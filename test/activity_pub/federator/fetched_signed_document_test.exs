defmodule ActivityPub.Federator.FetchedSignedDocumentTest do
  @moduledoc """
  A document we fetch is checked for its own proof or LD signature, as a delivered one is. One that holds is stored marked so, and kept as it arrived (`data_received`), so it still verifies when relayed or served; it keeps the date its origin gives, as anything fetched does. One without stays `:fetched`, with no original.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers
  import Tesla.Mock

  alias ActivityPub.Object
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Safety.IntegrityProofs

  @context [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/data-integrity/v2"
  ]

  setup do
    key = new_key(:ed25519)
    actor_id = "https://signer-#{System.unique_integer([:positive])}.example/users/alice"
    actor(ap_id: actor_id, data: %{"assertionMethod" => [multikey(actor_id, key)]})

    %{key: key, actor_id: actor_id}
  end

  defp served(document) do
    id = document["id"]

    mock(fn
      %{method: :get, url: ^id} ->
        json(document, headers: [{"content-type", "application/activity+json"}])

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    document
  end

  defp note(actor_id) do
    actor_id
    |> create_note()
    |> Map.fetch!("object")
    |> Map.put("@context", @context)
    |> Map.put("published", "2015-03-01T12:00:00Z")
  end

  test "a fetched document whose proof holds is kept as it arrived, and verifies from its row", %{
    key: key,
    actor_id: actor_id
  } do
    signed = actor_id |> note() |> sign(key) |> served()

    assert {:ok, _} = Fetcher.fetch_object_from_id(signed["id"])

    assert {:ok, %Object{authenticated: :integrity_proof, data_received: ^signed} = stored} =
             Object.get_uncached(ap_id: signed["id"])

    assert IntegrityProofs.verify(stored.data_received) == {:ok, actor_id}
    # its origin's date, as anything fetched
    assert stored.inserted_at.year == 2015
  end

  # An actor signs its own document with a key that document lists, so the proof shows only that it was signed by the key it names: fetching it from its origin is what vouches for it. Checking it would also look up its signer, the very actor being fetched, which is not stored yet (Hubzilla's actors carry a proof and an LD signature).
  @tag timeout: 10_000
  test "a fetched actor document signed by its own key is stored without checking it, and keeps no original" do
    key = new_key(:ed25519)
    actor_id = "https://self-signed-#{System.unique_integer([:positive])}.example/users/carol"

    document =
      %{
        "@context" => @context,
        "id" => actor_id,
        "type" => "Person",
        "preferredUsername" => "carol",
        "inbox" => actor_id <> "/inbox",
        "outbox" => actor_id <> "/outbox",
        "assertionMethod" => [multikey(actor_id, key)]
      }
      |> sign(key, verification_method: actor_id <> "#ed25519-key")
      |> served()

    assert {:ok, %{data: %{"id" => ^actor_id}}} =
             ActivityPub.Actor.get_cached_or_fetch(ap_id: actor_id)

    assert {:ok, %Object{data_received: nil}} = Object.get_uncached(ap_id: document["id"])
  end

  test "a fetched actor is stored as fetched, as any document we fetched from its origin" do
    actor_id = "https://plain-#{System.unique_integer([:positive])}.example/users/dave"

    served(%{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => actor_id,
      "type" => "Person",
      "preferredUsername" => "dave",
      "inbox" => actor_id <> "/inbox",
      "outbox" => actor_id <> "/outbox"
    })

    assert {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: actor_id)
    assert {:ok, %Object{authenticated: :fetched}} = Object.get_uncached(ap_id: actor_id)
  end

  # actors stored before they were marked, and any refetch of one: what we hold is what its origin served
  test "an actor we hold is marked as fetched when it is fetched again", %{actor_id: actor_id} do
    assert {:ok, %Object{authenticated: nil} = stored} = Object.get_uncached(ap_id: actor_id)

    served(%{stored.data | "name" => "renamed"} |> Map.put("name", "renamed"))

    assert {:ok, _} = ActivityPub.Actor.update_actor(actor_id, nil, true)

    assert {:ok, %Object{authenticated: :fetched, data: %{"name" => "renamed"}}} =
             Object.get_uncached(ap_id: actor_id)
  end

  test "a fetched document with no proof is stored as before", %{actor_id: actor_id} do
    unsigned = actor_id |> note() |> served()

    assert {:ok, _} = Fetcher.fetch_object_from_id(unsigned["id"])

    assert {:ok, %Object{authenticated: :fetched, data_received: nil}} =
             Object.get_uncached(ap_id: unsigned["id"])
  end
end
