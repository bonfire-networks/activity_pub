defmodule ActivityPub.Safety.LinkedDataSignatures.DocumentLoaderSSRFTest do
  @moduledoc """
  Verifying a Linked Data signature loads the document's `@context` URLs, which are chosen by whoever sent the document (even unauthenticated, to an inbox). So contexts that aren't bundled are fetched through the same checks as every other federation request: never from a private or loopback address, nor from an instance the block/allow lists don't federate with.

  The HTTP adapter is mocked and reports every request it gets. A test that expects a context to be refused checks that the mock never got the request. Next to it, a test with an allowed context checks that the mock does get it, which shows the request really would have been made.
  """
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Safety.LinkedDataSignatures.DocumentLoader

  setup do
    test_pid = self()

    Tesla.Mock.mock(fn env ->
      send(test_pid, {:hit, env.url})

      %Tesla.Env{
        status: 200,
        headers: [{"content-type", "application/ld+json"}],
        body: ~s({"@context": {"name": "https://schema.org/name"}})
      }
    end)

    clear_config([:mrf_simple, :reject], ["evil.example.org", "i said so"])

    :ok
  end

  test "an unknown context on an allowed instance is loaded" do
    assert {:ok, _} = DocumentLoader.load("http://mastodon.local/context.jsonld", [])
    assert_received {:hit, "http://mastodon.local/context.jsonld"}
  end

  test "a context on a private address is never loaded" do
    refute match?({:ok, _}, DocumentLoader.load("http://10.0.0.1/context.jsonld", []))
    refute_received {:hit, _}
  end

  test "a context on a rejected instance is never loaded" do
    refute match?({:ok, _}, DocumentLoader.load("http://evil.example.org/context.jsonld", []))
    refute_received {:hit, _}
  end
end
