defmodule ActivityPub.Federator.WebFingerTest do
  use ActivityPub.DataCase

  alias ActivityPub.Federator.WebFinger
  alias ActivityPub.Actor
  import ActivityPub.Factory

  import Tesla.Mock

  setup do
    mock(fn env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env]) end)
    :ok
  end

  describe "incoming webfinger request" do
    @tag :fixme
    test "works for fqns" do
      actor = local_actor()

      host = Application.get_env(:activity_pub, :instance)[:hostname]

      {:ok, result} = WebFinger.finger("#{actor.username}@#{host}")

      assert is_map(result)
    end

    @tag :fixme
    test "works for ap_ids" do
      actor = local_actor()
      {:ok, ap_actor} = Actor.get_cached(username: actor.username)

      {:ok, result} = WebFinger.finger(ap_actor.data["id"])
      assert is_map(result)
    end
  end

  describe "fingering" do
    test "works with pleroma" do
      user = "karen@mocked.local"

      {:ok, data} = WebFinger.finger(user)

      assert data["id"] == "https://mocked.local/users/karen"
    end

    test "works with mastodon" do
      user = "karen@mastodon.local"

      {:ok, data} = WebFinger.finger(user)

      assert data["id"] == "https://mastodon.local/users/admin"
    end

    test "works with mastodon, with leading @" do
      user = "@karen@mastodon.local"

      {:ok, data} = WebFinger.finger(user)

      assert data["id"] == "https://mastodon.local/users/admin"
    end
  end
end
