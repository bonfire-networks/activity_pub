defmodule ActivityPub.Federator.ActorUpdateWithoutRefetchTest do
  @moduledoc """
  An actor's `Update` of itself is applied from the document it carries, with no refetch, when the actor vouched for it with what we already hold of it: the delivery's HTTP signature by the actor (checked with the key we hold, not one the new document carries, so an `Update` that rotates the key is judged by the old one), or the document's own proof, checked with that key. Otherwise the actor is fetched again from its origin, as before. A first-seen actor is always fetched: its own signature shows only that it was signed by the key it names.

  Its origin serves nothing here, so an actor updated from the document cannot have come from a refetch.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers
  import Tesla.Mock

  alias ActivityPub.Object
  alias ActivityPub.Federator.Transformer

  @context [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/data-integrity/v2"
  ]

  setup do
    n = System.unique_integer([:positive])
    key = new_key(:ed25519)
    actor_id = "https://held-#{n}.local/users/alice"
    actor(ap_id: actor_id, data: %{"assertionMethod" => [multikey(actor_id, key)]})
    {:ok, %Object{data: held}} = Object.get_uncached(ap_id: actor_id)

    stranger = "https://stranger-#{n}.local/users/mallory"
    actor(ap_id: stranger)

    # its origin serves nothing
    mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    %{actor_id: actor_id, key: key, held: held, stranger: stranger}
  end

  defp actor_update(actor_id, document) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{actor_id}#updates/#{System.unique_integer([:positive])}",
      "type" => "Update",
      "actor" => actor_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "object" => document
    }
  end

  defp delivered(activity, opts),
    do: Transformer.handle_incoming(activity, [from_inbox: true] ++ opts)

  defp name(actor_id) do
    {:ok, %Object{data: data}} = Object.get_uncached(ap_id: actor_id)
    data["name"]
  end

  test "signed over HTTP by the actor itself: applied from the document", %{
    actor_id: actor_id,
    held: held
  } do
    delivered(actor_update(actor_id, %{held | "name" => "Alice renamed"}),
      authenticated: :http_signature,
      signed_by: actor_id
    )

    assert name(actor_id) == "Alice renamed"
  end

  test "rotating its key, signed with the key we hold: applied, new key included", %{
    actor_id: actor_id,
    held: held
  } do
    rotated = Map.put(held, "assertionMethod", [multikey(actor_id, new_key(:ed25519))])

    delivered(actor_update(actor_id, rotated),
      authenticated: :http_signature,
      signed_by: actor_id
    )

    {:ok, %Object{data: data}} = Object.get_uncached(ap_id: actor_id)
    assert data["assertionMethod"] == rotated["assertionMethod"]
  end

  test "its document carrying its own proof, by the key we hold: applied, whoever delivered it",
       %{actor_id: actor_id, held: held, key: key, stranger: stranger} do
    signed =
      held
      |> Map.put("name", "Alice signed")
      |> Map.put("@context", @context)
      |> sign(key, verification_method: actor_id <> "#ed25519-key")

    delivered(actor_update(actor_id, signed), authenticated: :http_signature, signed_by: stranger)

    assert name(actor_id) == "Alice signed"
  end

  test "delivered by somebody else, with no proof of its own: not applied", %{
    actor_id: actor_id,
    held: held,
    stranger: stranger
  } do
    delivered(actor_update(actor_id, %{held | "name" => "Alice forged"}),
      authenticated: :http_signature,
      signed_by: stranger
    )

    assert name(actor_id) == held["name"]
  end

  test "vouched for by nobody: not applied", %{actor_id: actor_id, held: held} do
    delivered(actor_update(actor_id, %{held | "name" => "Alice forged"}),
      authenticated: :unverified
    )

    assert name(actor_id) == held["name"]
  end

  test "an actor we do not hold: not stored from the document" do
    newcomer = "https://new-#{System.unique_integer([:positive])}.local/users/carol"

    delivered(
      actor_update(newcomer, %{
        "id" => newcomer,
        "type" => "Person",
        "preferredUsername" => "carol",
        "inbox" => newcomer <> "/inbox"
      }),
      authenticated: :http_signature,
      signed_by: newcomer
    )

    assert {:error, :not_found} = Object.get_uncached(ap_id: newcomer)
  end
end
