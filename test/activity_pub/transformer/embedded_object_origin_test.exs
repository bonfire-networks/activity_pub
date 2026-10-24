defmodule ActivityPub.Federator.Transformer.EmbeddedObjectOriginTest do
  @moduledoc """
  FEP-fe34: an object's id has to be on the origin of its owner (`attributedTo`). Without that, whoever's origin the id is on could put words in the owner's mouth, and a proof or a signature on the delivery would not say otherwise. So an object embedded in a delivered `Create` whose id is on another origin than its owner's is not stored, whoever delivered it and whatever proof it carries.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

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

  # a Create by `sender` of a note attributed to `owner`, whose id is where the test says
  defp create_of(sender, owner, note_id) do
    n = System.unique_integer([:positive])

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{sender.id}/activities/#{n}",
      "type" => "Create",
      "actor" => sender.id,
      "to" => [@public],
      "object" => %{
        "id" => note_id,
        "type" => "Note",
        "attributedTo" => owner,
        "content" => "<p>origin #{n}</p>",
        "to" => [@public]
      }
    }
  end

  defp deliver(create, sender),
    do:
      Transformer.handle_incoming(create,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: sender.id
      )

  defp stored?(note_id), do: match?({:ok, %Object{}}, Object.get_cached(ap_id: note_id))

  test "an object of the sender on another origin is not stored", %{n: n, sender: sender} do
    note_id = "https://elsewhere-#{n}.example/notes/#{n}"

    assert {:error, _} = deliver(create_of(sender, sender.id, note_id), sender)
    refute stored?(note_id)
  end

  test "an object of somebody else on the sender's origin is not stored, whatever proof it has",
       %{
         n: n,
         sender: sender
       } do
    author = person("https://author-#{n}.example/users/author")
    note_id = "#{sender.id}/notes/#{n}"

    create =
      sender
      |> create_of(author.id, note_id)
      |> Map.update!("object", &sign(&1, author.key))

    assert {:error, _} = deliver(create, sender)
    refute stored?(note_id)
  end

  test "an object of somebody else on the sender's origin with no proof is not stored either", %{
    n: n,
    sender: sender
  } do
    author = "https://author-#{n}.example/users/author"
    note_id = "#{sender.id}/notes/#{n}"

    assert {:error, _} = deliver(create_of(sender, author, note_id), sender)
    refute stored?(note_id)
  end

  test "an object of somebody else on that somebody's origin is stored", %{n: n, sender: sender} do
    author = person("https://author-#{n}.example/users/author")
    note_id = "#{author.id}/notes/#{n}"

    create =
      sender
      |> create_of(author.id, note_id)
      |> Map.update!("object", &sign(&1, author.key))

    assert {:ok, _} = deliver(create, sender)
    assert stored?(note_id)
  end

  test "an object of the sender on the sender's origin is stored", %{n: n, sender: sender} do
    note_id = "#{sender.id}/notes/#{n}"

    assert {:ok, _} = deliver(create_of(sender, sender.id, note_id), sender)
    assert stored?(note_id)
  end

  test "an object that names no owner is left to the rules for objects with no author", %{
    n: n,
    sender: sender
  } do
    note_id = "https://elsewhere-#{n}.example/notes/#{n}"

    create =
      sender
      |> create_of(sender.id, note_id)
      |> update_in(["object"], &Map.delete(&1, "attributedTo"))

    # not refused for its origin: there is no owner to compare with
    result = deliver(create, sender)
    refute match?({:error, "Object containment" <> _}, result)
  end
end
