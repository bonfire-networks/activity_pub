defmodule ActivityPub.LiveFederation.ActorTest do
  use ActivityPub.Web.ConnCase, async: false
  import Tesla.Mock

  alias ActivityPub.Actor

  import ActivityPub.Factory

  @moduletag :live_federation

  test "fetch_by_username/1" do
    actor = ok_unwrap(Actor.fetch_by_username("bonfire@indieweb.social"))
    assert %ActivityPub.Actor{} = actor

    assert actor.data["preferredUsername"] == "bonfire"
  end

  test "get_or_fetch_by_ap_id/1" do
    actor = ok_unwrap(Actor.get_or_fetch_by_ap_id("https://indieweb.social/users/bonfire"))
    assert %ActivityPub.Actor{} = actor

    assert actor.data["preferredUsername"] == "bonfire"
  end
end
