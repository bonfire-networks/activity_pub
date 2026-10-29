defmodule ActivityPub.LiveFederation.FetchTest do
  use ActivityPub.Web.ConnCase, async: false
  # use Mneme
  import ActivityPub.Factory

  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Instances

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

  # zotum.net runs h2o, which answers OTP's TLS 1.3 key share with a HelloRetryRequest and no compatibility ChangeCipherSpec, which `:ssl` refuses by default
  test "fetches from a server whose TLS 1.3 handshake skips the compatibility ChangeCipherSpec" do
    Instances.delete_host_cache("zotum.net", :tls_compat)

    {:ok, data} =
      Fetcher.fetch_remote_object_from_id(
        "https://zotum.net/item/b5f69b76-a5b8-492c-8ffb-2c0c89492e79"
      )

    assert data["content"] =~ "100% agreed"
    assert Instances.get_host_cache("zotum.net", :tls_compat) == true
  end
end
