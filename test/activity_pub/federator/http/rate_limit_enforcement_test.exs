defmodule ActivityPub.Federator.HTTP.RateLimitEnforcementTest do
  @moduledoc """
  Outside an Oban job (for example a web request that proxies a remote object), a request to a host whose per-host limit is used up must be refused promptly and must not reach the host. It must not hold the calling process for the rest of the window and then send anyway.

  `call/3` is compiled out under `:test` unless `ENABLE_RATE_LIMIT=yes`, so this runs through `just test-rate-limit`.

  The middleware is exercised directly, with a function adapter standing in for the remote host. `ActivityPub.Federator.HTTP.Tesla` leaves the middleware out under `:test`, so the web path (`/proxy_remote_object`) cannot be driven through it here.
  """
  use ExUnit.Case, async: false

  @moduletag :rate_limit

  alias ActivityPub.Federator.HTTP.RateLimit

  @limit 2
  @window_ms 3_000
  # well under the window, so a sleep of the rest of the window is clearly too slow
  @prompt_ms 500

  setup do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    adapter = fn env ->
      Agent.update(counter, &(&1 + 1))
      {:ok, %{env | status: 200, body: "ok"}}
    end

    client = Tesla.client([{RateLimit, scale_ms: @window_ms, limit: @limit}], adapter)

    # a host of its own per test, since the limiter is keyed by host and shared
    host = "rate-limit-#{System.unique_integer([:positive])}.example.local"

    {:ok, client: client, counter: counter, url: "https://#{host}/object/1"}
  end

  test "a request under the limit reaches the host and succeeds", ctx do
    assert {:ok, %{status: 200}} = Tesla.get(ctx.client, ctx.url)
    assert Agent.get(ctx.counter, & &1) == 1
  end

  test "once the host's limit is used up, a further request is refused promptly and does not reach the host",
       ctx do
    refute ProcessTree.get(:ap_oban_worker)

    for _ <- 1..@limit do
      assert {:ok, %{status: 200}} = Tesla.get(ctx.client, ctx.url)
    end

    assert Agent.get(ctx.counter, & &1) == @limit

    {micros, result} = :timer.tc(fn -> Tesla.get(ctx.client, ctx.url) end)
    elapsed_ms = div(micros, 1000)

    assert elapsed_ms < @prompt_ms,
           "the refused request held the process for #{elapsed_ms} ms (window is #{@window_ms} ms)"

    assert {:error, _} = result,
           "the request over the limit should be refused, got #{inspect(result)} after #{elapsed_ms} ms"

    assert Agent.get(ctx.counter, & &1) == @limit,
           "the host received a request beyond its limit"
  end
end
