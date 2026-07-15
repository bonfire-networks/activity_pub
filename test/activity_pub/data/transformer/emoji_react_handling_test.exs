# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.EmojiReactHandlingTest do
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Test.HttpRequestMock

  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  # unlike Pleroma, the library does not maintain reaction tallies on the reacted object's AP data (`reaction_count`/`reactions`), validate the emoji, or re-qualify it, the EmojiReact activity is stored as-is and reactions are the adapter's concern (e.g. Bonfire records them as emoji Likes)

  test "an incoming emoji reaction is stored as-is" do
    user = local_actor()
    other_user = actor(local: false)
    activity = insert(:note_activity, %{actor: user, status: "hello"})

    data =
      file("fixtures/emoji-reaction.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.put("actor", ap_id(other_user))

    {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

    assert data["actor"] == ap_id(other_user)
    assert data["type"] == "EmojiReact"
    assert data["id"] == "https://mastodon.local/users/admin#reactions/2"
    assert Object.get_ap_id(data["object"]) =~ activity.data["object"]
    assert data["content"] == "👌"
  end

  test "an incoming custom emoji reaction is stored with its Emoji tag" do
    user = local_actor()
    other_user = actor(local: false)
    activity = insert(:note_activity, %{actor: user, status: "hello"})

    data =
      file("fixtures/custom-emoji-reaction.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.put("actor", ap_id(other_user))

    {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

    assert data["actor"] == ap_id(other_user)
    # Misskey federates custom emoji reactions as a `Like` with `content`/`_misskey_reaction`;
    # the transformer normalises those to the canonical `EmojiReact` type
    assert data["type"] == "EmojiReact"
    assert data["id"] == "https://misskey.local/likes/917ocsybgp"
    assert Object.get_ap_id(data["object"]) =~ activity.data["object"]
    assert data["content"] == ":hanapog:"

    # the custom emoji's Emoji tag passes through unchanged 
    assert data["tag"] == [
             %{
               "id" => "https://misskey.local/emojis/hanapog",
               "type" => "Emoji",
               "name" => ":hanapog:",
               "updated" => "2022-06-07T12:00:05.773Z",
               "icon" => %{
                 "type" => "Image",
                 "mediaType" => "image/png",
                 "url" =>
                   "https://misskey.local/files/webpublic-8f8a9768-7264-4171-88d6-2356aabeadcd"
               }
             }
           ]
  end

  test "an unqualified emoji reaction is accepted as-is (no re-qualification)" do
    user = local_actor()
    other_user = actor(local: false)
    activity = insert(:note_activity, %{actor: user, status: "hello"})

    # woman detective emoji, unqualified (missing the variation selectors)
    unqualified_emoji = [0x1F575, 0x200D, 0x2640] |> List.to_string()

    data =
      file("fixtures/emoji-reaction.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])
      |> Map.put("actor", ap_id(other_user))
      |> Map.put("content", unqualified_emoji)

    {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

    assert data["type"] == "EmojiReact"
    assert data["content"] == unqualified_emoji
  end
end
