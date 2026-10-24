defmodule ActivityPub.Federator.Transformer.ReceivedEditHistoryTest do
  @moduledoc """
  The edit history a received object carries (`formerRepresentations`, Pleroma's and Akkoma's way of federating an edited object with its earlier versions inside it) is dropped on receipt, unless `keep_received_edit_history: true`. Nothing here reads it, and the origin still has it.
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
      "content" => "<p>edited</p>",
      "to" => [@public],
      "formerRepresentations" => %{
        "type" => "OrderedCollection",
        "totalItems" => 1,
        "orderedItems" => [
          %{
            "type" => "Note",
            "attributedTo" => author_id,
            "content" => "<p>first</p>",
            "to" => [@public]
          }
        ]
      }
    }

    create = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{author_id}/activities/create-#{n}",
      "type" => "Create",
      "actor" => author_id,
      "to" => [@public],
      "object" => note
    }

    %{note: note, create: create}
  end

  defp delivered(create),
    do:
      Transformer.handle_incoming(create,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: create["actor"]
      )

  defp stored(%{"id" => id}) do
    assert {:ok, %Object{data: data}} = Object.get_cached(ap_id: id)
    data
  end

  test "is dropped by default", %{note: note, create: create} do
    assert {:ok, _} = delivered(create)

    refute Map.has_key?(stored(note), "formerRepresentations")
    assert stored(note)["content"] == "<p>edited</p>", "the object itself is kept"
  end

  test "is kept with keep_received_edit_history: true", %{note: note, create: create} do
    clear_config([:keep_received_edit_history], true)

    assert {:ok, _} = delivered(create)

    assert %{"orderedItems" => [%{"content" => "<p>first</p>"}]} =
             stored(note)["formerRepresentations"]
  end
end
