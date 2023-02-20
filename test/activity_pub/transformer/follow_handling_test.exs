# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.FollowHandlingTest do
  use ActivityPub.DataCase, async: false
  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Utils
  alias ActivityPub.Test.HttpRequestMock

  import ActivityPub.Factory
  import Ecto.Query
  import Mock
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  describe "handle_incoming" do
    test "it works for osada follow request" do
      user = local_actor()

      data =
        file("fixtures/osada-follow-activity.json")
        |> Jason.decode!()
        |> Map.put("object", ap_id(user))

      {:ok, %Activity{data: data, local: false} = activity} = Transformer.handle_incoming(data)

      assert data["actor"] == "https://apfed.local/channel/indio"
      assert data["type"] == "Follow"
      assert data["id"] == "https://apfed.local/follow/9"

      activity = refresh_record(Object, activity.id)
      assert activity.data["state"] == "accept"
      assert following?(user_by_ap_id(data["actor"]), user)
    end

    test "for unlocked accounts, it auto-Accepts incoming follow requests" do
      user = local_actor()

      data =
        file("fixtures/mastodon/mastodon-follow-activity.json")
        |> Jason.decode!()
        |> Map.put("object", ap_id(user))

      {:ok, %Activity{data: data, local: false} = activity} = Transformer.handle_incoming(data)

      assert data["actor"] == "https://mastodon.local/users/admin"
      assert data["type"] == "Follow"
      assert data["id"] == "https://mastodon.local/users/admin#follows/2"

      activity = refresh_record(Object, activity.id)
      assert activity.data["state"] == "accept"
      assert following?(user_by_ap_id(data["actor"]), user)

      # TODO
      # [notification] = Notification.for_user(user)
      # assert notification.type == "follow"
    end

    test "with locked accounts, it does create a Follow, but not an Accept" do
      user = local_actor(request_before_follow: true)

      data =
        file("fixtures/mastodon/mastodon-follow-activity.json")
        |> Jason.decode!()
        |> Map.put("object", ap_id(user))

      {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

      assert data["state"] == "pending"

      refute following?(user_by_ap_id(data["actor"]), user)

      accepts =
        from(
          a in Object,
          where: fragment("?->>'type' = ?", a.data, "Accept")
        )
        |> repo().all()

      assert Enum.empty?(accepts)

      # TODO
      # [notification] = Notification.for_user(user)
      # assert notification.type == "follow_request"
    end

    # TODO?
    # test "it rejects incoming follow requests if the following errors for some reason" do
    #   user = local_actor()

    #   data =
    #     file("fixtures/mastodon/mastodon-follow-activity.json")
    #     |> Jason.decode!()
    #     |> Map.put("object", ap_id(user))

    #   with_mock User, [:passthrough], follow: fn _, _, _ -> {:error, :testing} end do
    #     {:ok, %Activity{data: %{"id" => id}}} = Transformer.handle_incoming(data)

    #     %Activity{} = activity = Activity.get_cached(id: id)

    #     assert activity.data["state"] == "reject"
    #   end
    # end

    test "it works for incoming follow requests from hubzilla" do
      user = local_actor()

      data =
        file("fixtures/hubzilla-follow-activity.json")
        |> Jason.decode!()
        |> Map.put("object", ap_id(user))
        |> Object.normalize_params()

      {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

      assert data["actor"] == "https://hubzilla.local/channel/kaniini"
      assert data["type"] == "Follow"
      assert data["id"] == "https://hubzilla.local/channel/kaniini#follows/2"
      assert data["state"] == "accept"

      assert following?(user_by_ap_id(data["actor"]), user)
    end

    test "it works for incoming follows to locked account" do
      pending_follower = local_actor(ap_id: "https://mastodon.local/users/admin")
      user = local_actor(request_before_follow: true)

      data =
        file("fixtures/mastodon/mastodon-follow-activity.json")
        |> Jason.decode!()
        |> Map.put("object", ap_id(user))

      {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

      assert data["type"] == "Follow"
      assert Object.get_ap_id(data["object"]) =~ ap_id(user)
      assert data["state"] == "pending"
      assert data["actor"] == "https://mastodon.local/users/admin"

      refute following?(user_by_ap_id(pending_follower), user_by_ap_id(user))
    end
  end
end
