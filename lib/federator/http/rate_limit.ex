defmodule ActivityPub.Federator.HTTP.RateLimit do
  @moduledoc """
  Rate limit middleware for Tesla using Hammer
  Based on `TeslaExtra.RateLimit` and `TeslaExtra.RetryAfter`
  """

  @behaviour Tesla.Middleware

  import Untangle
  alias ActivityPub.Config

  @impl Tesla.Middleware
  def call(env, next, opts) do
    # if Config.env() != :test do

    # Keyword.fetch!(opts, :scale_ms)
    scale_ms = Config.get([ActivityPub.Federator.HTTP.RateLimit, :scale_ms], 10000)
    # Keyword.fetch!(opts, :limit)
    limit = Config.get([ActivityPub.Federator.HTTP.RateLimit, :limit], 20)

    %{host: host} = URI.parse(env.url)

    case Hammer.check_rate(
           "rate_limit:#{host}",
           scale_ms,
           limit
         ) do
      {:allow, _} ->
        Tesla.run(env, next)

      {:deny, _} ->
        :timer.sleep(scale_ms)
        info(scale_ms, "RateLimit reached, wait (ms)")
        Tesla.run(env, next)
    end

    # else
    #   Tesla.run(env, next)
    # end
  end
end
