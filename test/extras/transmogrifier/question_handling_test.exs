# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.Transmogrifier.QuestionHandlingTest do
  use ActivityPub.DataCase

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object
  alias ActivityPubWeb.Transmogrifier
  alias ActivityPub.Test.HttpRequestMock

  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  test "Mastodon Question activity" do
    data = file("fixtures/mastodon/mastodon-question-activity.json") |> Jason.decode!()

    {:ok, %Activity{local: false} = activity} = Transmogrifier.handle_incoming(data)

    object = Object.normalize(activity, fetch: false)

    assert object.data["url"] == "https://masto.local/@rinpatch/102070944809637304"

    assert object.data["closed"] == "2019-05-11T09:03:36Z"

    assert object.data["context"] == activity.data["context"]

    assert object.data["context"] ==
             "tag:mastodon.sdf.org,2019-05-10:objectId=15095122:objectType=Conversation"

    assert object.data["anyOf"] == []

    assert Enum.sort(object.data["oneOf"]) ==
             Enum.sort([
               %{
                 "name" => "25 char limit is dumb",
                 "replies" => %{"totalItems" => 0, "type" => "Collection"},
                 "type" => "Note"
               },
               %{
                 "name" => "Dunno",
                 "replies" => %{"totalItems" => 0, "type" => "Collection"},
                 "type" => "Note"
               },
               %{
                 "name" => "Everyone knows that!",
                 "replies" => %{"totalItems" => 1, "type" => "Collection"},
                 "type" => "Note"
               },
               %{
                 "name" => "I can't even fit a funny",
                 "replies" => %{"totalItems" => 1, "type" => "Collection"},
                 "type" => "Note"
               }
             ])

    user = local_actor()

    reply_activity =
      insert(:note_activity, %{actor: user, status: "hewwo", in_reply_to_id: activity.id})

    reply_object = Object.normalize(reply_activity, fetch: false)

    assert reply_object.data["context"] == object.data["context"]
  end

  test "Mastodon Question activity with HTML tags in plaintext" do
    options = [
      %{
        "type" => "Note",
        "name" => "<input type=\"date\">",
        "replies" => %{"totalItems" => 0, "type" => "Collection"}
      },
      %{
        "type" => "Note",
        "name" => "<input type=\"date\"/>",
        "replies" => %{"totalItems" => 0, "type" => "Collection"}
      },
      %{
        "type" => "Note",
        "name" => "<input type=\"date\" />",
        "replies" => %{"totalItems" => 1, "type" => "Collection"}
      },
      %{
        "type" => "Note",
        "name" => "<input type=\"date\"></input>",
        "replies" => %{"totalItems" => 1, "type" => "Collection"}
      }
    ]

    data =
      file("fixtures/mastodon/mastodon-question-activity.json")
      |> Jason.decode!()
      |> Kernel.put_in(["object", "oneOf"], options)

    {:ok, %Activity{local: false} = activity} = Transmogrifier.handle_incoming(data)
    object = Object.normalize(activity, fetch: false)

    assert is_list(object.data["oneOf"])
    assert Enum.sort(object.data["oneOf"]) == Enum.sort(options)
  end

  test "Mastodon Question activity with custom emojis" do
    options = [
      %{
        "type" => "Note",
        "name" => ":blobcat:",
        "replies" => %{"totalItems" => 0, "type" => "Collection"}
      },
      %{
        "type" => "Note",
        "name" => ":blobfox:",
        "replies" => %{"totalItems" => 0, "type" => "Collection"}
      }
    ]

    tag = [
      %{
        "icon" => %{
          "type" => "Image",
          "url" => "https://blob.cat/emoji/custom/blobcats/blobcat.png"
        },
        "id" => "https://blob.cat/emoji/custom/blobcats/blobcat.png",
        "name" => ":blobcat:",
        "type" => "Emoji",
        "updated" => "1970-01-01T00:00:00Z"
      },
      %{
        "icon" => %{"type" => "Image", "url" => "https://blob.cat/emoji/blobfox/blobfox.png"},
        "id" => "https://blob.cat/emoji/blobfox/blobfox.png",
        "name" => ":blobfox:",
        "type" => "Emoji",
        "updated" => "1970-01-01T00:00:00Z"
      }
    ]

    data =
      file("fixtures/mastodon/mastodon-question-activity.json")
      |> Jason.decode!()
      |> Kernel.put_in(["object", "oneOf"], options)
      |> Kernel.put_in(["object", "tag"], tag)

    {:ok, %Activity{local: false} = activity} = Transmogrifier.handle_incoming(data)
    object = Object.normalize(activity, fetch: false)

    assert object.data["oneOf"] == options

    assert object.data["emoji"] == %{
             "blobcat" => "https://blob.cat/emoji/custom/blobcats/blobcat.png",
             "blobfox" => "https://blob.cat/emoji/blobfox/blobfox.png"
           }
  end

  test "returns same activity if received a second time" do
    data = file("fixtures/mastodon/mastodon-question-activity.json") |> Jason.decode!()

    assert {:ok, %Activity{local: false} = activity} = Transmogrifier.handle_incoming(data)

    {:ok, activity_2} = Transmogrifier.handle_incoming(data)

    assert activity
           |> Map.drop([:pointer, :pointer_id]) ==
             activity_2
             |> Map.drop([:pointer, :pointer_id])
  end

  test "accepts a Question with no content" do
    data =
      file("fixtures/mastodon/mastodon-question-activity.json")
      |> Jason.decode!()
      |> Kernel.put_in(["object", "content"], "")

    assert {:ok, %Activity{local: false}} = Transmogrifier.handle_incoming(data)
  end
end
