defmodule ActivityPub.Federator.Transformer.IncomingDeleteIdTest do
  @moduledoc """
  A `Delete` from another instance is stored as its author sent it, under the id they gave it, as an `Update` is: the deletion still happens as before, only the activity recorded for it is theirs rather than one we rebuild with an id on our host.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Object
  alias ActivityPub.Federator.Transformer

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    n = System.unique_integer([:positive])
    author_id = "https://author-#{n}.example/users/author"
    actor(ap_id: author_id)

    note = %{
      "id" => "#{author_id}/objects/#{n}",
      "type" => "Note",
      "attributedTo" => author_id,
      "content" => "<p>about to go</p>",
      "to" => [@public]
    }

    assert {:ok, _} =
             delivered(%{
               "@context" => "https://www.w3.org/ns/activitystreams",
               "id" => "#{author_id}/activities/create-#{n}",
               "type" => "Create",
               "actor" => author_id,
               "to" => [@public],
               "object" => note
             })

    %{author_id: author_id, note: note}
  end

  defp delivered(document),
    do:
      Transformer.handle_incoming(document,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: document["actor"]
      )

  defp delete_of(%{author_id: author_id, note: note}) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{author_id}/activities/delete-#{System.unique_integer([:positive])}",
      "type" => "Delete",
      "actor" => author_id,
      "to" => [@public],
      "cc" => ["#{author_id}/followers"],
      "object" => note["id"]
    }
  end

  test "is stored under the author's id, as they sent it", context do
    delete = delete_of(context)
    assert {:ok, _} = delivered(delete)

    assert {:ok, %Object{data: stored}} = Object.get_cached(ap_id: delete["id"])
    assert stored["type"] == "Delete"
    assert stored["actor"] == context.author_id
    assert stored["cc"] == delete["cc"], "rebuilt, it gets the post's addressing instead"
  end

  test "still deletes the post", context do
    assert {:ok, _} = delivered(delete_of(context))

    assert {:ok, %Object{data: %{"type" => "Tombstone"}}} =
             Object.get_cached(ap_id: context.note["id"])
  end
end
