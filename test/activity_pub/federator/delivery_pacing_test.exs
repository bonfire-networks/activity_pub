defmodule ActivityPub.Federator.DeliveryPacingTest do
  @moduledoc """
  Slowing deliveries to a host that is failing, instead of each queued job discovering the outage for itself.

  Oban backs off PER JOB, so five hundred deliveries waiting for one struggling host each retry on their own clock and hand it the same herd it just failed under. `unreachable_since` already knows the host is failing, but nothing reads it until the give-up threshold, so between the first failure and that day it changes nothing at all.

  Pacing is that flag gaining resolution rather than a second mechanism beside it: how long a host has been failing is what the backoff curve wants as its input, and `set_unreachable` keeps the OLDEST timestamp, so `now - unreachable_since` is exactly that. The row's `updated_at` says when we last tried, so of the jobs that wake together only the first probes and the rest are put back to sleep.

  The grace period is what keeps a single failure from throttling a healthy host: below it the curve is zero, deliveries keep flowing at full rate, and the success that follows clears the flag before pacing ever engages. It is only a host that KEEPS failing that crosses into being paced.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import Tesla.Mock

  alias ActivityPub.Federator.APPublisher
  alias ActivityPub.Instances
  alias ActivityPub.Instances.Instance

  @host "paced.local"
  @inbox "https://paced.local/inbox"

  describe "backoff_sec/1" do
    test "is zero while the failure is still young" do
      assert Instances.backoff_sec(0) == 0

      assert Instances.backoff_sec(30) == 0,
             "one failure must not throttle a host, since the next success would have cleared it anyway"
    end

    test "grows with how long the host has been failing" do
      an_hour = Instances.backoff_sec(3600)
      ten_minutes = Instances.backoff_sec(600)

      assert an_hour > ten_minutes,
             "a host down for an hour deserves fewer probes than one down for ten minutes"
    end

    test "and stops growing at the cap" do
      assert Instances.backoff_sec(86_400) == Instances.backoff_sec(86_400 * 30),
             "a month of failure should not mean a month between probes: the cap is what lets a recovered host be noticed"
    end
  end

  describe "a host that has been failing" do
    setup do
      test_pid = self()

      mock(fn %{method: :post} ->
        send(test_pid, :posted)
        %Tesla.Env{status: 202, body: ""}
      end)

      actor = local_actor()
      {:ok, actor} = ActivityPub.Actor.get_cached(username: actor.username)

      %{actor: actor}
    end

    defp deliver(actor) do
      APPublisher.publish_one(%{
        actor: actor,
        inbox: @inbox,
        json: Jason.encode!(%{"type" => "Announce"}),
        id: "https://local.local/pub/objects/paced"
      })
    end

    # `failing_for` sets both halves the pacing decision reads: how long the host has been failing, and when we last tried it
    defp failing_for(seconds, last_attempt_seconds_ago \\ 0) do
      now = NaiveDateTime.utc_now(Calendar.ISO) |> NaiveDateTime.truncate(:second)

      Instances.set_unreachable(@host)

      repo().update_all(
        Ecto.Query.from(i in Instance, where: i.host == ^@host),
        set: [
          unreachable_since: NaiveDateTime.add(now, -seconds),
          updated_at: NaiveDateTime.add(now, -last_attempt_seconds_ago)
        ]
      )
    end

    test "is left alone inside its window", %{actor: actor} do
      failing_for(3600)

      assert {:snooze, seconds} = deliver(actor)
      assert seconds > 0

      refute_received :posted,
                      "the point is to stop N queued jobs each rediscovering the same outage"
    end

    test "is probed once the window has passed", %{actor: actor} do
      failing_for(3600, 3600)

      assert {:ok, _} = deliver(actor)
      assert_received :posted
    end

    test "is not paced at all while the failure is young", %{actor: actor} do
      failing_for(10)

      assert {:ok, _} = deliver(actor)

      assert_received :posted,
                      "a host that failed once seconds ago is not a host in trouble"
    end

    test "and a host with no history is never paced", %{actor: actor} do
      assert {:ok, _} = deliver(actor)
      assert_received :posted
    end
  end

  # Because snoozing raises `max_attempts` every time, a delivery riding the backoff curve never runs out of attempts by itself: something has to decide it is too late to bother. Staleness is that something, since an activity delivered long enough after the fact is worse than one never delivered, as the post may have been edited or deleted and the `Follow` revoked, and nothing guarantees the `Delete` we queued behind it arrives after it.
  describe "a delivery that has been waiting too long" do
    setup do
      test_pid = self()

      mock(fn %{method: :post} ->
        send(test_pid, :posted)
        %Tesla.Env{status: 202, body: ""}
      end)

      actor = local_actor()
      {:ok, actor} = ActivityPub.Actor.get_cached(username: actor.username)

      %{actor: actor}
    end

    defp deliver_queued_at(actor, queued_at) do
      APPublisher.publish_one(%{
        actor: actor,
        inbox: @inbox,
        json: Jason.encode!(%{"type" => "Announce"}),
        id: "https://local.local/pub/objects/stale",
        queued_at: queued_at
      })
    end

    test "is cancelled, not retried", %{actor: actor} do
      long_ago = DateTime.utc_now() |> DateTime.add(-30, :day)

      assert {:cancel, _} = deliver_queued_at(actor, long_ago),
             "erroring here would retry roughly as many times as the delivery had snoozed, since every snooze raised `max_attempts`"
    end

    test "and is not sent at all", %{actor: actor} do
      long_ago = DateTime.utc_now() |> DateTime.add(-30, :day)

      deliver_queued_at(actor, long_ago)

      refute_received :posted,
                      "checked before posting, so a host we have given up on is not contacted"
    end

    test "while one queued recently goes out normally", %{actor: actor} do
      assert {:ok, _} = deliver_queued_at(actor, DateTime.utc_now())
      assert_received :posted
    end
  end
end
