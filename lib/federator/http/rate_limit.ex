defmodule ActivityPub.Federator.HTTP.RateLimit do
  @moduledoc """
  Rate limit middleware for Tesla using Hammer 7.

  Based on `TeslaExtra.RateLimit` and `TeslaExtra.RetryAfter`
  """

  @behaviour Tesla.Middleware

  import Untangle
  alias ActivityPub.Config

  @impl Tesla.Middleware
  def call(env, next, opts) do
    scale_ms =
      Keyword.get(opts, :scale_ms) ||
        Config.get([ActivityPub.Federator.HTTP.RateLimit, :scale_ms], 10_000)

    limit =
      Keyword.get(opts, :limit) ||
        Config.get([ActivityPub.Federator.HTTP.RateLimit, :limit], 20)

    %{host: host} = URI.parse(env.url)

    # Use Hammer 7 API via ActivityPub.RateLimit module
    case ActivityPub.RateLimit.hit("http_client:#{host}", scale_ms, limit) do
      {:allow, _count} ->
        Tesla.run(env, next)

      {:deny, retry_after} ->
        # Wait for the retry period (but cap it at scale_ms to avoid excessive delays)
        wait_ms = min(retry_after, scale_ms)
        :timer.sleep(wait_ms)
        info(wait_ms, "HTTP client rate limit reached, waited (ms)")
        Tesla.run(env, next)
    end
  end
end
