defmodule ActivityPub.WebFingerTest do
  use ActivityPub.DataCase

  alias ActivityPub.WebFinger
  alias ActivityPub.Actor
  import ActivityPub.Factory

  import Tesla.Mock

  setup do
    mock(fn env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env]) end)
    :ok
  end


  describe "fingering" do
    test "works with pleroma" do
      user = "karen@kawen.space"

      {:ok, data} = WebFinger.finger(user)

      assert data["id"] == "https://kawen.space/users/karen"
    end

    test "works with mastodon" do
      user = "karen@mastodon.example.org"

      {:ok, data} = WebFinger.finger(user)

      assert data["id"] == "https://mastodon.example.org/users/karen"
    end

    test "works with mastodon, with leading @" do
      user = "@karen@mastodon.example.org"

      {:ok, data} = WebFinger.finger(user)

      assert data["id"] == "https://mastodon.example.org/users/karen"
    end
  end
end
