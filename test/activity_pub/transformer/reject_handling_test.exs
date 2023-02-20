# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.RejectHandlingTest do
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Object
  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Utils

  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  test "it rejects incoming follow requests from blocked users " do
    user = local_actor()

    {:ok, target} =
      ActivityPub.Actor.get_or_fetch_by_ap_id("https://mastodon.local/users/admin")
      |> debug("targettt")

    {:ok, _user_relationship} = block(user, target)

    data =
      file("fixtures/mastodon/mastodon-follow-activity.json")
      |> Jason.decode!()
      |> Map.put("object", ap_id(user))

    {:ok, %Activity{data: %{"id" => id}}} = Transformer.handle_incoming(data)

    {:ok, activity} = Activity.get_cached(ap_id: id)

    assert activity.data["state"] == "reject"
  end

  test "it fails for incoming rejects which cannot be correlated" do
    follower = local_actor()
    followed = local_actor(request_before_follow: true)

    accept_data =
      file("fixtures/mastodon/mastodon-reject-activity.json")
      |> Jason.decode!()
      |> Map.put("actor", ap_id(followed))

    accept_data =
      Map.put(accept_data, "object", Map.put(accept_data["object"], "actor", ap_id(follower)))

    {:error, _} = Transformer.handle_incoming(accept_data)

    follower = user_by_ap_id(follower)

    refute following?(follower, followed) == true
  end

  test "it works for incoming rejects which are referenced by IRI only" do
    follower = local_actor()
    followed = local_actor(request_before_follow: true)

    {:ok, f} = follow(follower, followed)
    follow_activity = ap_object_from_outgoing(f)

    assert following?(follower, followed) == true

    reject_data =
      file("fixtures/mastodon/mastodon-reject-activity.json")
      |> Jason.decode!()
      |> Map.put("actor", ap_id(followed))
      |> Map.put("object", follow_activity.data["id"])

    {:ok, %Activity{data: _}} = Transformer.handle_incoming(reject_data)

    follower = user_by_ap_id(follower)

    assert following?(follower, followed) == false
  end

  describe "when accept/reject references a transient activity" do
    test "it handles accept activities that do not contain an ID key" do
      follower = local_actor()
      followed = local_actor(request_before_follow: true)

      pending_follow =
        insert(:follow_activity, follower: follower, followed: followed, state: "pending")

      refute following?(follower, followed)

      without_id = Map.delete(pending_follow.data, "id")

      reject_data =
        file("fixtures/mastodon/mastodon-reject-activity.json")
        |> Jason.decode!()
        |> Map.put("actor", ap_id(followed))
        |> Map.delete("id")
        |> Map.put("object", without_id)

      {:ok, %Activity{data: _}} = Transformer.handle_incoming(reject_data)

      refute following?(user_by_ap_id(follower), user_by_ap_id(followed))
      assert Object.fetch_latest_follow(follower, followed).data["state"] == "reject"
    end

    test "it handles reject activities that do not contain an ID key" do
      follower = local_actor()
      followed = local_actor()
      {:ok, follow_activity} = follow(follower, followed)
      assert Object.fetch_latest_follow(follower, followed).data["state"] == "accept"
      assert following?(follower, followed)

      without_id = Map.delete(follow_activity.data, "id")

      reject_data =
        file("fixtures/mastodon/mastodon-reject-activity.json")
        |> Jason.decode!()
        |> Map.put("actor", ap_id(followed))
        |> Map.delete("id")
        |> Map.put("object", without_id)

      {:ok, %Activity{data: _}} = Transformer.handle_incoming(reject_data)

      follower = user_by_ap_id(follower)

      refute following?(follower, followed)
      assert Object.fetch_latest_follow(follower, followed).data["state"] == "reject"
    end

    test "it does not accept follows that are not in pending or accepted" do
      follower = local_actor()
      followed = local_actor(request_before_follow: true)

      rejected_follow =
        insert(:follow_activity, follower: follower, followed: followed, state: "reject")

      refute following?(follower, followed)

      without_id = Map.delete(rejected_follow.data, "id")

      accept_data =
        file("fixtures/mastodon/mastodon-accept-activity.json")
        |> Jason.decode!()
        |> Map.put("actor", ap_id(followed))
        |> Map.put("object", without_id)

      {:error, _} = Transformer.handle_incoming(accept_data)

      refute following?(follower, followed)
    end
  end

  test "it rejects activities without a valid ID" do
    user = local_actor()

    data =
      file("fixtures/mastodon/mastodon-follow-activity.json")
      |> Jason.decode!()
      |> Map.put("object", ap_id(user))
      |> Map.put("id", "")

    {:error, _} = Transformer.handle_incoming(data)
  end
end
