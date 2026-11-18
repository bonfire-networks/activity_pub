defmodule ActivityPub.Federator.Transformer.IncomingOwnHostIdTest do
  @moduledoc """
  A document from another instance that names itself with an id on OUR host is not stored as theirs.

  An id belongs to its actor's origin (FEP-fe34), so one on our host is ours to mint. Stored as a remote copy, it then stands in for what we hold under that id: our own group actor stored this way made every incoming `Join` to the group fail, since its URL found the copy before the group.
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

    %{author_id: author_id, n: n}
  end

  defp delivered(document),
    do:
      Transformer.handle_incoming(document,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: document["actor"]
      )

  defp create(author_id, id, object_id) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => id,
      "type" => "Create",
      "actor" => author_id,
      "to" => [@public],
      "object" => %{
        "id" => object_id,
        "type" => "Note",
        "attributedTo" => author_id,
        "content" => "<p>hello</p>",
        "to" => [@public]
      }
    }
  end

  test "an activity from elsewhere under an id on our host is not stored", %{
    author_id: author_id,
    n: n
  } do
    ours = "#{ActivityPub.Web.base_url()}/pub/objects/#{Ecto.UUID.generate()}"

    delivered(create(author_id, ours, "#{author_id}/objects/#{n}"))

    assert {:error, :not_found} = Object.get_cached(ap_id: ours)
  end

  test "an object from elsewhere under an id on our host is not stored", %{
    author_id: author_id,
    n: n
  } do
    ours = "#{ActivityPub.Web.base_url()}/pub/objects/#{Ecto.UUID.generate()}"

    delivered(create(author_id, "#{author_id}/activities/create-#{n}", ours))

    assert {:error, :not_found} = Object.get_cached(ap_id: ours)
  end

  # the control: the same delivery under its sender's own ids is stored as always, so a missing row above is the guard's
  test "the same activity under its sender's ids is stored", %{author_id: author_id, n: n} do
    activity_id = "#{author_id}/activities/create-#{n}"
    object_id = "#{author_id}/objects/#{n}"

    assert {:ok, _} = delivered(create(author_id, activity_id, object_id))

    assert {:ok, %Object{local: false}} = Object.get_cached(ap_id: activity_id)
    assert {:ok, %Object{local: false}} = Object.get_cached(ap_id: object_id)
  end
end
