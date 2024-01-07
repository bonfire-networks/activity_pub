defmodule ActivityPub.LiveFederation.ActorTest do
  use ActivityPub.Web.ConnCase, async: false
  use Mneme
  import ActivityPub.Factory

  alias ActivityPub.Actor

  # WARNING: these are integration tests which run against real remote instances!
  @moduletag :live_federation
  # They only runs when you specifically instruct ex_unit to run this tag.

  test "get_or_fetch_by_ap_id/1" do
    # {:ok, actor} =
    auto_assert {:ok, %Actor{}} <-
                  Actor.get_cached_or_fetch(ap_id: "https://indieweb.social/users/bonfire")

    # auto_assert actor.data
    # assert actor.data["preferredUsername"] == "bonfire"
  end

  test "fetch_by_username/1" do
    {:ok, actor} = Actor.fetch_by_username("bonfire@indieweb.social")

    # auto_assert actor.data

    assert actor.data["preferredUsername"] == "bonfire"
  end
end
