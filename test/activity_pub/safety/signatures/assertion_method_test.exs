defmodule ActivityPub.Safety.AssertionMethodTest do
  @moduledoc """
  A local actor publishes its derived Ed25519 key (FEP-521a) as a `Multikey` in `assertionMethod`, which is where a verifier of an integrity proof (FEP-8b32) looks for it.

  It is merged into the entries the actor data already holds, matched by `id`, never written over them: clients with keys of their own (FEP-ae97) and identity keys (FEP-ef61) keep theirs. And the entry for our own key id is always the derived key, whatever the data holds under that id: FEP-fe34 says a server must not let a client set or change key objects, so nothing a user submits can take the place of our key.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Safety.Keys
  alias ActivityPub.Safety.Multibase

  setup do
    %{username: username} = local_actor()
    {:ok, actor} = ActivityPub.Actor.get_cached(username: username)

    {:ok, {public, _private}} = Keys.ed25519_keypair(actor)
    {:ok, actor} = ActivityPub.Actor.get_cached(username: username)

    %{actor: actor, id: actor.data["id"], public: public}
  end

  defp entry(actor, suffix),
    do: Enum.find(List.wrap(actor.data["assertionMethod"]), &String.ends_with?(&1["id"], suffix))

  defp with_assertion_method(actor, entries),
    do: put_in(actor.data["assertionMethod"], entries)

  describe "the entry for our own key" do
    test "is a Multikey whose controller is the actor", %{actor: actor, id: id} do
      published = Keys.add_public_key(actor)

      assert %{"id" => key_id, "type" => "Multikey", "controller" => ^id} =
               entry(published, "#ed25519-key")

      assert key_id == id <> "#ed25519-key"
    end

    test "holds the derived public key, as a multibase", %{actor: actor, public: public} do
      published = Keys.add_public_key(actor)

      %{"publicKeyMultibase" => multibase} = entry(published, "#ed25519-key")

      assert String.starts_with?(multibase, "z6Mk"), "an Ed25519 Multikey, base58btc"
      assert Multibase.decode_multikey(multibase) == {:ok, {:ed25519, public}}
    end

    test "is there once, however often the actor is built", %{actor: actor, id: id} do
      published = actor |> Keys.add_public_key() |> Keys.add_public_key()

      assert [_one] =
               Enum.filter(published.data["assertionMethod"], &(&1["id"] == id <> "#ed25519-key"))
    end
  end

  describe "what the actor data already holds" do
    test "is kept, with ours added", %{actor: actor, id: id} do
      client_key = %{
        "id" => id <> "#client-key",
        "type" => "Multikey",
        "controller" => id,
        "publicKeyMultibase" => "z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK"
      }

      published = actor |> with_assertion_method([client_key]) |> Keys.add_public_key()

      assert client_key in published.data["assertionMethod"]
      assert entry(published, "#ed25519-key")
    end

    test "never takes the place of our key, whatever it says under our key id", %{
      actor: actor,
      id: id,
      public: public
    } do
      crafted = %{
        "id" => id <> "#ed25519-key",
        "type" => "Multikey",
        "controller" => id,
        "publicKeyMultibase" => "z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK"
      }

      published = actor |> with_assertion_method([crafted]) |> Keys.add_public_key()

      assert [only] = Enum.filter(published.data["assertionMethod"], &(&1["id"] == crafted["id"]))
      assert Multibase.decode_multikey(only["publicKeyMultibase"]) == {:ok, {:ed25519, public}}
    end
  end

  test "an actor that is not ours gets no key of ours", %{actor: actor} do
    remote = %{actor | local: false}

    assert Keys.add_public_key(remote) == remote
  end

  test "the rendered actor lists the key, and names the context that defines the term" do
    %{username: username} = local_actor()
    {:ok, actor} = ActivityPub.Actor.get_cached(username: username)

    json = ActivityPub.Web.ActorView.render("actor.json", %{actor: actor})

    assert Enum.any?(json["assertionMethod"], &(&1["type"] == "Multikey"))
    assert "https://www.w3.org/ns/cid/v1" in List.wrap(json["@context"])
  end
end
