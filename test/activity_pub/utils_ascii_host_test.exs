defmodule ActivityPub.UtilsAsciiHostTest do
  use ExUnit.Case, async: true
  @moduletag :ap_lib

  alias ActivityPub.Utils

  test "a normal IDN host is encoded to its A-labels" do
    assert Utils.ascii_host("bücher.example") == "xn--bcher-kva.example"
    assert Utils.ascii_host("bücher.example:4000") == "xn--bcher-kva.example:4000"
  end

  # remote hosts are attacker input: an oversized `xn--` label beside a non-ASCII one must be dealt with quickly, not decoded for seconds or minutes
  test "a host with a huge xn-- label next to a non-ASCII label returns quickly" do
    host = "bücher.xn--" <> String.duplicate("a", 4000) <> ".example"

    task = Task.async(fn -> :timer.tc(fn -> Utils.ascii_host(host) end) end)

    case Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {micros, result}} ->
        assert is_binary(result)
        assert micros < 200_000

      other ->
        flunk("ascii_host/1 did not return within 1 s: #{inspect(other)}")
    end
  end
end
