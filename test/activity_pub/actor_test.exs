defmodule ActivityPub.ActorTest do
  use ActivityPub.DataCase
  import Tesla.Mock

  alias ActivityPub.Actor

  import ActivityPub.Factory

  setup do
    mock(fn
      %{method: :get, url: "https://fedi.local/userisgone502"} ->
        %Tesla.Env{status: 502}

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
    actor = ok_unwrap(Actor.fetch_by_username("karen@mocked.local"))
    assert %ActivityPub.Actor{} = actor

    assert actor.data["preferredUsername"] == "karen"
  end

  test "get_or_fetch_by_ap_id/1" do
    actor = ok_unwrap(Actor.get_or_fetch_by_ap_id("https://mastodon.local/users/admin"))
    assert %ActivityPub.Actor{} = actor

    assert actor.data["preferredUsername"] == "karen"
  end

  test "get_or_fetch_by_ap_id/1 with unresponsive remote" do
    assert {:error, _} = Actor.get_or_fetch_by_ap_id("https://fedi.local/userisgone502")
  end

  test "followers/1" do
    actor_1 = local_actor()
    actor_2 = local_actor()
    actor_3 = local_actor()

    follow(actor_1, actor_2)
    follow(actor_3, actor_2)

    {:ok, ap_actor_2} = Actor.get_cached(ap_id: actor_2.data["id"])

    {:ok, actors} = Actor.get_followers(ap_actor_2)
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
