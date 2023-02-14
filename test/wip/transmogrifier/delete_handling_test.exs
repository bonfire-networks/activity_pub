# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.Transmogrifier.DeleteHandlingTest do
  use ActivityPub.DataCase
  use Oban.Testing, repo: repo()

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object

  alias ActivityPubWeb.Transmogrifier
  alias ActivityPub.Test.HttpRequestMock
  alias ActivityPub.Tests.ObanHelpers

  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)
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

    {:ok, %Activity{local: false, data: %{"id" => id, "actor" => actor}}} =
      Transmogrifier.handle_incoming(data)

    assert id == data["id"]

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

    # TODO: mock cachex
    Cachex.del(:object_cache, "object:#{object.data["id"]}")

    deleting_user = local_actor()

    data =
      file("fixtures/mastodon/mastodon-delete.json")
      |> Jason.decode!()
      |> Map.put("actor", ap_id(deleting_user))
      |> put_in(["object", "id"], activity.data["object"])

    {:ok, %Activity{local: false, data: %{"id" => id, "actor" => actor}}} =
      Transmogrifier.handle_incoming(data)

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

    assert match?({:error, _}, Transmogrifier.handle_incoming(data))
  end

  @tag capture_log: true
  test "it works for incoming user deletes" do
    ap_id = ap_id(local_actor(ap_id: "https://mastodon.local/users/admin"))

    data =
      file("fixtures/mastodon/mastodon-delete-user.json")
      |> Jason.decode!()

    {:ok, _} = Transmogrifier.handle_incoming(data)
    ObanHelpers.perform_all()

    refute user_by_ap_id(ap_id).is_active
  end

  test "it fails for incoming user deletes with spoofed origin" do
    ap_id = ap_id(local_actor())

    data =
      file("fixtures/mastodon/mastodon-delete-user.json")
      |> Jason.decode!()
      |> Map.put("actor", ap_id)

    assert match?({:error, _}, Transmogrifier.handle_incoming(data))

    assert user_by_ap_id(ap_id)
  end
end
