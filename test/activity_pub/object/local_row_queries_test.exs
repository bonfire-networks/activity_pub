defmodule ActivityPub.Object.LocalRowQueriesTest do
  @moduledoc """
  A local object is stored with its signed public form, and `data` only a patch over it (plan step 10.2), as a received signed one is. So every query that reads inside `data` must find it too. `signed_row_queries_test.exs` does this for rows stored as received; these rows are made through `ActivityPub.create`, as a local post is.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import Ecto.Query

  alias ActivityPub.Object

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    author = local_actor()
    {:ok, actor} = ActivityPub.Actor.get_cached(username: author.username)
    {:ok, actor} = ActivityPub.Safety.Keys.ensure_keys_present(actor)
    other = local_actor()
    {:ok, other} = ActivityPub.Actor.get_cached(username: other.username)
    {:ok, other} = ActivityPub.Safety.Keys.ensure_keys_present(other)
    %{actor: actor, other: other}
  end

  # a local Create; its activity and its object's row are returned
  defp create!(actor, object \\ %{}, params \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, activity} =
      ActivityPub.create(
        Map.merge(
          %{
            actor: actor,
            context: "#{actor.ap_id}/contexts/#{n}",
            to: [@public],
            object:
              Map.merge(
                %{
                  "id" => "#{actor.ap_id}/objects/#{n}",
                  "type" => "Note",
                  "attributedTo" => actor.ap_id,
                  "content" => "post #{n}",
                  "to" => [@public]
                },
                object
              )
          },
          params
        )
      )

    {:ok, row} = Object.get_uncached(ap_id: activity.data["object"])
    assert %{"proof" => _} = row.data_received
    {activity, row}
  end

  defp raw(%Object{id: id}),
    do: repo().one(from(o in Object, where: o.id == ^id, select: o.data))

  defp ids(objects), do: Enum.map(objects, & &1.data["id"])

  test "the row's data is a patch, and the queried fields are in it", %{actor: actor} do
    {_activity, row} = create!(actor)

    patch = raw(row)
    refute Map.has_key?(patch, "content")
    for key <- ["id", "type", "to"], do: assert(Map.has_key?(patch, key), "patch lacks #{key}")
  end

  test "by its id", %{actor: actor} do
    {_activity, row} = create!(actor)
    id = row.data["id"]
    assert {:ok, %Object{data: %{"id" => ^id}}} = Object.get_uncached(ap_id: id)
  end

  test "by its url, when it differs from its id", %{actor: actor} do
    url = "#{actor.ap_id}/page/#{System.unique_integer([:positive])}"
    {_activity, row} = create!(actor, %{"url" => url})
    id = row.data["id"]

    assert {:ok, %Object{data: %{"id" => ^id}}} = Object.get_uncached(ap_id: url)
  end

  test "the replies to a post", %{actor: actor, other: other} do
    {_activity, post} = create!(actor)
    {_activity, reply} = create!(other, %{"inReplyTo" => post.data["id"]})

    assert Object.replies_ids(post, 10) == [reply.data["id"]]
  end

  test "the Create of the object", %{actor: actor} do
    {activity, row} = create!(actor)
    id = activity.data["id"]

    assert %Object{data: %{"id" => ^id}} = Object.get_activity_for_object_ap_id(row.data["id"])
  end

  test "the actor's outbox", %{actor: actor} do
    {activity, _row} = create!(actor)
    assert activity.data["id"] in ids(Object.get_outbox_for_actor(actor))
  end

  test "another actor's inbox, by an addressing field", %{actor: actor, other: other} do
    {to, _row} = create!(actor, %{"to" => [other.ap_id]}, %{to: [other.ap_id]})
    {bcc, _row} = create!(actor, %{"to" => [], "bcc" => [other.ap_id]}, %{to: [], bcc: [other.ap_id]})

    listed = ids(Object.get_inbox_for_actor(other.ap_id))
    assert to.data["id"] in listed
    assert bcc.data["id"] in listed
  end

  test "a like of it", %{actor: actor, other: other} do
    {_activity, row} = create!(actor)
    {:ok, like} = ActivityPub.like(%{actor: other, object: row, local: true})
    id = like.data["id"]

    assert %Object{data: %{"id" => ^id}} = Object.get_existing_like(other.ap_id, row.data["id"])
  end

  test "an announce of it", %{actor: actor, other: other} do
    {_activity, row} = create!(actor)
    {:ok, boost} = ActivityPub.announce(%{actor: other, object: row, local: true})
    id = boost.data["id"]

    assert %Object{data: %{"id" => ^id}} = Object.get_existing_announce(other.ap_id, row)
  end

  test "after a change (a reply count), it is still found by id and as a reply", %{
    actor: actor,
    other: other
  } do
    {_activity, post} = create!(actor)
    {_activity, reply} = create!(other, %{"inReplyTo" => post.data["id"]})

    assert {:ok, _} =
             Object.do_update_existing(post, %{data: Map.put(post.data, "replies_count", 1)})

    id = post.data["id"]
    assert {:ok, %Object{data: %{"id" => ^id}}} = Object.get_uncached(ap_id: id)
    assert Object.replies_ids(post, 10) == [reply.data["id"]]
  end

  # the pruner's thread mode reads the `context` of every row of a thread, a local one included; it is the same in the original as in `data`, so the patch holds none
  test "a remote thread with a recent local reply keeps its old post", %{actor: actor} do
    n = System.unique_integer([:positive])
    context = "https://remote-#{n}.local/contexts/#{n}"
    old = NaiveDateTime.utc_now() |> NaiveDateTime.add(-60 * 86_400) |> NaiveDateTime.truncate(:second)

    {:ok, remote} =
      %{
        data: %{
          "id" => "https://remote-#{n}.local/notes/1",
          "type" => "Note",
          "actor" => "https://remote-#{n}.local/users/alice",
          "context" => context
        },
        local: false,
        is_object: true
      }
      |> Object.changeset()
      |> repo().insert()

    repo().update_all(from(o in Object, where: o.id == ^remote.id), set: [updated_at: old])

    {_activity, reply} =
      create!(actor, %{"inReplyTo" => remote.data["id"]}, %{context: context})

    refute Map.has_key?(raw(reply), "context"),
           "the patch holds the context, so this does not test the coalesce"

    ActivityPub.Pruner.prune_objects(keep_threads: true, remote_post_retention_days: 30)

    assert repo().exists?(from(o in Object, where: o.id == ^remote.id))
  end
end
