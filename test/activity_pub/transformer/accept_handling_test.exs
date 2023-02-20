# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.AcceptHandlingTest do
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Federator.Transformer

  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  test "it works for incoming accepts which were pre-accepted" do
    follower = local_actor()
    followed = local_actor()

    {:ok, f} = follow(follower, followed)
    assert following?(follower, followed) == true

    follow_activity = ap_object_from_outgoing(f)

    accept_data =
      file("fixtures/mastodon/mastodon-accept-activity.json")
      |> Jason.decode!()
      |> Map.put("actor", followed.data["id"] || ap_id(followed))

    object =
      accept_data["object"]
      |> Map.put("actor", follower.data["id"] || ap_id(follower))
      |> Map.put("id", follow_activity.data["id"])

    accept_data = Map.put(accept_data, "object", object)

    {:ok, activity} = Transformer.handle_incoming(accept_data)
    refute activity.local

    assert Object.get_ap_id(activity.data["object"]) =~ follow_activity.data["id"]

    assert activity.data["id"] == accept_data["id"]

    follower = user_by_ap_id(follower)

    assert following?(follower, followed) == true
  end

  test "it works for incoming accepts which are referenced by IRI only" do
    follower = local_actor()
    followed = local_actor(request_before_follow: true)

    {:ok, f} = follow(follower, followed)
    follow_activity = ap_object_from_outgoing(f)

    accept_data =
      file("fixtures/mastodon/mastodon-accept-activity.json")
      |> Jason.decode!()
      |> Map.put("actor", followed.data["id"] || ap_id(followed))
      |> Map.put("object", follow_activity.data["id"])

    {:ok, a} = Transformer.handle_incoming(accept_data)
    accept_activity = ap_object_from_outgoing(a)
    assert Object.get_ap_id(accept_activity.data["object"]) =~ follow_activity.data["id"]

    assert following?(follower, followed) == true
  end

  test "it works for follow requests when you are already followed, creating a new accept activity" do
    # This is important because the remote might have the wrong idea about the
    # current follow status. This can lead to instance A thinking that x@A is
    # followed by y@B, but B thinks they are not. In this case, the follow can
    # never go through again because it will never get an Accept.
    user = local_actor()

    data =
      file("fixtures/mastodon/mastodon-follow-activity.json")
      |> Jason.decode!()
      |> Map.put("object", ap_id(user))

    {:ok, %Object{local: false}} = Transformer.handle_incoming(data)

    accepts =
      from(
        a in Object,
        where: fragment("?->>'type' = ?", a.data, "Accept")
      )
      |> repo().all()
      |> debug("accepts")

    assert length(accepts) == 1

    data =
      file("fixtures/mastodon/mastodon-follow-activity.json")
      |> Jason.decode!()
      |> Map.put("id", String.replace(data["id"], "2", "3"))
      |> Map.put("object", ap_id(user))

    {:ok, %Object{local: false}} = Transformer.handle_incoming(data)

    accepts =
      from(
        a in Object,
        where: fragment("?->>'type' = ?", a.data, "Accept")
      )
      |> repo().all()

    assert length(accepts) == 2
  end

  test "it fails for incoming accepts which cannot be correlated" do
    follower = local_actor()
    followed = local_actor(request_before_follow: true)

    accept_data =
      file("fixtures/mastodon/mastodon-accept-activity.json")
      |> Jason.decode!()
      |> Map.put("actor", followed.data["id"] || ap_id(followed))

    accept_data =
      Map.put(
        accept_data,
        "object",
        Map.put(accept_data["object"], "actor", follower.data["id"] || ap_id(follower))
      )

    {:error, _} = Transformer.handle_incoming(accept_data)

    follower = user_by_ap_id(follower)

    refute following?(follower, followed) == true
  end
end
