defmodule ActivityPub.Federator.HTTP.RateLimitSnooze do
  defexception [:wait_sec]

  @impl true
  def message(%{wait_sec: wait_sec}) do
    "Rate limited, retry after #{wait_sec} seconds"
  end
end
