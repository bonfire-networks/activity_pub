defmodule ActivityPub.ActorTest do
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Actor

  import ActivityPub.Factory

  import Tesla.Mock

  setup_all do
    mock_global(fn
      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  test "get local actor by username" do
    actor = local_actor()

    username = actor.username

    {:ok, fetched_actor} = ActivityPub.Actor.get_cached(username: username)

    assert fetched_actor.data["preferredUsername"] == username
  end

  test "fetch_by_username/1" do
    actor = from_ok(Actor.fetch_by_username("karen@mocked.local"))
    assert %ActivityPub.Actor{} = actor

    assert actor.data["preferredUsername"] == "karen"
  end

  test "get_or_fetch_by_ap_id/1" do
    actor = from_ok(Actor.get_cached_or_fetch(ap_id: "https://mastodon.local/users/admin"))
    assert %ActivityPub.Actor{} = actor

    assert actor.data["preferredUsername"] == "karen"
  end

  test "get_or_fetch_by_ap_id/1 with unresponsive remote" do
    assert {:error, _} = Actor.get_cached_or_fetch(ap_id: "https://fedi.local/userisgone502")
  end

  test "followers/1" do
    actor_1 = local_actor()
    actor_2 = local_actor()
    actor_3 = local_actor()

    follow(actor_1, actor_2)
    follow(actor_3, actor_2)

    {:ok, ap_actor_2} = Actor.get_cached(ap_id: actor_2.data["id"])

    actors = Actor.get_followers(ap_actor_2)
    assert length(actors) == 2
  end

  # FIXME: not implemented in TestAdapter
  # test "followings/1" do
  #   actor_1 = local_actor()
  #   actor_2 = local_actor()
  #   actor_3 = local_actor()

  #   follow(actor_2, actor_1)
  #   follow(actor_2, actor_3)

  #   {:ok, ap_actor_2} = Actor.get_cached(ap_id: actor_2.data["id"])

  #   {:ok, actors} = Actor.get_followings(ap_actor_2)
  #   assert length(actors) == 2
  # end
end
