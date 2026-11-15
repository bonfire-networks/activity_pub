defmodule ActivityPub.Federator.FetchedIdHostTest do
  @moduledoc """
  A fetched document is taken only if its `id` is on the host it was fetched from (after redirects). One served from another host is taken only when its `id`'s own host serves the same document, or it carries a proof that holds: by its attributed actor (an object), or with the key we hold (an actor we already know).
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers
  import Tesla.Mock

  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Object

  @context [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/data-integrity/v2"
  ]

  setup do
    n = System.unique_integer([:positive])
    %{n: n, home: "https://home-#{n}.example", other: "https://other-#{n}.example"}
  end

  # `routes`: requested url => {document, url it ends on}, or nil for a 404. Responses carry the final url, as a real adapter sets it.
  defp serve(routes) do
    mock(fn
      %{method: :get, url: url} ->
        case routes[url] do
          {document, final_url} ->
            %{
              json(document, headers: [{"content-type", "application/activity+json"}])
              | url: final_url
            }

          nil ->
            %Tesla.Env{status: 404, body: "", url: url}
        end
    end)
  end

  defp note(id, actor_id) do
    actor_id
    |> create_note()
    |> Map.fetch!("object")
    |> Map.merge(%{"id" => id, "@context" => @context, "published" => "2015-03-01T12:00:00Z"})
  end

  describe "an id on another host than the fetch" do
    test "is taken when its own host serves the same document, also after a redirect", %{
      home: home,
      other: other
    } do
      doc = note(other <> "/notes/1", other <> "/users/alice")
      serve(%{(home <> "/x") => {doc, home <> "/x"}, doc["id"] => {doc, doc["id"]}})
      assert {:ok, %{"id" => id}} = Fetcher.fetch_remote_object_from_id(home <> "/x")
      assert id == doc["id"]

      serve(%{
        (home <> "/x") => {doc, "https://moved-#{System.unique_integer([:positive])}.example/y"},
        doc["id"] => {doc, doc["id"]}
      })

      assert {:ok, %{"id" => ^id}} = Fetcher.fetch_remote_object_from_id(home <> "/x")
    end

    test "is refused when its own host serves another id, or nothing", %{home: home, other: other} do
      doc = note(other <> "/notes/1", other <> "/users/alice")
      different = Map.put(doc, "id", other <> "/notes/2")

      serve(%{(home <> "/x") => {doc, home <> "/x"}, doc["id"] => {different, doc["id"]}})
      assert {:error, _} = Fetcher.fetch_remote_object_from_id(home <> "/x")

      serve(%{(home <> "/x") => {doc, home <> "/x"}})
      assert {:error, _} = Fetcher.fetch_remote_object_from_id(home <> "/x")
    end

    test "is refused when it is an id of this instance, with no fetch from there", %{home: home} do
      local_id = ActivityPub.Web.base_url() <> "/pub/objects/abc"
      doc = note(local_id, home <> "/users/alice")
      serve(%{(home <> "/x") => {doc, home <> "/x"}})

      assert {:error, :local_id_claimed} = Fetcher.fetch_remote_object_from_id(home <> "/x")
    end
  end

  describe "an object served from another host" do
    setup %{other: other} do
      key = new_key(:ed25519)
      actor_id = other <> "/users/alice"
      actor(ap_id: actor_id, data: %{"assertionMethod" => [multikey(actor_id, key)]})
      %{key: key, actor_id: actor_id}
    end

    test "is taken with a valid proof by its attributed actor", %{
      home: home,
      key: key,
      actor_id: actor_id,
      other: other
    } do
      signed = (other <> "/notes/1") |> note(actor_id) |> sign(key)
      serve(%{(home <> "/x") => {signed, home <> "/x"}})

      assert {:ok, %{"id" => id}} = Fetcher.fetch_remote_object_from_id(home <> "/x")
      assert id == signed["id"]
    end

    test "is refused with a proof made by another key", %{
      home: home,
      actor_id: actor_id,
      other: other
    } do
      forged = (other <> "/notes/1") |> note(actor_id) |> sign(new_key(:ed25519))
      serve(%{(home <> "/x") => {forged, home <> "/x"}})

      assert {:error, _} = Fetcher.fetch_remote_object_from_id(home <> "/x")
    end

    test "is refused with a proof that no longer matches the document", %{
      home: home,
      key: key,
      actor_id: actor_id,
      other: other
    } do
      tampered =
        (other <> "/notes/1") |> note(actor_id) |> sign(key) |> Map.put("content", "edited")

      serve(%{(home <> "/x") => {tampered, home <> "/x"}})

      assert {:error, _} = Fetcher.fetch_remote_object_from_id(home <> "/x")
    end
  end

  describe "an actor served from another host" do
    setup %{other: other} do
      key = new_key(:ed25519)
      actor_id = other <> "/users/alice"
      actor(ap_id: actor_id, data: %{"assertionMethod" => [multikey(actor_id, key)]})
      {:ok, %Object{data: held}} = Object.get_cached(ap_id: actor_id)
      %{key: key, actor_id: actor_id, held: Map.delete(held, "proof")}
    end

    test "is taken when signed with the key we hold", %{
      home: home,
      key: key,
      actor_id: actor_id,
      held: held
    } do
      signed =
        held
        |> Map.put("@context", @context)
        |> Map.put("name", "renamed")
        |> sign(key, verification_method: actor_id <> "#ed25519-key")

      serve(%{(home <> "/x") => {signed, home <> "/x"}})

      assert {:ok, %{"id" => ^actor_id, "name" => "renamed"}} =
               Fetcher.fetch_remote_object_from_id(home <> "/x")
    end

    test "is refused when signed with an attacker's key", %{
      home: home,
      actor_id: actor_id,
      held: held
    } do
      attacker = new_key(:ed25519)

      forged =
        held
        |> Map.put("@context", @context)
        |> Map.put("name", "spoofed")
        |> Map.put("assertionMethod", [multikey(actor_id, attacker)])
        |> sign(attacker, verification_method: actor_id <> "#ed25519-key")

      serve(%{(home <> "/x") => {forged, home <> "/x"}})

      assert {:error, _} = Fetcher.fetch_remote_object_from_id(home <> "/x")
    end

    test "is refused when we do not hold the actor, even if self-signed", %{home: home, n: n} do
      key = new_key(:ed25519)
      unknown_id = "https://stranger-#{n}.example/users/bob"

      self_signed =
        %{
          "@context" => @context,
          "id" => unknown_id,
          "type" => "Person",
          "preferredUsername" => "bob",
          "inbox" => unknown_id <> "/inbox",
          "outbox" => unknown_id <> "/outbox",
          "assertionMethod" => [multikey(unknown_id, key)]
        }
        |> sign(key, verification_method: unknown_id <> "#ed25519-key")

      serve(%{(home <> "/x") => {self_signed, home <> "/x"}})

      assert {:error, _} = Fetcher.fetch_remote_object_from_id(home <> "/x")
    end
  end
end
