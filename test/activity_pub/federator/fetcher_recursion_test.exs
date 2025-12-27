defmodule ActivityPub.Federator.FetcherRecursionTest do
  use ActivityPub.DataCase, async: false
  import Tesla.Mock
  import Mock

  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.WebFinger

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Instances
  alias ActivityPub.Object

  alias ActivityPub.Test.HttpRequestMock

  setup_all do
    mock_global(fn
      env ->
        HttpRequestMock.request(env)
    end)

    :ok
  end

  describe "max thread distance restriction" do
    @ap_id "https://mastodon.local/@admin/99512778738411822"
    @reply_ap_id "https://mastodon.local/users/admin/statuses/8511"
    @reply_2_ap_id "https://mocked.local/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779"

    setup do: clear_config([:instance, :federation_incoming_max_recursion])

    test "it returns error if thread depth is exceeded" do
      clear_config([:instance, :federation_incoming_max_recursion], 0)

      assert {:error, "Stopping to avoid too much recursion"} =
               Fetcher.fetch_object_from_id(@ap_id, depth: 1)

      assert {:error, :not_found} = ActivityPub.Object.get_cached(ap_id: @ap_id)
    end

    test "it fetches object if max thread depth is restricted to 0 and depth is not specified" do
      clear_config([:instance, :federation_incoming_max_recursion], 0)

      assert {:ok, _} = Fetcher.fetch_object_from_id(@ap_id)
    end

    test "it fetches object if requested depth does not exceed max thread depth" do
      clear_config([:instance, :federation_incoming_max_recursion], 10)

      assert {:ok, _} = Fetcher.fetch_object_from_id(@ap_id, depth: 10)
    end

    test "it fetches reply_to and replies if thread depth is not exceeded" do
      clear_config([:instance, :federation_incoming_max_recursion], 4)

      assert {:ok, _} =
               Fetcher.fetch_object_from_id(@reply_ap_id,
                 fetch_collection_entries: :async,
                 depth: 2
               )

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert {:ok, _} = ActivityPub.Object.get_cached(ap_id: @reply_ap_id)
      assert {:ok, _} = ActivityPub.Object.get_cached(ap_id: @ap_id)
      assert {:ok, _} = ActivityPub.Object.get_cached(ap_id: @reply_2_ap_id)
    end

    test "it fetches reply_to if thread depth is not exceeded" do
      clear_config([:instance, :federation_incoming_max_recursion], 2)

      assert {:ok, _} =
               Fetcher.fetch_object_from_id(@reply_ap_id, depth: 1)

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert {:ok, _} = ActivityPub.Object.get_cached(ap_id: @reply_ap_id)
      assert {:ok, _} = ActivityPub.Object.get_cached(ap_id: @ap_id)
      assert {:error, :not_found} = ActivityPub.Object.get_cached(ap_id: @reply_2_ap_id)
    end

    test "it does not fetch reply_to if thread depth is exceeded" do
      clear_config([:instance, :federation_incoming_max_recursion], 3)

      assert {:ok, _} =
               Fetcher.fetch_object_from_id(@reply_ap_id, depth: 3)

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert {:ok, _} = ActivityPub.Object.get_cached(ap_id: @reply_ap_id)
      assert {:error, :not_found} = ActivityPub.Object.get_cached(ap_id: @ap_id)
      assert {:error, :not_found} = ActivityPub.Object.get_cached(ap_id: @reply_2_ap_id)
    end
  end
end
