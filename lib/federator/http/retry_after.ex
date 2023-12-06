defmodule ActivityPub.Federator.HTTP.RetryAfter do
  @moduledoc """
  Takes into account the Retry-After header returned by the server when the rate limit is exceeded.

  Based on `TeslaExtra.RetryAfter`
  """

  @behaviour Tesla.Middleware

  import Untangle
  alias ActivityPub.Config

  @impl Tesla.Middleware
  def call(env, next, opts) do
    debug(next)

    env
    |> Tesla.run(next)
    |> handle_rate_limit_headers(env, opts)
  end

  defp handle_rate_limit_headers(%{status: 429, headers: headers} = env, next, _opts) do
    debug(env)

    retry_after =
      case Enum.find_value(headers, fn {k, _} -> k == "retry-after" end) do
        nil ->
          Config.get([__MODULE__, :default_retry_after_sec], 10)
          |> debug("Limit reached but no `retry-after` header was provided, will retry in ")

        retry_after ->
          String.to_integer(retry_after)
          |> info("Rate limit reached, will retry in (seconds)")
      end

    :timer.sleep(retry_after * 1000)
    Tesla.run(env, next)
  end

  defp handle_rate_limit_headers(env, _next, _opts) do
    debug(env)
    env
  end
end
