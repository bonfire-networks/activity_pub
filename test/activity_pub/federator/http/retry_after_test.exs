defmodule ActivityPub.Federator.HTTP.RetryAfterTest do
  @moduledoc """
  Honouring a remote's `Retry-After` when it rate limits us.

  A 429 is answered by rescheduling rather than retrying: inside an Oban worker the middleware raises `RateLimitSnooze`, which `ActivityPub.Federator.Worker` turns into `{:snooze, seconds}`, so the job waits as long as the remote asked and the attempt is not spent. Outside a worker there is no job to reschedule, so it waits inline and re-runs the request.

  The header's VALUE decides the delay, which is what these pin: reading the header as a mere presence check gave `true` rather than the number, and `String.to_integer/1` then raised, so a 429 that carried a `Retry-After` fell back to ordinary backoff while one without it snoozed correctly.
  """
  use ExUnit.Case, async: true

  alias ActivityPub.Federator.HTTP.RateLimitSnooze
  alias ActivityPub.Federator.HTTP.RetryAfter

  # a Tesla stack of just this middleware, over an adapter that answers what the test wants and counts how often it was asked
  defp client(status, headers) do
    test_pid = self()

    Tesla.client([RetryAfter], fn env ->
      send(test_pid, :requested)
      {:ok, %{env | status: status, headers: headers}}
    end)
  end

  defp as_oban_worker do
    Process.put(:ap_oban_worker, true)
    on_exit(fn -> Process.delete(:ap_oban_worker) end)
  end

  test "a 429 in a worker snoozes for the seconds the remote asked for" do
    as_oban_worker()

    assert_raise RateLimitSnooze, fn ->
      Tesla.get(client(429, [{"retry-after", "30"}]), "https://remote.local/inbox")
    end
  end

  test "and the delay is the header's value, not a placeholder" do
    as_oban_worker()

    error =
      assert_raise RateLimitSnooze, fn ->
        Tesla.get(client(429, [{"retry-after", "30"}]), "https://remote.local/inbox")
      end

    assert error.wait_sec == 30,
           "the delay has to come from the header: waiting an arbitrary interval against a remote that told us exactly how long is what rate limiting asks us not to do"
  end

  test "a 429 with no Retry-After falls back to the configured default" do
    as_oban_worker()

    error =
      assert_raise RateLimitSnooze, fn ->
        Tesla.get(client(429, []), "https://remote.local/inbox")
      end

    assert error.wait_sec ==
             ActivityPub.Config.get([RetryAfter, :default_retry_after_sec], 10)
  end

  # Outside a worker there is no job to reschedule, so the only way to honour a delay is to BLOCK, which means holding that process and any connection it has checked out. Fine for a couple of seconds, not for the hour a remote is entitled to ask for, so past a threshold we hand the 429 back instead and let the caller fail normally. Inside a worker the same delay costs nothing, so it is honoured whole.
  test "outside a worker a long wait is not waited for" do
    assert {:ok, %{status: 429}} =
             Tesla.get(client(429, [{"retry-after", "3600"}]), "https://remote.local/inbox")

    assert_received :requested

    refute_received :requested,
                    "blocking a web request for an hour to be polite is worse than answering it"
  end

  test "outside a worker it waits and re-runs the request" do
    # `0` so the inline wait costs nothing: what is under test is that the request is repeated, not how long we slept for
    assert {:ok, %{status: 429}} =
             Tesla.get(client(429, [{"retry-after", "0"}]), "https://remote.local/inbox")

    assert_received :requested
    assert_received :requested
  end

  # RFC 9110 allows `Retry-After` on a 503 too, and we do honour it, but in the PUBLISHER, not here. A 503 says the host is in trouble, which is something the publisher has to see: absorbing it into a snooze would mean the host is never flagged, so the reachability clock never starts and per-host pacing never engages. A 429 can be handled below the publisher precisely because it does NOT count against the host.
  test "a 503 passes through, even when it names a delay" do
    as_oban_worker()

    assert {:ok, %{status: 503}} =
             Tesla.get(client(503, [{"retry-after", "120"}]), "https://remote.local/inbox"),
           "the delay is honoured where the failure is also recorded, rather than swallowed here"
  end

  test "any other status passes straight through" do
    assert {:ok, %{status: 202}} =
             Tesla.get(client(202, []), "https://remote.local/inbox")

    assert_received :requested
    refute_received :requested
  end
end
