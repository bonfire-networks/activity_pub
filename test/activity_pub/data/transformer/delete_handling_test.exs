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

  test "delete object works for incoming deletes of remote object when it was deleted on origin instance" do
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

  # should make sure we also tell the adapter to delete things that were pruned, as part of the work on https://github.com/bonfire-networks/bonfire-app/issues/850
  @tag :todo
  test "delete object works for incoming when the object has been pruned" do
    activity = insert(:note_activity)

    # process with adapter
    {:ok, stored_activity} = ActivityPub.Federator.Fetcher.cached_or_handle_incoming(activity)

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

    refute Activity.get_cached(id: activity.id)
    assert actor == ap_id(deleting_user)
  end

  test "delete object fails when note still exists" do
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

  test "delete object fails for incoming deletes of local activities" do
    activity = insert(:note_activity)
    deleting_user = local_actor()

    data =
      file("fixtures/mastodon/mastodon-delete.json")
      |> Jason.decode!()
      |> Map.put("actor", ap_id(deleting_user))
      |> put_in(["object", "id"], activity.data["object"])
      |> debug("dattta")

    assert {:error, _} =
             Transformer.handle_incoming(data)
             |> debug("delete handdddled")
  end

  test "delete object skips incoming deletes of unknown objects" do
    data =
      file("fixtures/mastodon/mastodon-delete.json")
      |> Jason.decode!()
      |> Map.put("actor", "https://mastodon.local/users/admin")
      |> put_in(["object", "id"], "https://mastodon.local/objects/123")

    refute match?({:ok, %{}}, Transformer.handle_incoming(data))
  end

  test "delete object fails for incoming deletes with spoofed origin" do
    activity = insert(:note_activity)
    ap_id = ap_id(local_actor(ap_id: "https://gensokyo.2hu/users/raymoo"))

    data =
      file("fixtures/mastodon/mastodon-delete.json")
      |> Jason.decode!()
      |> Map.put("actor", ap_id)
      |> put_in(["object", "id"], activity.data["object"])

    assert match?({:error, _}, Transformer.handle_incoming(data))
  end
end
