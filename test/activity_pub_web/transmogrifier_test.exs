# MoodleNet: Connecting and empowering educators worldwide
# Copyright © 2018-2020 Moodle Pty Ltd <https://moodle.com/moodlenet/>
# Contains code from Pleroma <https://pleroma.social/> and CommonsPub <https://commonspub.org/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.TransmogrifierTest do
  use MoodleNet.DataCase
  alias ActivityPubWeb.Transmogrifier
  alias ActivityPub.Actor
  alias ActivityPub.Object
  alias MoodleNet.Test.Faking

  import ActivityPub.Factory
  import Tesla.Mock

  setup do
    mock(fn
      %{method: :get, url: "https://pleroma.example/objects/410"} ->
        %Tesla.Env{status: 410}

      env ->
        apply(HttpRequestMock, :request, [env])
    end)

    :ok
  end

  describe "handle incoming" do
    test "it works for incoming deletes when object was deleted on origin instance" do
      note = insert(:note, %{data: %{"id" => "https://pleroma.example/objects/410"}})
      activity = insert(:note_activity, %{note: note})

      data =
        File.read!("test/fixtures/mastodon-delete.json")
        |> Poison.decode!()

      object =
        data["object"]
        |> Map.put("id", activity.data["object"])

      data =
        data
        |> Map.put("object", object)
        |> Map.put("actor", activity.data["actor"])

      {:ok, %Object{local: false}} = Transmogrifier.handle_incoming(data)

      object = Object.get_by_ap_id(note.data["id"])
      assert object.data["type"] == "Tombstone"
    end

    test "it errors when note still exists" do
      note_data =
        File.read!("test/fixtures/pleroma_note.json")
        |> Poison.decode!()

      note = insert(:note, data: note_data)
      activity = insert(:note_activity, %{note: note})

      data =
        File.read!("test/fixtures/mastodon-delete.json")
        |> Poison.decode!()

      object =
        data["object"]
        |> Map.put("id", activity.data["object"])

      data =
        data
        |> Map.put("object", object)
        |> Map.put("actor", activity.data["actor"])

      :error = Transmogrifier.handle_incoming(data)
    end

    test "it works for incoming user deletes" do
      %{data: %{"id" => ap_id}} =
        insert(:actor, %{data: %{"id" => "http://mastodon.example.org/users/admin"}})

      assert object = Object.get_by_ap_id(ap_id)

      data =
        File.read!("test/fixtures/mastodon-delete-user.json")
        |> Poison.decode!()

      {:ok, _} = Transmogrifier.handle_incoming(data)

      refute Object.get_by_ap_id(ap_id)
    end

    test "it returns an error for incoming unlikes wihout a like activity" do
      data =
        File.read!("test/fixtures/mastodon-undo-like.json")
        |> Poison.decode!()

      assert Transmogrifier.handle_incoming(data) == :error
    end

    test "it works for incoming likes" do
      actor = Faking.fake_user!()
      {:ok, note_actor} = Actor.get_by_username(actor.actor.preferred_username)
      note_activity = insert(:note_activity, %{actor: note_actor})
      delete_actor = insert(:actor)

      data =
        File.read!("test/fixtures/mastodon-like.json")
        |> Poison.decode!()
        |> Map.put("object", note_activity.data["object"])
        |> Map.put("actor", delete_actor.data["id"])

      {:ok, %Object{data: data, local: false}} = Transmogrifier.handle_incoming(data)

      assert data["actor"] == delete_actor.data["id"]
      assert data["type"] == "Like"
      assert data["id"] == "http://mastodon.example.org/users/admin#likes/2"
      assert data["object"] == note_activity.data["object"]
    end

    test "it works for incoming unlikes with an existing like activity" do
      actor = Faking.fake_user!()
      {:ok, note_actor} = Actor.get_by_username(actor.actor.preferred_username)
      note_activity = insert(:note_activity, %{actor: note_actor})
      delete_actor = insert(:actor)

      like_data =
        File.read!("test/fixtures/mastodon-like.json")
        |> Poison.decode!()
        |> Map.put("object", note_activity.data["object"])
        |> Map.put("actor", delete_actor.data["id"])

      {:ok, %Object{data: like_data, local: false}} = Transmogrifier.handle_incoming(like_data)

      data =
        File.read!("test/fixtures/mastodon-undo-like.json")
        |> Poison.decode!()
        |> Map.put("object", like_data)
        |> Map.put("actor", like_data["actor"])

      {:ok, %Object{data: data, local: false}} = Transmogrifier.handle_incoming(data)

      assert data["actor"] == delete_actor.data["id"]
      assert data["type"] == "Undo"
      assert data["id"] == "http://mastodon.example.org/users/admin#likes/2/undo"
      assert data["object"]["id"] == "http://mastodon.example.org/users/admin#likes/2"
    end

    test "it works for incoming announces" do
      announce_actor = insert(:actor)
      note = insert(:note)

      data =
        File.read!("test/fixtures/mastodon-announce.json")
        |> Poison.decode!()
        |> Map.put("actor", announce_actor.data["id"])
        |> Map.put("object", note.data["id"])

      {:ok, %Object{data: data, local: false}} = Transmogrifier.handle_incoming(data)

      assert data["actor"] == announce_actor.data["id"]
      assert data["type"] == "Announce"

      assert data["id"] ==
               "http://mastodon.example.org/users/admin/statuses/99542391527669785/activity"

      assert data["object"] ==
               note.data["id"]
    end

    test "it works for incoming announces with an existing activity" do
      actor = Faking.fake_user!()
      {:ok, note_actor} = Actor.get_by_username(actor.actor.preferred_username)
      note_activity = insert(:note_activity, %{actor: note_actor})
      announce_actor = insert(:actor)

      data =
        File.read!("test/fixtures/mastodon-announce.json")
        |> Poison.decode!()
        |> Map.put("object", note_activity.data["object"])
        |> Map.put("actor", announce_actor.data["id"])

      {:ok, %Object{data: data, local: false}} = Transmogrifier.handle_incoming(data)

      assert data["actor"] == announce_actor.data["id"]
      assert data["type"] == "Announce"

      assert data["id"] ==
               "http://mastodon.example.org/users/admin/statuses/99542391527669785/activity"

      assert data["object"] == note_activity.data["object"]
    end

    test "it works for incoming unannounces with an existing notice" do
      actor = Faking.fake_user!()
      {:ok, note_actor} = Actor.get_by_username(actor.actor.preferred_username)
      note_activity = insert(:note_activity, %{actor: note_actor})
      announce_actor = insert(:actor)

      announce_data =
        File.read!("test/fixtures/mastodon-announce.json")
        |> Poison.decode!()
        |> Map.put("actor", announce_actor.data["id"])
        |> Map.put("object", note_activity.data["object"])

      {:ok, %Object{data: announce_data, local: false}} =
        Transmogrifier.handle_incoming(announce_data)

      data =
        File.read!("test/fixtures/mastodon-undo-announce.json")
        |> Poison.decode!()
        |> Map.put("object", announce_data)
        |> Map.put("actor", announce_data["actor"])

      {:ok, %Object{data: data, local: false}} = Transmogrifier.handle_incoming(data)

      assert data["type"] == "Undo"
      assert object_data = data["object"]
      assert object_data["type"] == "Announce"
      assert object_data["object"] == note_activity.data["object"]

      assert object_data["id"] ==
               "http://mastodon.example.org/users/admin/statuses/99542391527669785/activity"
    end

    test "it accepts Flag activities" do
      actor = insert(:actor)
      other_actor = insert(:actor)

      activity = insert(:note_activity, %{actor: actor})
      object = Object.normalize(activity)

      message = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "cc" => [actor.data["id"]],
        "object" => [actor.data["id"], object.data["id"]],
        "type" => "Flag",
        "content" => "blocked AND reported!!!",
        "actor" => other_actor.data["id"]
      }

      assert {:ok, activity} = Transmogrifier.handle_incoming(message)

      assert activity.data["object"] == [actor.data["id"], object.data["id"]]
      assert activity.data["content"] == "blocked AND reported!!!"
      assert activity.data["actor"] == other_actor.data["id"]
      assert activity.data["cc"] == [actor.data["id"]]
    end

    test "it works for incoming update activities" do
      data = File.read!("test/fixtures/mastodon-post-activity.json") |> Poison.decode!()

      {:ok, %Object{data: data, local: false}} = Transmogrifier.handle_incoming(data)
      update_data = File.read!("test/fixtures/mastodon-update.json") |> Poison.decode!()

      {:ok, actor} = Actor.get_or_fetch_by_ap_id(data["actor"])

      object =
        update_data["object"]
        |> Map.put("actor", data["actor"])
        |> Map.put("id", data["actor"])
        |> Map.put("preferredUsername", actor.data["preferredUsername"])

      update_data =
        update_data
        |> Map.put("actor", data["actor"])
        |> Map.put("object", object)

      {:ok, %Object{data: data, local: false}} = Transmogrifier.handle_incoming(update_data)

      {:ok, actor} = Actor.get_by_ap_id(data["actor"])
      assert actor.data["name"] == "gargle"

      assert actor.data["icon"]["url"] ==
               "https://cd.niu.moe/accounts/avatars/000/033/323/original/fd7f8ae0b3ffedc9.jpeg"

      assert actor.data["image"]["url"] ==
               "https://cd.niu.moe/accounts/headers/000/033/323/original/850b3448fa5fd477.png"

      assert actor.data["summary"] == "<p>Some bio</p>"
    end
  end
end
