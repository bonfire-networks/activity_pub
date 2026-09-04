defmodule ActivityPub.Federator.DeliveryResponseTest do
  @moduledoc """
  What we do with a remote's answer to a delivery: whether to try again, and whether to hold it against the host.

  Two independent decisions, which used to be one. Every non-2xx marked the host unreachable AND returned an error, so Oban retried it. That is wrong in both directions for a 4xx: the host plainly answered, so it is not unreachable, and it answered that THIS PAYLOAD is wrong, which re-POSTing identical bytes cannot change.

  It stopped being academic with the group relay, which deliberately sends two shapes of the same Announce so that receivers understanding either one can file it. Lemmy answers the shape it does not parse with a 400, every time, so one delivery per pair is expected to fail: without the split, each group post scheduled a permanent retry and re-flagged the receiver.

  The line for the second decision is that a host answering is reachable, and only "I could not take this request" says otherwise. So 408 leaves its 4xx neighbours and joins 502/503/504, all of which mean the application did not answer — while a plain 500 stays out, being their handler erroring on our document rather than anything about the host. A 429 sits on its own, a healthy host deliberately shedding load, and `HTTP.RetryAfter` absorbs it before the publisher sees it.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import Tesla.Mock

  alias ActivityPub.Federator.APPublisher
  alias ActivityPub.Instances.Instance

  @inbox "https://receiver.local/inbox"

  defp deliver(status, body \\ "") do
    mock(fn %{method: :post} -> %Tesla.Env{status: status, body: body} end)

    actor = local_actor()
    {:ok, actor} = ActivityPub.Actor.get_cached(username: actor.username)

    APPublisher.publish_one(%{
      actor: actor,
      inbox: @inbox,
      json: Jason.encode!(%{"type" => "Announce", "id" => "https://local.local/pub/objects/1"}),
      id: "https://local.local/pub/objects/1"
    })
  end

  defp flagged? do
    case Instance.get_by_host("receiver.local") do
      %{unreachable_since: since} -> not is_nil(since)
      _ -> false
    end
  end

  describe "retryable_status?/1" do
    test "a payload the receiver cannot parse is not worth sending again" do
      for status <- [400, 401, 403, 404, 410, 422] do
        refute APPublisher.retryable_status?(status),
               "HTTP #{status} is the receiver refusing this document, and the same bytes will be refused again"
      end
    end

    test "a timeout or a broken server is" do
      for status <- [408, 500, 502, 503, 504] do
        assert APPublisher.retryable_status?(status)
      end
    end

    test "and so is being rate limited, though `RetryAfter` normally gets there first" do
      assert APPublisher.retryable_status?(429)
    end
  end

  describe "unreachable_status?/1" do
    test "a host that answers is reachable, whatever it answered" do
      for status <- [400, 401, 403, 404, 410, 422, 429] do
        refute APPublisher.unreachable_status?(status),
               "HTTP #{status} came FROM the host, so it is up"
      end
    end

    test "except when the answer is that it could not take the request" do
      assert APPublisher.unreachable_status?(408),
             "a request timeout is the same condition as no answer, just reported"

      for status <- [502, 503, 504] do
        assert APPublisher.unreachable_status?(status),
               "HTTP #{status} comes from the gateway in front of an application that is not answering"
      end
    end

    test "and a plain 500 is their application erroring, not their host being gone" do
      refute APPublisher.unreachable_status?(500),
             "a 500 says our document broke their handler, or their code did; a dead instance answers with a refused connection, not a 500"
    end
  end

  describe "delivering" do
    test "a 400 is discarded rather than retried" do
      assert {:cancel, _} = deliver(400, ~s({"error":"unknown"}))
    end

    test "and leaves the host reachable" do
      deliver(400, ~s({"error":"unknown"}))

      refute flagged?(),
             "the receiver answered us, so nothing about it is unreachable — and a group relay makes this happen on every post"
    end

    test "a 500 is retried, but not held against the host" do
      assert {:error, _} = deliver(500)

      refute flagged?(),
             "their handler broke on our document; the host answered us and is plainly there"
    end

    test "a 502 is retried and does hold against the host" do
      assert {:snooze, _} = deliver(502)
      assert flagged?()
    end

    test "a 2xx is neither" do
      assert {:ok, _} = deliver(202)
      refute flagged?()
    end
  end

  # Snoozing and erroring differ in ATTEMPT ACCOUNTING rather than in timing: `{:error, _}` burns one of the three attempts, while `{:snooze, n}` raises `max_attempts` to compensate. So a delivery that keeps erroring against a host that is down dies in about three minutes (Oban's ~16s/35s/110s) and never reaches the hours-long part of the backoff curve at all. Snoozing instead lets it ride out the outage, which is what the delivery age limit then has to bound. The cost is that a one-off blip waits the grace period rather than Oban's first 16s, which is a trade worth one simple rule.
  describe "a retryable failure that counts against the host" do
    test "snoozes rather than spending an attempt" do
      assert {:snooze, seconds} = deliver(502),
             "including the first one, since the flag is set before the answer is judged, which is what keeps the rule to one sentence"

      assert seconds > 0

      assert {:snooze, _} = deliver(502)
    end

    test "while a host with no history still errors" do
      assert {:error, _} = deliver(500),
             "a 500 does not flag the host, so nothing changes: three attempts and the delivery is discarded, which is right for a document their handler chokes on"

      assert {:error, _} = deliver(500)
    end
  end

  # RFC 9110 allows `Retry-After` on a 503, and an overloaded host naming its own recovery time is better information than our backoff curve guessing. It is honoured HERE rather than in `HTTP.RetryAfter` because both things have to happen: the host is in trouble, which the reachability clock needs to know, AND it asked for a specific delay. Middleware could only do the second, and doing it there would hide the failure from the publisher entirely.
  describe "a 503 that names a delay" do
    test "is rescheduled for the time the host asked for" do
      mock(fn %{method: :post} ->
        %Tesla.Env{status: 503, headers: [{"retry-after", "120"}], body: ""}
      end)

      actor = local_actor()
      {:ok, actor} = ActivityPub.Actor.get_cached(username: actor.username)

      assert {:snooze, 120} =
               APPublisher.publish_one(%{
                 actor: actor,
                 inbox: @inbox,
                 json: Jason.encode!(%{"type" => "Announce"}),
                 id: "https://local.local/pub/objects/2"
               })
    end

    test "and still counts against the host, unlike a 429" do
      mock(fn %{method: :post} ->
        %Tesla.Env{status: 503, headers: [{"retry-after", "120"}], body: ""}
      end)

      actor = local_actor()
      {:ok, actor} = ActivityPub.Actor.get_cached(username: actor.username)

      APPublisher.publish_one(%{
        actor: actor,
        inbox: @inbox,
        json: Jason.encode!(%{"type" => "Announce"}),
        id: "https://local.local/pub/objects/3"
      })

      assert flagged?(),
             "a polite outage is still an outage: waiting as asked must not stop the clock that decides when to give up"
    end
  end
end
