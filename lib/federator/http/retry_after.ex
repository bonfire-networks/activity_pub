defmodule ActivityPub.Federator.HTTP.RetryAfter do
  @moduledoc """
  Takes into account the Retry-After header returned by the server when the rate limit is exceeded.

  Inside an Oban worker a 429 raises `RateLimitSnooze`, which `ActivityPub.Federator.Worker` turns into `{:snooze, seconds}`: the job is rescheduled for as long as the remote asked, and since snoozing raises `max_attempts` alongside `attempt`, waiting costs no retry.

  Elsewhere there is no job to reschedule, so the only way to honour a delay is to block the caller and its database connection with it. That is fine for a moment and wrong for the hour a remote is entitled to ask for, so a short wait is taken inline and repeated, while a long one gives the 429 back to the caller (`:max_inline_wait_sec`).

  Only 429 is handled here. A 503 also carries `Retry-After` and is honoured in `APPublisher`, because it says the HOST is in trouble: absorbing it into a snooze would keep that from ever reaching the failure handling that records it.

  Based on `TeslaExtra.RetryAfter`
  """

  @behaviour Tesla.Middleware

  import Untangle
  alias ActivityPub.Config

  @impl Tesla.Middleware
  def call(env, next, opts) do
    # matching on the RESULT of `Tesla.run/2`, which is `{:ok, env}` rather than a bare env. Matching the bare form (as this did until 2026-09-04) means the 429 clause can never be selected, so no `Retry-After` was ever honoured
    case Tesla.run(env, next) do
      {:ok, %{status: 429, headers: headers}} = result ->
        handle_rate_limited(result, requested_wait_sec(headers), env, next, opts)

      {:error, error} ->
        error(error)

      result ->
        result
    end
  end

  @doc """
  The `Retry-After` delay in seconds, or nil when the header is absent or gives an HTTP-date, which RFC 9110 also allows and we do not read.

  Public because the publisher honours the same header on a 503, which it has to do itself: a 503 says the host is in trouble, so it has to reach the failure handling that records that, rather than being absorbed into a snooze here.
  """
  def retry_after_sec(headers) do
    # `find_value` returns what the function returns, so this has to yield the VALUE: returning the comparison itself gave `true`, which `String.to_integer/1` then raised on
    with value when is_binary(value) <-
           Enum.find_value(headers, fn {k, v} -> k == "retry-after" && v end),
         {seconds, _} <- Integer.parse(value) do
      seconds
    else
      _ -> nil
    end
  end

  defp handle_rate_limited(result, retry_after, env, next, _opts) do
    debug(result, "handle HTTP 429: Too Many Requests")

    cond do
      ProcessTree.get(:ap_oban_worker) ->
        info(retry_after, "Rate limited, rescheduling the job in (seconds)")
        raise ActivityPub.Federator.HTTP.RateLimitSnooze, wait_sec: retry_after

      retry_after <= max_inline_wait_sec() ->
        :timer.sleep(retry_after * 1000)

        # the ORIGINAL env and the REST of the stack, which is what a repeat needs: retrying the result of the first attempt is not a request
        Tesla.run(env, next)

      true ->
        # with no job to reschedule, honouring this would mean BLOCKING the caller's process, and its database connection with it, for as long as the remote asked. A caller holding a web request is better off with the 429
        warn(
          retry_after,
          "Rate limited for longer than we will wait outside a job, so answering with the 429 (seconds)"
        )

        result
    end
  end

  defp requested_wait_sec(headers) do
    retry_after_sec(headers)
    |> debug("requested retry-after") ||
      Config.get([__MODULE__, :default_retry_after_sec], 10)
      |> debug("no readable `retry-after` header, will retry in ")
  end

  defp max_inline_wait_sec, do: Config.get([__MODULE__, :max_inline_wait_sec], 5)
end
