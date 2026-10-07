defmodule ActivityPub.UtilsBaseUrlTest do
  use ExUnit.Case, async: true
  @moduletag :ap_lib

  alias ActivityPub.Utils

  # names under `localhost` are loopback (RFC 6761), so like `localhost` itself they're served over plain HTTP in local setups
  for {authority, expected} <- [
        {"localhost:4002", "http://localhost:4002"},
        {"xn--bcher-kva.localhost:4002", "http://xn--bcher-kva.localhost:4002"},
        {"instance2.localhost", "http://instance2.localhost"},
        {"mocked.local", "https://mocked.local"},
        {"localhost.example.com", "https://localhost.example.com"}
      ] do
    test "base_url of #{authority} is #{expected}" do
      assert Utils.base_url(unquote(authority)) == unquote(expected)
    end
  end
end
