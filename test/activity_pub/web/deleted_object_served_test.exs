defmodule ActivityPub.Web.DeletedObjectServedTest do
  @moduledoc """
  A deleted object is served as a Tombstone to anyone who asks for it, public or not (`maybe_object_json`), so a server that missed the `Delete` can learn the object is gone. The Tombstone says only that: its id, what it was (`formerType`) and when it was deleted, never the content of a post that was held signed by its author.
  """
  use ActivityPub.Web.ConnCase, async: false

  # these tests check what is served, not who may fetch it (that is `signed_fetch_gate_test.exs`), so they fetch unsigned, under the library's own default, whatever the app's config says
  setup do
    clear_config([:reject_unsigned], false)
  end

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers
  import Plug.Conn
  import Phoenix.ConnTest

  alias ActivityPub.Federator.Worker.ReceiverHelpers
  alias ActivityPub.Object

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    n = System.unique_integer([:positive])
    key = new_key(:ed25519)
    author_id = "https://author-#{n}.example/users/author"
    actor(ap_id: author_id, data: %{"assertionMethod" => [multikey(author_id, key)]})
    Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)
    %{key: key, author_id: author_id}
  end

  # a signed post in a signed Create, over its author's verified HTTP signature, as the receiver worker gets it; held with its original
  defp received_note(%{key: key, author_id: author_id}, to) do
    content = "<p>to be deleted #{System.unique_integer([:positive])}</p>"
    %{"object" => note} = create = create_note(author_id, content)
    note = note |> Map.put("to", to) |> sign(key)
    create = create |> Map.put("to", to) |> Map.put("object", note) |> sign(key)

    assert {:ok, _} =
             ReceiverHelpers.perform(
               %Oban.Job{
                 args: %{
                   "op" => "incoming_ap_doc",
                   "params" => create,
                   "signed_by" => author_id,
                   "repo" => ActivityPub.Utils.repo()
                 }
               },
               :verified
             )

    %{note: note, content: content}
  end

  defp deleted_by(author_id, object_id) do
    ActivityPub.Federator.Transformer.handle_incoming(
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{author_id}/activities/delete-#{System.unique_integer([:positive])}",
        "type" => "Delete",
        "actor" => author_id,
        "to" => [@public],
        "object" => object_id
      },
      from_inbox: true,
      authenticated: :http_signature,
      signed_by: author_id
    )
  end

  # the route finds an object by the pointer its adapter gave it; a real pointer, as `object_list_cached_test.exs` does
  defp with_pointer(object_id) do
    pointer_id = local_actor().user.id
    {:ok, row} = Object.get_uncached(ap_id: object_id)

    {:ok, _} =
      ActivityPub.Utils.repo().get(Object, row.id)
      |> Ecto.Changeset.change(%{pointer_id: pointer_id})
      |> ActivityPub.Utils.repo().update()

    pointer_id
  end

  defp get_it(pointer_id) do
    build_conn()
    |> put_req_header("accept", "application/activity+json")
    |> get("/pub/objects/#{pointer_id}")
  end

  for followers_only? <- [false, true] do
    test "a deleted post is served as a bare Tombstone, followers only: #{followers_only?}",
         %{
           author_id: author_id
         } = context do
      followers_only? = unquote(followers_only?)
      to = if followers_only?, do: ["#{author_id}/followers"], else: [@public]
      %{note: note, content: content} = received_note(context, to)
      pointer_id = with_pointer(note["id"])

      # control: before the delete, a public post is served as its author sent it, and a followers-only one is not served
      if followers_only?,
        do: assert(get_it(pointer_id).status == 401),
        else: assert(json_response(get_it(pointer_id), 200) == note)

      assert {:ok, _} = deleted_by(author_id, note["id"])

      resp = json_response(get_it(pointer_id), 200)

      assert resp["type"] == "Tombstone"
      assert resp["id"] == note["id"]
      refute Jason.encode!(resp) =~ content
    end
  end
end
