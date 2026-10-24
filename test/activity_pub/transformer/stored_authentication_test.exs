defmodule ActivityPub.Federator.Transformer.StoredAuthenticationTest do
  @moduledoc """
  What is stored on `ap_object.authenticated` for a document, and for the object it carries, when it arrives:

    * a delivery says how it was vouched for (`authenticated:` and `signed_by:` in the options), and each document has its own value
    * an object inside a `Create` has the activity's value when it belongs to the activity's actor and the activity was vouched for as that actor (the signature covers the whole document); otherwise it stands on its own proof, or is `unverified`
    * a delivery nobody vouched for is `unverified`
    * a document we fetched ourselves is `fetched`
    * a document that is ours, or that came by no delivery, has none
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Object

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    n = System.unique_integer([:positive])
    %{n: n, sender: person("https://sender-#{n}.example/users/sender")}
  end

  defp person(id) do
    key = new_key(:ed25519)
    actor(ap_id: id, data: %{"assertionMethod" => [multikey(id, key)]})
    %{id: id, key: key}
  end

  defp create_of(sender, owner) do
    n = System.unique_integer([:positive])

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{sender.id}/activities/#{n}",
      "type" => "Create",
      "actor" => sender.id,
      "to" => [@public],
      "object" => %{
        "id" => "#{owner.id}/notes/#{n}",
        "type" => "Note",
        "attributedTo" => owner.id,
        "content" => "<p>stored #{n}</p>",
        "to" => [@public]
      }
    }
  end

  # the row, past the cache
  defp row(ap_id) do
    {:ok, %Object{id: id}} = Object.get_cached(ap_id: ap_id)
    ActivityPub.Utils.repo().get!(Object, id)
  end

  describe "a delivered Create" do
    test "is stored as vouched for, and its same-owner object the same way", %{sender: sender} do
      create = create_of(sender, sender)

      assert {:ok, _} =
               Transformer.handle_incoming(create,
                 from_inbox: true,
                 authenticated: :http_signature,
                 signed_by: sender.id
               )

      assert row(create["id"]).authenticated == :http_signature
      assert row(create["object"]["id"]).authenticated == :http_signature
    end

    test "has an object of somebody else without a proof of its own stored as unverified", %{
      n: n,
      sender: sender
    } do
      author = person("https://author-#{n}.example/users/author")
      create = create_of(sender, author)

      assert {:ok, _} =
               Transformer.handle_incoming(create,
                 from_inbox: true,
                 authenticated: :http_signature,
                 signed_by: sender.id
               )

      assert row(create["id"]).authenticated == :http_signature
      assert row(create["object"]["id"]).authenticated == :unverified
    end

    test "has an object of somebody else with a valid proof stored as vouched for by it", %{
      n: n,
      sender: sender
    } do
      author = person("https://author-#{n}.example/users/author")
      create = create_of(sender, author)
      create = Map.update!(create, "object", &sign(&1, author.key))

      assert {:ok, _} =
               Transformer.handle_incoming(create,
                 from_inbox: true,
                 authenticated: :http_signature,
                 signed_by: sender.id
               )

      assert row(create["object"]["id"]).authenticated == :integrity_proof
    end

    test "nobody vouched for is stored as unverified, the object too", %{sender: sender} do
      create = create_of(sender, sender)

      assert {:ok, _} = Transformer.handle_incoming(create, from_inbox: true)

      assert row(create["id"]).authenticated == :unverified
      assert row(create["object"]["id"]).authenticated == :unverified
    end
  end

  test "an object we fetched ourselves is stored as fetched", %{sender: sender} do
    note = create_of(sender, sender)["object"]

    Tesla.Mock.mock(fn %{method: :get, url: url} ->
      if url == note["id"],
        do: Tesla.Mock.json(Map.put(note, "@context", "https://www.w3.org/ns/activitystreams")),
        else: %Tesla.Env{status: 404, body: ""}
    end)

    assert {:ok, _} = Fetcher.fetch_object_from_id(note["id"])

    assert row(note["id"]).authenticated == :fetched
  end

  test "an activity of ours, which no delivery brought, has none", %{sender: sender} do
    assert {:ok, activity} =
             ActivityPub.create(%{
               to: [@public],
               actor: ActivityPub.Actor.get_cached!(ap_id: sender.id),
               context: "stored-authentication-test",
               object: %{"content" => "ours", "type" => "Note"}
             })

    assert row(activity.data["id"]).authenticated == nil
  end
end
