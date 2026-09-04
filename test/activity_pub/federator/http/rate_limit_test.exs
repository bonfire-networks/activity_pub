defmodule ActivityPub.Federator.HTTP.RateLimitTest do
  @moduledoc """
  Our own outgoing rate limit, which caps how hard we hit one host.

  When it trips inside an Oban worker the delivery is rescheduled rather than attempted, and `{:snooze, n}` counts SECONDS while Hammer answers in milliseconds. That conversion is what this pins: getting it backwards postpones a delivery by months instead of seconds, and nothing downstream would notice, since a job scheduled far in the future looks exactly like a job that is waiting.

  `call/3` itself is compiled out under `:test` unless `ENABLE_RATE_LIMIT=yes`, so the arithmetic lives in `snooze_seconds/2` where it can be asserted on.
  """
  use ExUnit.Case, async: true

  alias ActivityPub.Federator.HTTP.RateLimit

  @window_ms 10_000

  test "the snooze is in seconds" do
    assert RateLimit.snooze_seconds(3_500, @window_ms) == 3
  end

  test "a wait longer than the window is capped at the window" do
    assert RateLimit.snooze_seconds(60_000, @window_ms) == 10,
           "waiting longer than one rate-limit window cannot buy anything, since the window has emptied by then"
  end

  test "a sub-second wait still snoozes for a second" do
    assert RateLimit.snooze_seconds(400, @window_ms) == 1,
           "a snooze of zero would run the job again immediately, straight back into the limit"
  end

  test "the largest possible snooze is one window, in seconds" do
    assert RateLimit.snooze_seconds(@window_ms, @window_ms) == 10,
           "reading milliseconds as seconds here is the difference between 10 seconds and 115 days, and both look like a job quietly waiting"
  end
end
