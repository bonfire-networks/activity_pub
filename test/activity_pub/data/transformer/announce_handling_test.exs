# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.AnnounceHandlingTest do
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object
  alias ActivityPub.Actor
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Test.HttpRequestMock

  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  test "it works for incoming announces" do
    announce_actor = insert(:actor)
    note = insert(:note)

    data =
      file("fixtures/mastodon/mastodon-announce.json")
      |> Jason.decode!()
      |> Map.put("actor", announce_actor.data["id"])
      |> Map.put("object", note.data["id"])

    {:ok, %Object{data: data, local: false}} = Transformer.handle_incoming(data)

    assert data["actor"] == announce_actor.data["id"]
    assert data["type"] == "Announce"

    assert data["id"] ==
             "https://mastodon.local/users/admin/statuses/99542391527669785/activity"

    assert Object.get_ap_id(data["object"]) =~
             note.data["id"]
  end

  test "it works for incoming announces with an existing activity" do
    actor = local_actor()
    {:ok, note_actor} = Actor.get_cached(username: actor.username)

    note_activity =
      insert(:note_activity, %{actor: note_actor})
      |> debug("create_activity")

    announce_actor = insert(:actor)

    data =
      file("fixtures/mastodon/mastodon-announce.json")
      |> Jason.decode!()
      |> Map.put("object", note_activity.data["object"])
      |> Map.put("actor", announce_actor.data["id"])

    {:ok, %Object{data: data, local: false}} =
      Transformer.handle_incoming(data)
      |> debug("announce_activity")

    assert data["actor"] == announce_actor.data["id"]
    assert data["type"] == "Announce"

    assert data["id"] ==
             "https://mastodon.local/users/admin/statuses/99542391527669785/activity"

    object =
      Object.get_ap_id(data["object"])
      |> debug("got_object")

    assert object =~ note_activity.data["object"]

    {:ok, fetched} =
      Fetcher.fetch_object_from_id(data["object"])
      |> debug("fetched_object")

    assert fetched.data["id"] == note_activity.data["object"]
    # assert fetched.id == note_activity.id
  end

  @tag :todo
  test "it works for incoming honk announces" do
    user = actor(ap_id: "https://mastodon.local/users/admin", local: false)
    other_user = local_actor()
    post = local_note_activity(%{actor: other_user, status: "bonkeronk"})

    announce = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "actor" => "https://mastodon.local/users/admin",
      "id" => "https://mastodon.local/users/admin/bonk/1793M7B9MQ48847vdx",
      "object" => post.data["object"],
      "published" => "2019-06-25T19:33:58Z",
      "to" => "https://www.w3.org/ns/activitystreams#Public",
      "type" => "Announce"
    }

    {:ok, %Activity{local: false}} = Transformer.handle_incoming(announce)

    {:ok, object} = Object.get_cached(ap_id: post.data["object"])

    assert is_list(debug(object.data["announcements"])) and
             length(object.data["announcements"]) == 1

    assert ap_id(user) in object.data["announcements"]
  end

  @tag :todo
  test "it works for incoming announces with actor being inlined (kroeg)" do
    data = file("fixtures/kroeg-announce-with-inline-actor.json") |> Jason.decode!()

    _user = actor(local: false, ap_id: data["actor"]["id"])
    other_user = local_actor()

    post = insert(:note_activity, %{actor: other_user, status: "kroegeroeg"})

    data =
      data
      |> put_in(["object", "id"], post.data["object"])

    {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

    assert data["actor"] == "https://puckipedia.local/"
  end

  test "it works for incoming announces, fetching the announced object" do
    data =
      file("fixtures/mastodon/mastodon-announce.json")
      |> Jason.decode!()
      |> Map.put("object", "https://mastodon.local/users/admin/statuses/99512778738411822")

    _user = actor(local: false, ap_id: data["actor"])

    {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

    assert data["actor"] == "https://mastodon.local/users/admin"
    assert data["type"] == "Announce"

    assert data["id"] ==
             "https://mastodon.local/users/admin/statuses/99542391527669785/activity"

    assert Object.get_ap_id(data["object"]) =~
             "https://mastodon.local/users/admin/statuses/99512778738411822"

    assert {:ok, _} = Fetcher.fetch_object_from_id(data["object"])
  end

  # Ignore inlined activities for now
  @tag skip: true
  test "it works for incoming announces with an inlined activity" do
    data =
      file("fixtures/mastodon/mastodon-announce-private.json")
      |> Jason.decode!()

    _user =
      insert(:actor,
        local: false,
        ap_id: data["actor"],
        follower_address: data["actor"] <> "/followers"
      )

    {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

    assert data["actor"] == "https://mastodon.local/users/admin"
    assert data["type"] == "Announce"

    assert data["id"] ==
             "https://mastodon.local/users/admin/statuses/99542391527669785/activity"

    object = Object.normalize(data["object"], fetch: false)

    assert object.data["id"] == "https://mastodon.local/@admin/99541947525187368"
    assert object.data["content"] == "this is a private toot"
  end

  test "it rejects incoming announces with an inlined activity from another origin" do
    Tesla.Mock.mock(fn
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    data =
      file("fixtures/bogus-mastodon-announce.json")
      |> Jason.decode!()

    # _user = actor(local: false, ap_id: data["actor"])

    assert {:error, _e} = Transformer.handle_incoming(data)
  end
end
