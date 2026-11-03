defmodule ActivityPub.Federator.HTTP.TLSFallbackTest do
  @moduledoc """
  Requests through `ActivityPub.Federator.HTTP.TLSFallback` when the host cache isn't running.

  Mix tasks (eg. `mix changelog` in the docs CI) make HTTP requests through this middleware without starting the application, so `:ap_host_cache` doesn't exist. What we learned about hosts is then simply not remembered: the request goes through, rather than Cachex raising on the missing cache.
  """
  use ExUnit.Case, async: false

  @moduletag :backend

  alias ActivityPub.Federator.HTTP.TLSFallback
  alias ActivityPub.Instances

  @url "https://example.local/"

  setup do
    :ok = Supervisor.terminate_child(ActivityPub.Supervisor, :ap_host_cache)
    on_exit(fn -> Supervisor.restart_child(ActivityPub.Supervisor, :ap_host_cache) end)
  end

  test "a request goes through when the host cache isn't running" do
    client = Tesla.client([TLSFallback], fn env -> {:ok, %{env | status: 200}} end)

    assert {:ok, %{status: 200}} = Tesla.get(client, @url)
  end

  test "host cache reads give nil and writes do nothing when the cache isn't running" do
    assert Instances.put_host_cache(@url, :tls_compat, true) == nil
    assert Instances.get_host_cache(@url, :tls_compat) == nil
    assert Instances.delete_host_cache(@url, :tls_compat) == nil
  end
end
