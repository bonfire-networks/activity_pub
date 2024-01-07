defmodule ActivityPub.LiveFederation.FetchTest do
  use ActivityPub.Web.ConnCase, async: false
  # use Mneme
  import ActivityPub.Factory

  alias ActivityPub.Federator.Fetcher

  # WARNING: these are integration tests which run against real remote instances!
  @moduletag :live_federation
  # They only runs when you specifically instruct ex_unit to run this tag.

  test "Lookup by link tag" do
    {:ok, data} =
      Fetcher.fetch_remote_object_from_id("https://bovine.social/http_activitypub_test/case1",
        return_tombstones: true
      )

    assert data["content"] =~ "Test Case 1"
  end

  test "Lookup by link header" do
    {:ok, data} =
      Fetcher.fetch_remote_object_from_id("https://bovine.social/http_activitypub_test/case2",
        return_tombstones: true
      )

    assert data["content"] =~ "Test Case 2"
  end

  test "Return ActivityPub Object" do
    {:ok, data} =
      Fetcher.fetch_remote_object_from_id("https://bovine.social/http_activitypub_test/case3",
        return_tombstones: true
      )

    assert data["content"] =~ "Test Case 3"
  end

  test "Redirect to ActivityPub Object" do
    {:ok, data} =
      Fetcher.fetch_remote_object_from_id("https://bovine.social/http_activitypub_test/case4",
        return_tombstones: true
      )

    assert data["content"] =~ "Test Case 4"
  end
end
