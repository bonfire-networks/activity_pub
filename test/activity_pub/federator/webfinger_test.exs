defmodule ActivityPub.Federator.WebFingerTest do
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Federator.WebFinger
  alias ActivityPub.Actor
  import ActivityPub.Factory

  import Tesla.Mock

  setup_all do
    mock_global(fn env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env]) end)
    :ok
  end

  describe "incoming webfinger request" do
    test "works for fqns" do
      actor = local_actor()

      host = WebFinger.local_hostname()

      {:ok, result} = WebFinger.finger("#{actor.username}@#{host}")

      assert is_map(result)
    end

    test "works for ap_ids" do
      actor = local_actor()
      # {:ok, ap_actor} = Actor.get_cached(username: actor.username)

      {:ok, result} = WebFinger.finger(actor.data["id"])
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
