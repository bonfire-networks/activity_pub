defmodule ActivityPub.Federator.HTTPSSRFTest do
  @moduledoc """
  Every request the federation HTTP client makes (fetches, webfinger, nodeinfo, deliveries) goes to a URL that comes from remote data or user input. So the client itself, on every request and redirect hop, refuses private or loopback addresses and hosts the instance's block/allow lists don't let it federate with, without each caller having to remember to check.

  The HTTP adapter is mocked and reports every request it gets. A test that expects a request to be refused checks that the mock never got it. Next to it, a test where a request is allowed checks that the mock does get it, which shows the request really would have been made. `ReqSSRF` has its own tests for which addresses count as private.
  """
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Federator.HTTP

  setup do
    test_pid = self()

    Tesla.Mock.mock(fn
      %{url: "http://mastodon.local/to-private"} = env ->
        send(test_pid, {:hit, env.url})
        %Tesla.Env{status: 302, headers: [{"location", "http://10.0.0.1/inbox"}]}

      %{url: "http://mastodon.local/to-rejected"} = env ->
        send(test_pid, {:hit, env.url})
        %Tesla.Env{status: 302, headers: [{"location", "http://evil.example.org/inbox"}]}

      env ->
        send(test_pid, {:hit, env.url})
        %Tesla.Env{status: 200, body: "ok"}
    end)

    clear_config([:mrf_simple, :reject], ["evil.example.org", "i said so"])

    :ok
  end

  test "a public host is fetched" do
    assert {:ok, %{status: 200}} = HTTP.get("http://mastodon.local/hello")
    assert_received {:hit, "http://mastodon.local/hello"}
  end

  test "a private address is never requested" do
    refute match?({:ok, _}, HTTP.get("http://10.0.0.1/hello"))
    refute_received {:hit, _}
  end

  test "a rejected instance is never fetched from, with no options passed" do
    assert {:error, :not_allowed} = HTTP.get("http://evil.example.org/hello")
    refute_received {:hit, _}
  end

  test "nothing is delivered to a rejected instance, with no options passed" do
    assert {:error, :not_allowed} = HTTP.post("http://evil.example.org/inbox", "{}")
    refute_received {:hit, _}
  end

  describe "a redirect from an allowed instance" do
    test "to a private address is refused at that hop" do
      refute match?({:ok, %{status: 200}}, HTTP.get("http://mastodon.local/to-private"))
      assert_received {:hit, "http://mastodon.local/to-private"}
      refute_received {:hit, "http://10.0.0.1/inbox"}
    end

    test "to a rejected instance is refused at that hop" do
      refute match?({:ok, %{status: 200}}, HTTP.get("http://mastodon.local/to-rejected"))
      assert_received {:hit, "http://mastodon.local/to-rejected"}
      refute_received {:hit, "http://evil.example.org/inbox"}
    end
  end
end
