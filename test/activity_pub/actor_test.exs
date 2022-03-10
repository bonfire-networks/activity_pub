defmodule ActivityPub.ActorTest do
  use ActivityPub.DataCase
  import Tesla.Mock

  alias ActivityPub.Actor

  import ActivityPub.Factory

  setup do
    mock(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  test "get_by_username/1" do
    actor = local_actor()

    username = actor.username

    {:ok, fetched_actor} = ActivityPub.Actor.get_by_username(username)

    assert fetched_actor.data["preferredUsername"] == username
  end

  test "followers/1" do
    actor_1 = local_actor()
    actor_2 = local_actor()
    actor_3 = local_actor()

    follow(actor_1, actor_2)
    follow(actor_3, actor_2)

    {:ok, ap_actor_2} = Actor.get_by_ap_id(actor_2.data["id"])

    {:ok, actors} = Actor.get_followers(ap_actor_2)
    assert length(actors) == 2
  end

  test "followings/1" do
    actor_1 = local_actor()
    actor_2 = local_actor()
    actor_3 = local_actor()

    follow(actor_2, actor_1)
    follow(actor_2, actor_3)

    {:ok, ap_actor_2} = Actor.get_by_ap_id(actor_2.data["id"])

    {:ok, actors} = Actor.get_followings(ap_actor_2)
    assert length(actors) == 2
  end

  test "fetch_by_username/1" do
    {:ok, actor} = Actor.fetch_by_username("karen@kawen.space")

    assert actor.data["preferredUsername"] == "karen"
  end
end
