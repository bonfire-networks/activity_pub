defmodule ActivityPub.Federator.Transformer.IncomingUpdateIdTest do
  @moduledoc """
  An `Update` from another instance is stored under the id its author gave it, as every other activity is.

  A local id would put an activity of theirs on our host (FEP-fe34: an id belongs to its actor's origin), so relaying it as a group, or finding it again by the id the author used, would not work.
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
      "content" => "<p>first</p>",
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

  defp update_of(%{author_id: author_id, note: note}, content) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{author_id}/activities/update-#{System.unique_integer([:positive])}",
      "type" => "Update",
      "actor" => author_id,
      "to" => [@public],
      "object" => Map.put(note, "content", content)
    }
  end

  test "is stored under the author's id", context do
    update = update_of(context, "<p>edited</p>")
    assert {:ok, _} = delivered(update)

    assert {:ok, %Object{data: %{"type" => "Update"}}} = Object.get_cached(ap_id: update["id"])

    assert %Object{data: %{"id" => id}} =
             Object.get_activity_for_object_ap_id(context.note["id"], "Update")

    assert id == update["id"]
  end

  test "is stored as the author sent it, not rebuilt", %{author_id: author_id} = context do
    update =
      context
      |> update_of("<p>edited</p>")
      |> Map.put("cc", ["#{author_id}/followers"])
      |> Map.put("published", "2026-10-24T09:00:00Z")

    assert {:ok, _} = delivered(update)

    assert {:ok, %Object{data: stored}} = Object.get_cached(ap_id: update["id"])
    assert stored["cc"] == update["cc"], "rebuilt, it loses `cc`"
    assert stored["published"] == update["published"]
    assert stored["actor"] == author_id
  end

  test "delivered twice, is stored once, and the second delivery is not an error", context do
    update = update_of(context, "<p>edited</p>")

    assert {:ok, _} = delivered(update)
    assert {:ok, _} = delivered(update)

    assert {:ok, %Object{data: %{"content" => "<p>edited</p>"}}} =
             Object.get_cached(ap_id: context.note["id"])
  end

  test "two edits are two Updates, each under its own id", context do
    first = update_of(context, "<p>edited once</p>")
    second = update_of(context, "<p>edited twice</p>")

    assert {:ok, _} = delivered(first)
    assert {:ok, _} = delivered(second)

    for update <- [first, second],
        do:
          assert(
            {:ok, %Object{data: %{"type" => "Update"}}} = Object.get_cached(ap_id: update["id"])
          )

    assert {:ok, %Object{data: %{"content" => "<p>edited twice</p>"}}} =
             Object.get_cached(ap_id: context.note["id"])
  end
end
