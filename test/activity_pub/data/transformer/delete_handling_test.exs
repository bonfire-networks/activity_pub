# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.DeleteHandlingTest do
  use ActivityPub.DataCase, async: false
  use Oban.Testing, repo: repo()

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object

  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Test.HttpRequestMock
  alias ActivityPub.Tests.ObanHelpers

  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  test "it works for incoming deletes" do
    activity = insert(:note_activity)
    deleting_user = local_actor()

    data =
      file("fixtures/mastodon/mastodon-delete.json")
      |> Jason.decode!()
      |> Map.put("actor", ap_id(deleting_user))
      |> put_in(["object", "id"], activity.data["object"])
      |> debug("dattta")

    {:ok, %Activity{local: false, data: %{"id" => id, "actor" => actor}}} =
      Transformer.handle_incoming(data)
      |> debug("handdddled")

    # assert id == data["id"]

    # We delete the Create activity because we base our timelines on it.
    # This should be changed after we unify objects and activities
    refute Activity.get_cached(id: activity.id)
    assert actor == ap_id(deleting_user)

    # Objects are replaced by a tombstone object.
    object = Object.normalize(activity.data["object"], fetch: false)
    assert object.data["type"] == "Tombstone"
  end

  test "it works for incoming when the object has been pruned" do
    activity = insert(:note_activity)

    {:ok, object} =
      Object.normalize(activity.data["object"], fetch: false)
      |> repo().delete()

    Object.invalidate_cache(object)

    deleting_user = local_actor()

    data =
      file("fixtures/mastodon/mastodon-delete.json")
      |> Jason.decode!()
      |> Map.put("actor", ap_id(deleting_user))
      |> put_in(["object", "id"], activity.data["object"])

    {:ok, %Activity{local: false, data: %{"id" => id, "actor" => actor}}} =
      Transformer.handle_incoming(data)

    assert id == data["id"]

    # We delete the Create activity because we base our timelines on it.
    # This should be changed after we unify objects and activities
    refute Activity.get_cached(id: activity.id)
    assert actor == ap_id(deleting_user)
  end

  test "it fails for incoming deletes with spoofed origin" do
    activity = insert(:note_activity)
    ap_id = ap_id(local_actor(ap_id: "https://gensokyo.2hu/users/raymoo"))

    data =
      file("fixtures/mastodon/mastodon-delete.json")
      |> Jason.decode!()
      |> Map.put("actor", ap_id)
      |> put_in(["object", "id"], activity.data["object"])

    assert match?({:error, _}, Transformer.handle_incoming(data))
  end

  test "it works for incoming user deletes" do
    %{data: %{"id" => ap_id}} =
      insert(:actor, %{
        data: %{"id" => "https://mastodon.local/users/deleted"}
      })

    assert Object.get_cached!(ap_id: ap_id)

    data =
      file("fixtures/mastodon/mastodon-delete-user.json")
      |> Jason.decode!()

    {:ok, _} = Transformer.handle_incoming(data)
    ObanHelpers.perform_all()

    refute Object.get_cached!(ap_id: ap_id)
  end

  test "it works for incoming deletes when object was deleted on origin instance" do
    note = insert(:note, %{data: %{"id" => "https://fedi.local/objects/410"}})

    activity = insert(:note_activity, %{note: note})

    data =
      file("fixtures/mastodon/mastodon-delete.json")
      |> Jason.decode!()

    object =
      data["object"]
      |> Map.put("id", activity.data["object"])

    data =
      data
      |> Map.put("object", object)
      |> Map.put("actor", activity.data["actor"])

    {:ok, %Object{local: false}} = Transformer.handle_incoming(data)

    object = Object.get_cached!(ap_id: note.data["id"])
    assert object.data["type"] == "Tombstone"
  end

  test "it errors when note still exists" do
    note_data =
      file("fixtures/pleroma_note.json")
      |> Jason.decode!()

    note = insert(:note, data: note_data)
    activity = insert(:note_activity, %{note: note})

    data =
      file("fixtures/mastodon/mastodon-delete.json")
      |> Jason.decode!()

    object =
      data["object"]
      |> Map.put("id", activity.data["object"])

    data =
      data
      |> Map.put("object", object)
      |> Map.put("actor", activity.data["actor"])

    assert {:error, _} = Transformer.handle_incoming(data)
  end

  test "it fails for incoming user deletes with spoofed origin" do
    ap_id = ap_id(local_actor())

    data =
      file("fixtures/mastodon/mastodon-delete-user.json")
      |> Jason.decode!()
      |> Map.put("actor", ap_id)

    assert match?({:error, _}, Transformer.handle_incoming(data))

    assert user_by_ap_id(ap_id)
  end
end
