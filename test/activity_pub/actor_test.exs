# MoodleNet: Connecting and empowering educators worldwide
# Copyright © 2018-2020 Moodle Pty Ltd <https://moodle.com/moodlenet/>
# Contains code from Pleroma <https://pleroma.social/> and CommonsPub <https://commonspub.org/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.ActorTest do
  use ActivityPub.DataCase
  import Tesla.Mock

  alias ActivityPub.Actor
  alias MoodleNet.Test.Faking
  import ActivityPub.Factory

  setup do
    mock(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  test "get_by_username/1" do
    actor = Faking.fake_user!()

    username = actor.actor.preferred_username

    {:ok, fetched_actor} = ActivityPub.Actor.get_by_username(username)

    assert fetched_actor.data["preferredUsername"] == username
  end

  test "external_followers/1" do
    community = Faking.fake_user!() |> Faking.fake_community!()
    actor_1 = actor()
    actor_2 = actor()
    {:ok, ap_community} = Actor.get_by_local_id(community.id)

    ActivityPub.follow(actor_1, ap_community, nil, false)
    ActivityPub.follow(actor_2, ap_community, nil, false)
    Oban.drain_queue(:ap_incoming)

    {:ok, actors} = Actor.get_external_followers(ap_community)
    assert length(actors) == 2
  end

  test "fetch_by_username/1" do
    {:ok, actor} = Actor.fetch_by_username("karen@kawen.space")

    assert actor.data["preferredUsername"] == "karen"
  end

  describe "format remote actor/1" do
    test "it creates local community actor" do
      actor = community()

      {:ok, actor} = Actor.get_by_ap_id(actor.data["id"])
      assert actor.data["type"] == "MN:Community"
    end

    test "it creates local collection actor" do
      actor = collection()

      {:ok, actor} = Actor.get_by_ap_id(actor.data["id"])
      assert actor.data["type"] == "MN:Collection"
    end
  end
end
