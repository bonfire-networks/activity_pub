# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.Transmogrifier.EmojiReactHandlingTest do
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

  test "it works for incoming emoji reactions" do
    user = local_actor()
    other_user = local_actor(local: false)
    activity = insert(:note_activity, %{actor: user, status: "hello"})

    data =
      file("fixtures/emoji-reaction.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.put("actor", ap_id(other_user))

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["actor"] == ap_id(other_user)
    assert data["type"] == "EmojiReact"
    assert data["id"] == "https://mastodon.local/users/admin#reactions/2"
    assert Object.get_ap_id(data["object"]) =~ activity.data["object"]
    assert data["content"] == "👌"

    {:ok, object} = Object.get_cached(ap_id: data["object"])

    assert object.data["reaction_count"] == 1
    assert match?([["👌", _, nil]], object.data["reactions"])
  end

  test "it works for incoming custom emoji reactions" do
    user = local_actor()
    other_user = local_actor(local: false)
    activity = insert(:note_activity, %{actor: user, status: "hello"})

    data =
      file("fixtures/custom-emoji-reaction.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.put("actor", ap_id(other_user))

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["actor"] == ap_id(other_user)
    assert data["type"] == "EmojiReact"
    assert data["id"] == "https://misskey.local/likes/917ocsybgp"
    assert Object.get_ap_id(data["object"]) =~ activity.data["object"]
    assert data["content"] == ":hanapog:"

    assert data["tag"] == [
             %{
               "id" => "https://misskey.local/emojis/hanapog",
               "type" => "Emoji",
               "name" => "hanapog",
               "updated" => "2022-06-07T12:00:05.773Z",
               "icon" => %{
                 "type" => "Image",
                 "url" =>
                   "https://misskey.local/files/webpublic-8f8a9768-7264-4171-88d6-2356aabeadcd"
               }
             }
           ]

    {:ok, object} = Object.get_cached(ap_id: data["object"])

    assert object.data["reaction_count"] == 1

    assert match?(
             [
               [
                 "hanapog",
                 _,
                 "https://misskey.local/files/webpublic-8f8a9768-7264-4171-88d6-2356aabeadcd"
               ]
             ],
             object.data["reactions"]
           )
  end

  test "it works for incoming unqualified emoji reactions" do
    user = local_actor()
    other_user = local_actor(local: false)
    activity = insert(:note_activity, %{actor: user, status: "hello"})

    # woman detective emoji, unqualified
    unqualified_emoji = [0x1F575, 0x200D, 0x2640] |> List.to_string()

    data =
      file("fixtures/emoji-reaction.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.put("actor", ap_id(other_user))
      |> Map.put("content", unqualified_emoji)

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["actor"] == ap_id(other_user)
    assert data["type"] == "EmojiReact"
    assert data["id"] == "https://mastodon.local/users/admin#reactions/2"
    assert Object.get_ap_id(data["object"]) =~ activity.data["object"]
    # woman detective emoji, fully qualified
    # emoji = [0x1F575, 0xFE0F, 0x200D, 0x2640, 0xFE0F] |> List.to_string()
    emoji = "🕵️‍♀️"
    assert data["content"] == emoji

    {:ok, object} = Object.get_cached(ap_id: data["object"])

    assert object.data["reaction_count"] == 1
    assert match?([[^emoji, _, _]], object.data["reactions"])
  end

  test "it reject invalid emoji reactions" do
    user = local_actor()
    other_user = local_actor(local: false)
    activity = insert(:note_activity, %{actor: user, status: "hello"})

    data =
      file("fixtures/emoji-reaction-too-long.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.put("actor", ap_id(other_user))

    assert {:error, _} = Transmogrifier.handle_incoming(data)

    data =
      file("fixtures/emoji-reaction-no-emoji.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.put("actor", ap_id(other_user))

    assert {:error, _} = Transmogrifier.handle_incoming(data)
  end
end
