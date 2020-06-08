# MoodleNet: Connecting and empowering educators worldwide
# Copyright © 2018-2020 Moodle Pty Ltd <https://moodle.com/moodlenet/>
# Contains code from Pleroma <https://pleroma.social/> and CommonsPub <https://commonspub.org/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.ActivityPubControllerTest do
  use ActivityPubWeb.ConnCase

  import ActivityPub.Factory

  describe "object" do
    test "works for activities" do
      activity = insert(:note_activity)

      uuid =
        String.split(activity.data["id"], "/")
        |> List.last()

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/pub/objects/#{uuid}")
        |> json_response(200)

      assert resp["@context"]
      assert resp["type"] == "Create"
    end

    test "works for objects" do
      object = insert(:note)

      uuid =
        String.split(object.data["id"], "/")
        |> List.last()

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/pub/objects/#{uuid}")
        |> json_response(200)

      assert resp["@context"]
      assert resp["type"] == "Note"
    end
  end

  describe "actor" do
    test "works for actors" do
      actor = fake_user!()

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("pub/actors/#{actor.actor.preferred_username}")
        |> json_response(200)

      assert resp["@context"]
      assert resp["preferredUsername"] == actor.actor.preferred_username
      assert resp["url"] == resp["id"]
    end

    test "following collection" do
      actor = fake_user!()
      following = fake_user!()

      MoodleNet.Follows.create(actor, following, %{is_local: true})
      {:ok, ap_actor} = ActivityPub.Actor.get_by_local_id(actor.id)

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("pub/actors/#{ap_actor.username}/following")
        |> json_response(200)

      assert length(resp["first"]["orderedItems"]) == 1
      assert resp["totalItems"] == 1
      assert resp["type"] == "Collection"
      assert String.ends_with?(resp["id"], "/following")
    end

    test "following collection pagination" do
      actor = fake_user!()
      following = fake_user!()

      MoodleNet.Follows.create(actor, following, %{is_local: true})
      {:ok, ap_actor} = ActivityPub.Actor.get_by_local_id(actor.id)

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("pub/actors/#{ap_actor.username}/following?page=1")
        |> json_response(200)

      assert length(resp["orderedItems"]) == 1
      assert resp["totalItems"] == 1
      assert resp["type"] == "CollectionPage"
      assert String.ends_with?(resp["id"], "/following?page=1")
    end

    test "follower collection" do
      actor = fake_user!()
      follower = fake_user!()

      MoodleNet.Follows.create(follower, actor, %{is_local: true})
      {:ok, ap_actor} = ActivityPub.Actor.get_by_local_id(actor.id)

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("pub/actors/#{ap_actor.username}/followers")
        |> json_response(200)

      assert length(resp["first"]["orderedItems"]) == 1
      assert resp["totalItems"] == 1
      assert resp["type"] == "Collection"
      assert String.ends_with?(resp["id"], "/followers")
    end

    test "follower collection pagination" do
      actor = fake_user!()
      follower = fake_user!()

      MoodleNet.Follows.create(follower, actor, %{is_local: true})
      {:ok, ap_actor} = ActivityPub.Actor.get_by_local_id(actor.id)

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("pub/actors/#{ap_actor.username}/followers?page=1")
        |> json_response(200)

      assert length(resp["orderedItems"]) == 1
      assert resp["totalItems"] == 1
      assert resp["type"] == "CollectionPage"
      assert String.ends_with?(resp["id"], "/followers?page=1")
    end
  end
end
