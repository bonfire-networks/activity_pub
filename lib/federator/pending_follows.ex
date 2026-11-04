defmodule ActivityPub.Federator.PendingFollows do
  @moduledoc """
  Sends one of our Follows once more when it is still pending a few minutes after its delivery.

  Lemmy 0.19 never sends the Accept of the first Follow it gets from an instance it hadn't seen yet: it starts sending to that instance at its next check of its instance list, and skips what was queued before. It answers every Follow with an Accept, so one more Follow gets the Accept. That Follow has a new id, as Lemmy drops an activity id it has already received, and it is stored, as an incoming Accept must find the Follow it embeds.

  Each delivered Follow gets one check, scheduled `:resend_pending_follow_after` (a duration in milliseconds, or `false` for no checks) after the delivery got a 2xx. The re-sent Follow gets no check of its own, so a Follow is re-sent once at most.
  """
  import Untangle

  alias ActivityPub.Config
  alias ActivityPub.Actor
  alias ActivityPub.Object
  alias ActivityPub.Instances
  alias ActivityPub.Federator.APPublisher
  alias ActivityPub.Federator.Workers.PublisherWorker

  @op "resend_pending_follow"

  def op, do: @op

  @doc "How long after the delivery of a Follow to check it, in milliseconds, or `false`."
  def resend_after, do: Config.get(:resend_pending_follow_after, to_timeout(minute: 4))

  @doc "After a delivery got a 2xx, queues the check if what it delivered is a Follow."
  def maybe_queue_check(%{type: "Follow", resend_pending_follow: false}), do: nil

  def maybe_queue_check(%{type: "Follow", id: follow_id, inbox: inbox} = params)
      when is_binary(follow_id) do
    after_ms = resend_after()

    cond do
      not is_integer(after_ms) ->
        nil

      # an actor that approves its followers by hand is pending for a good reason, and a re-send could notify its owner again
      manually_approves_followers?(params) ->
        debug(follow_id, "no check for a Follow of an actor that approves followers by hand")
        nil

      true ->
        PublisherWorker.enqueue(
          @op,
          %{"follow_id" => follow_id, "inbox" => inbox},
          schedule_in: div(after_ms, 1000),
          # one check per Follow, ever, also when the same Follow is delivered again
          unique: [period: :infinity, keys: [:op, :follow_id], states: :all]
        )
        |> debug("queued a check for a re-send")
    end
  end

  def maybe_queue_check(_params), do: nil

  # an actor that doesn't say counts as not approving by hand (eg. a Lemmy person)
  defp manually_approves_followers?(%{json: json}) when is_binary(json) do
    with {:ok, %{"object" => followed}} <- Jason.decode(json),
         {:ok, %{data: %{"manuallyApprovesFollowers" => true}}} <-
           Actor.get_cached(ap_id: Object.get_ap_id(followed)) do
      true
    else
      _ -> false
    end
  end

  defp manually_approves_followers?(_params), do: false

  @doc """
  Runs the check of a delivered Follow, from its job. If the Follow is still pending and still the newest Follow from that actor to that actor, sends a new one. An Accept or a Reject (of this Follow or a newer one) and an unfollow (`ActivityPub.unfollow/2` marks the Follow `"undo"`) each set its state, so the check then cancels.
  """
  def check(follow_id, inbox) do
    with {:ok, %Object{data: %{"actor" => follower_id, "object" => followed}}} <-
           Object.get_cached(ap_id: follow_id),
         followed_id = Object.get_ap_id(followed),
         :ok <- still_pending(follow_id, follower_id, followed_id),
         :ok <- host_ready(inbox),
         {:ok, follower} <- Actor.get_cached(ap_id: follower_id),
         {:ok, followed} <- Actor.get_cached(ap_id: followed_id) do
      info(follow_id, "re-sending a Follow still pending")
      # no `pointer`, as that belongs to the first Follow, and no check of its own
      ActivityPub.follow(%{actor: follower, object: followed}, resend_pending_follow: false)
    else
      {:cancel, _} = cancel ->
        cancel

      {:snooze, _} = snooze ->
        snooze

      e ->
        {:cancel, "could not find the Follow or its actors: #{inspect(e)}"}
    end
  end

  # the same rules as a delivery (`APPublisher`): wait while the host is failing, and give up once it has been failing for longer than a delivery is kept
  defp host_ready(inbox) do
    cond do
      APPublisher.too_stale?(%{queued_at: failing_since(inbox)}) ->
        {:cancel, "the host has been failing for too long to still be worth a re-send"}

      seconds = Instances.pacing_snooze_sec(inbox) ->
        info(inbox, "backing off from a failing host for #{seconds}s before checking this Follow")
        {:snooze, seconds}

      true ->
        :ok
    end
  end

  defp failing_since(inbox) do
    case Instances.Instance.get_by_host(Instances.host(inbox)) do
      %{unreachable_since: since} -> since
      _ -> nil
    end
  end

  # read from the database rather than the cache: an Accept, a Reject or an unfollow sets the state of every Follow from that actor to that actor, but refreshes the cached copy of only one of them
  defp still_pending(follow_id, follower_id, followed_id) do
    case Object.fetch_latest_activity(follower_id, followed_id, "Follow") do
      %Object{data: %{"id" => ^follow_id, "state" => "pending"}} ->
        :ok

      %Object{data: %{"id" => ^follow_id} = data} ->
        {:cancel, "the Follow is no longer pending: #{inspect(data["state"])}"}

      %Object{} ->
        {:cancel, "a newer Follow replaced it"}

      nil ->
        {:cancel, "the Follow is gone"}
    end
  end
end
