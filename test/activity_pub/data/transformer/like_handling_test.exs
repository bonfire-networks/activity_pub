# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.LikeHandlingTest do
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Actor
  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Federator.Transformer

  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  test "it works for incoming likes" do
    actor = local_actor()

    {:ok, note_actor} =
      Actor.get_cached(username: actor.username)
      |> debug("note_actor")

    note_activity =
      insert(:note_activity, %{actor: note_actor})
      |> debug("note_activity")

    like_actor = insert(:actor)

    data =
      file("fixtures/mastodon/mastodon-like.json")
      |> Jason.decode!()
      |> Map.put("object", note_activity.data["object"])
      |> Map.put("actor", like_actor.data["id"])

    # _actor = actor(ap_id: data["actor"], local: false)

    {:ok, %Object{data: data, local: false}} = Transformer.handle_incoming(data)
    refute Enum.empty?(note_activity.data["to"])

    assert data["actor"] == like_actor.data["id"]
    assert data["type"] == "Like"
    assert data["id"] == "https://mastodon.local/users/admin#likes/2"
    assert Object.get_ap_id(data["object"]) =~ note_activity.data["object"]
  end

  @tag :todo
  test "it works for incoming misskey likes, turning them into EmojiReacts" do
    user = local_actor()

    activity = insert(:note_activity, %{actor: user, status: "hello"})

    data =
      file("fixtures/misskey/misskey-like.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])

    _actor = local_actor(ap_id: data["actor"], local: false)

    {:ok, %Activity{data: activity_data, local: false}} = Transformer.handle_incoming(data)

    assert activity_data["actor"] == data["actor"]
    assert activity_data["type"] == "EmojiReact"
    assert activity_data["id"] == data["id"]
    assert activity_data["object"] == activity.data["object"]
    assert activity_data["content"] == ":pudding:"
  end

  @tag :todo
  test "it works for incoming misskey likes that contain unicode emojis, turning them into EmojiReacts" do
    user = local_actor()

    activity = insert(:note_activity, %{actor: user, status: "hello"})

    data =
      file("fixtures/misskey/misskey-like.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.put("_misskey_reaction", "⭐")

    _actor = local_actor(ap_id: data["actor"], local: false)

    {:ok, %Activity{data: activity_data, local: false}} = Transformer.handle_incoming(data)

    assert activity_data["actor"] == data["actor"]
    assert activity_data["type"] == "EmojiReact"
    assert activity_data["id"] == data["id"]
    assert activity_data["object"] == activity.data["object"]
    assert activity_data["content"] == "⭐"
  end
end
