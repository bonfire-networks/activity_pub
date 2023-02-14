# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.Transmogrifier.UndoHandlingTest do
  use ActivityPub.DataCase, async: true

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object
  alias ActivityPubWeb.Transmogrifier

  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  @tag :todo
  test "it works for incoming emoji reaction undos" do
    user = local_actor()

    activity = insert(:note_activity, %{actor: user, status: "hello"})
    {:ok, reaction_activity} = CommonAPI.react_with_emoji(activity.id, user, "👌")

    data =
      file("fixtures/mastodon/mastodon-undo-like.json")
      |> Jason.decode!()
      |> Map.put("object", reaction_activity.data["id"])
      |> Map.put("actor", ap_id(user))

    {:ok, activity} = Transmogrifier.handle_incoming(data)

    assert activity.actor == ap_id(user)
    assert activity.data["id"] == data["id"]
    assert activity.data["type"] == "Undo"
  end

  test "it returns an error for incoming unlikes wihout a like activity" do
    user = local_actor()
    activity = insert(:note_activity, %{actor: user, status: "leave a like pls"})

    data =
      file("fixtures/mastodon/mastodon-undo-like.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])

    {:error, _} = assert Transmogrifier.handle_incoming(data)
  end

  test "it works for incoming unlikes with an existing like activity" do
    user = local_actor()
    activity = insert(:note_activity, %{actor: user, status: "leave a like pls"})

    like_data =
      file("fixtures/mastodon/mastodon-like.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])

    _liker = local_actor(ap_id: like_data["actor"], local: false)

    {:ok, %Activity{data: like_data, local: false}} = Transmogrifier.handle_incoming(like_data)

    data =
      file("fixtures/mastodon/mastodon-undo-like.json")
      |> Jason.decode!()
      |> Map.put("object", like_data)
      |> Map.put("actor", like_data["actor"])

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["actor"] == "https://mastodon.local/users/admin"
    assert data["type"] == "Undo"
    assert data["id"] == "https://mastodon.local/users/admin#likes/2/undo"
    assert Object.get_ap_id(data["object"]) =~ "https://mastodon.local/users/admin#likes/2"

    {:ok, note} = Object.get_cached(ap_id: like_data["object"])
    assert note.data["like_count"] == 0
    assert note.data["likes"] == []
  end

  test "it works for incoming unlikes with an existing like activity and a compact object" do
    user = local_actor()
    activity = insert(:note_activity, %{actor: user, status: "leave a like pls"})

    like_data =
      file("fixtures/mastodon/mastodon-like.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])

    _liker = local_actor(ap_id: like_data["actor"], local: false)

    {:ok, %Activity{data: like_data, local: false}} = Transmogrifier.handle_incoming(like_data)

    data =
      file("fixtures/mastodon/mastodon-undo-like.json")
      |> Jason.decode!()
      |> Map.put("object", like_data["id"])
      |> Map.put("actor", like_data["actor"])

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["actor"] == "https://mastodon.local/users/admin"
    assert data["type"] == "Undo"
    assert data["id"] == "https://mastodon.local/users/admin#likes/2/undo"
    assert Object.get_ap_id(data["object"]) =~ "https://mastodon.local/users/admin#likes/2"
  end

  test "it works for incoming unannounces with an existing notice" do
    user = local_actor()
    activity = insert(:note_activity, %{actor: user, status: "hey"})

    announce_data =
      file("fixtures/mastodon/mastodon-announce.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])

    _announcer = local_actor(ap_id: announce_data["actor"], local: false)

    {:ok, %Activity{data: announce_data, local: false}} =
      Transmogrifier.handle_incoming(announce_data)

    data =
      file("fixtures/mastodon/mastodon-undo-announce.json")
      |> Jason.decode!()
      |> Map.put("object", announce_data)
      |> Map.put("actor", announce_data["actor"])

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["type"] == "Undo"

    assert Object.get_ap_id(data["object"]) =~
             "https://mastodon.local/users/admin/statuses/99542391527669785/activity"
  end

  test "it works for incoming unfollows with an existing follow" do
    user = local_actor()

    follow_data =
      file("fixtures/mastodon/mastodon-follow-activity.json")
      |> Jason.decode!()
      |> Map.put("object", ap_id(user))

    _follower = local_actor(ap_id: follow_data["actor"], local: false)

    {:ok, %Activity{data: _, local: false}} = Transmogrifier.handle_incoming(follow_data)

    data =
      file("fixtures/mastodon/mastodon-unfollow-activity.json")
      |> Jason.decode!()
      |> Map.put("object", follow_data)

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["type"] == "Undo"
    assert data["object"]["type"] == "Follow"
    assert data["object"]["object"] == ap_id(user)
    assert data["actor"] == "https://mastodon.local/users/admin"

    refute following?(user_by_ap_id(data["actor"]), user)
  end

  # test "it works for incoming unblocks with an existing block" do
  #   user = local_actor()

  #   block_data =
  #     file("fixtures/mastodon/mastodon-block-activity.json")
  #     |> Jason.decode!()
  #     |> Map.put("object", ap_id(user))

  #   _blocker = local_actor(ap_id: block_data["actor"], local: false)

  #   {:ok, %Activity{data: _, local: false}} = Transmogrifier.handle_incoming(block_data)

  #   data =
  #     file("fixtures/mastodon/mastodon-unblock-activity.json")
  #     |> Jason.decode!()
  #     |> Map.put("object", block_data)

  #   {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)
  #   assert data["type"] == "Undo"
  #   assert Object.get_ap_id(data["object"]) =~ block_data["id"]

  #   blocker = user_by_ap_id(data["actor"])

  #   refute User.blocks?(blocker, user)
  # end
end
