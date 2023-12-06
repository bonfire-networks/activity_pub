defmodule ActivityPub.Federator.HTTP.Tesla do
  use Tesla
  import Untangle

  if ActivityPub.Config.env() != :test do
    # rate limit outgoing HTTP requests
    plug ActivityPub.Federator.HTTP.RateLimit
  end

  plug Tesla.Middleware.FollowRedirects, max_redirects: 3

  # if ActivityPub.Config.env() != :test do
  # retry failed outgoing HTTP requests
  plug ActivityPub.Federator.HTTP.RetryAfter

  # NOTE: this should come after `RetryAfter` so we actually retry after waiting the indicated time
  plug Tesla.Middleware.Retry,
    delay: 1000,
    max_retries: 5,
    max_delay: 10_000,
    should_retry: fn
      {:ok, %{status: status}}
      when status in [
             # Request timeout
             408,
             # Too many requests
             429,
             # Client Closed Request
             499,
             # Internal server error
             500,
             # Bad gateway
             502,
             # Service unavailable
             503,
             # Gateway timeout
             504,
             # Web Server Is Down
             521,
             # Connection Timed Out
             522,
             # Origin Is Unreachable
             523,
             # A Timeout Occurred
             524,
             # Connection Timed Out
             522
           ] ->
        info(status, "Tesla.Middleware.Retry will retry after matching on HTTP code")
        true

      {:ok, _} ->
        false

      {:error, e} ->
        warn(e, "Tesla.Middleware.Retry will retry after connection error")
        true
    end

  # end
end
