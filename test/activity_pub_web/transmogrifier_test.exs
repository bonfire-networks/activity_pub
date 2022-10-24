defmodule ActivityPubWeb.TransmogrifierTest do
  use ActivityPub.DataCase
  alias ActivityPubWeb.Transmogrifier
  alias ActivityPub.Actor
  alias ActivityPub.Object

  import ActivityPub.Factory
  import Tesla.Mock

  @mod_path __DIR__
  def file(path), do: File.read!(@mod_path <> "/../" <> path)

  setup do
    mock(fn
      %{method: :get, url: "https://pleroma.example/objects/410"} ->
        %Tesla.Env{status: 410}

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  describe "handle incoming" do


    test "it works for incoming create activity" do
      data = file("fixtures/mastodon-post-activity.json") |> Jason.decode!()

      {:ok, %Object{data: data, local: false}} = Transmogrifier.handle_incoming(data)
    end

    test "it works for incoming deletes when object was deleted on origin instance" do
      note = insert(:note, %{data: %{"id" => "https://pleroma.example/objects/410"}})

      activity = insert(:note_activity, %{note: note})

      data =
        file("fixtures/mastodon-delete.json")
        |> Jason.decode!()

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
        file("fixtures/pleroma_note.json")
        |> Jason.decode!()

      note = insert(:note, data: note_data)
      activity = insert(:note_activity, %{note: note})

      data =
        file("fixtures/mastodon-delete.json")
        |> Jason.decode!()

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
        insert(:actor, %{
          data: %{"id" => "https://mastodon.example.org/users/karen"}
        })

      assert Object.get_by_ap_id(ap_id)

      data =
        file("fixtures/mastodon-delete-user.json")
        |> Jason.decode!()

      {:ok, _} = Transmogrifier.handle_incoming(data)

      refute Object.get_by_ap_id(ap_id)
    end

    test "it returns an error for incoming unlikes wihout a like activity" do
      data =
        file("fixtures/mastodon-undo-like.json")
        |> Jason.decode!()

      assert Transmogrifier.handle_incoming(data) == :error
    end

    test "it works for incoming likes" do
      actor = local_actor()
      {:ok, note_actor} = Actor.get_by_username(actor.username)
      note_activity = insert(:note_activity, %{actor: note_actor})
      delete_actor = insert(:actor)

      data =
        file("fixtures/mastodon-like.json")
        |> Jason.decode!()
        |> Map.put("object", note_activity.data["object"])
        |> Map.put("actor", delete_actor.data["id"])

      {:ok, %Object{data: data, local: false}} = Transmogrifier.handle_incoming(data)

      assert data["actor"] == delete_actor.data["id"]
      assert data["type"] == "Like"
      assert data["id"] == "https://mastodon.example.org/users/karen#likes/2"
      assert data["object"] == note_activity.data["object"]
    end

    test "it works for incoming unlikes with an existing like activity" do
      actor = local_actor()
      {:ok, note_actor} = Actor.get_by_username(actor.username)
      note_activity = insert(:note_activity, %{actor: note_actor})
      delete_actor = insert(:actor)

      like_data =
        file("fixtures/mastodon-like.json")
        |> Jason.decode!()
        |> Map.put("object", note_activity.data["object"])
        |> Map.put("actor", delete_actor.data["id"])

      {:ok, %Object{data: like_data, local: false}} = Transmogrifier.handle_incoming(like_data)

      data =
        file("fixtures/mastodon-undo-like.json")
        |> Jason.decode!()
        |> Map.put("object", like_data)
        |> Map.put("actor", like_data["actor"])

      {:ok, %Object{data: data, local: false}} = Transmogrifier.handle_incoming(data)

      assert data["actor"] == delete_actor.data["id"]
      assert data["type"] == "Undo"

      assert data["id"] ==
               "https://mastodon.example.org/users/karen#likes/2/undo"

      assert data["object"]["id"] ==
               "https://mastodon.example.org/users/karen#likes/2"
    end

    test "it works for incoming announces" do
      announce_actor = insert(:actor)
      note = insert(:note)

      data =
        file("fixtures/mastodon-announce.json")
        |> Jason.decode!()
        |> Map.put("actor", announce_actor.data["id"])
        |> Map.put("object", note.data["id"])

      {:ok, %Object{data: data, local: false}} = Transmogrifier.handle_incoming(data)

      assert data["actor"] == announce_actor.data["id"]
      assert data["type"] == "Announce"

      assert data["id"] ==
               "https://mastodon.example.org/users/karen/statuses/99542391527669785/activity"

      assert data["object"] ==
               note.data["id"]
    end

    test "it works for incoming announces with an existing activity" do
      actor = local_actor()
      {:ok, note_actor} = Actor.get_by_username(actor.username)
      note_activity = insert(:note_activity, %{actor: note_actor})
      announce_actor = insert(:actor)

      data =
        file("fixtures/mastodon-announce.json")
        |> Jason.decode!()
        |> Map.put("object", note_activity.data["object"])
        |> Map.put("actor", announce_actor.data["id"])

      {:ok, %Object{data: data, local: false}} = Transmogrifier.handle_incoming(data)

      assert data["actor"] == announce_actor.data["id"]
      assert data["type"] == "Announce"

      assert data["id"] ==
               "https://mastodon.example.org/users/karen/statuses/99542391527669785/activity"

      assert data["object"] == note_activity.data["object"]
    end

    test "it works for incoming unannounces with an existing notice" do
      actor = local_actor()
      {:ok, note_actor} = Actor.get_by_username(actor.username)
      note_activity = insert(:note_activity, %{actor: note_actor})
      announce_actor = insert(:actor)

      announce_data =
        file("fixtures/mastodon-announce.json")
        |> Jason.decode!()
        |> Map.put("actor", announce_actor.data["id"])
        |> Map.put("object", note_activity.data["object"])

      {:ok, %Object{data: announce_data, local: false}} =
        Transmogrifier.handle_incoming(announce_data)

      data =
        file("fixtures/mastodon-undo-announce.json")
        |> Jason.decode!()
        |> Map.put("object", announce_data)
        |> Map.put("actor", announce_data["actor"])

      {:ok, %Object{data: data, local: false}} = Transmogrifier.handle_incoming(data)

      assert data["type"] == "Undo"
      assert object_data = data["object"]
      assert object_data["type"] == "Announce"
      assert object_data["object"] == note_activity.data["object"]

      assert object_data["id"] ==
               "https://mastodon.example.org/users/karen/statuses/99542391527669785/activity"
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
      data = file("fixtures/mastodon-post-activity.json") |> Jason.decode!()

      {:ok, %Object{data: data, local: false}} = Transmogrifier.handle_incoming(data)

      update_data = file("fixtures/mastodon-update.json") |> Jason.decode!()

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

      {:ok, actor} = Actor.single_by_ap_id(data["actor"])
      assert actor.data["name"] == "gargle"

      assert actor.data["icon"]["url"] ==
               "https://cd.mastodon.example.org/accounts/avatars/000/033/323/original/fd7f8ae0b3ffedc9.jpeg"

      assert actor.data["image"]["url"] ==
               "https://cd.mastodon.example.org/accounts/headers/000/033/323/original/850b3448fa5fd477.png"

      assert actor.data["summary"] == "<p>Some bio</p>"
    end
  end
end
