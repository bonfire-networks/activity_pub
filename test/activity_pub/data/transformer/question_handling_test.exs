# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.QuestionHandlingTest do
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

  # `Question` is supported in two shapes (see `ActivityPub.Object.do_insert_object`):
  #  - as a poll *object* wrapped in a `Create` (how Mastodon federates polls) — covered by the
  #    tests below, which assert the wrapped Question is stored as its own retrievable AP object;
  #  - as a bare *intransitive activity* (its AS2 classification) — covered by this test.
  test "a bare intransitive Question activity is stored and retrievable" do
    data = file("fixtures/mastodon/mastodon-question-activity.json") |> Jason.decode!()

    # the inner Question sent directly as an intransitive activity (no Create wrapper), with a
    # distinct id so it doesn't collide with the wrapped-Question tests
    bare =
      data["object"]
      |> Map.put("actor", data["actor"])
      |> Map.put("id", data["object"]["id"] <> "-intransitive")

    {:ok, %Activity{local: false} = activity} = Transformer.handle_incoming(bare)

    object = Object.normalize(activity, fetch: false)
    assert is_map(object)
    assert object.data["type"] == "Question"
    assert is_list(object.data["oneOf"])
    assert object.data["id"] == bare["id"]
  end

  test "Mastodon Question activity" do
    data = file("fixtures/mastodon/mastodon-question-activity.json") |> Jason.decode!()

    {:ok, %Activity{local: false} = activity} = Transformer.handle_incoming(data)

    object = Object.normalize(activity, fetch: false)
    assert is_map(object)

    assert is_map(object.data) || raise("object.data is not a map: #{inspect(object.data)}")

    assert object.data["url"] == "https://masto.local/@rinpatch/102070944809637304"

    assert object.data["endTime"] == "2019-05-11T09:03:36Z"

    assert object.data["context"] == activity.data["context"]

    assert object.data["context"] ==
             "tag:mastodon.sdf.org,2019-05-10:objectId=15095122:objectType=Conversation"

    # single-choice poll: only `oneOf` is present, `anyOf` (multiple-choice) is absent
    assert object.data["anyOf"] == nil

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

    # a normal non-vote reply to the federated poll should join the poll's thread. Bonfire threads by the root
    # object's AP id (not Mastodon's conversation `context` tag), so the reply takes the poll's
    # URL as its context.
    reply_activity =
      insert(:note_activity, %{actor: user, status: "hewwo", reply_to: object.pointer_id})

    reply_object = Object.normalize(reply_activity, fetch: false)

    assert reply_object.data["context"] == object.data["id"]
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

    {:ok, %Activity{local: false} = activity} = Transformer.handle_incoming(data)
    object = Object.normalize(activity, fetch: false)
    assert is_map(object)
    assert is_map(object.data) || raise("object.data is not a map: #{inspect(object.data)}")

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

    {:ok, %Activity{local: false} = activity} = Transformer.handle_incoming(data)
    object = Object.normalize(activity, fetch: false)
    assert is_map(object) || raise("object is not a map: #{inspect(object)}")
    assert is_map(object.data) || raise("object.data is not a map: #{inspect(object.data)}")

    assert object.data["oneOf"] == options

    assert object.data["emoji"] == %{
             "blobcat" => "https://blob.cat/emoji/custom/blobcats/blobcat.png",
             "blobfox" => "https://blob.cat/emoji/blobfox/blobfox.png"
           }
  end

  test "returns same activity if received a second time" do
    data = file("fixtures/mastodon/mastodon-question-activity.json") |> Jason.decode!()

    assert {:ok, %Activity{local: false} = activity} = Transformer.handle_incoming(data)

    {:ok, activity_2} = Transformer.handle_incoming(data)

    assert stripped_object(activity) ==
             stripped_object(activity_2)
  end

  test "accepts a Question with no content" do
    data =
      file("fixtures/mastodon/mastodon-question-activity.json")
      |> Jason.decode!()
      |> Kernel.put_in(["object", "content"], "")

    assert {:ok, %Activity{local: false}} = Transformer.handle_incoming(data)
  end
end
