defmodule ActivityPub.Federator.FetcherCollectionsTest do
  @moduledoc """
  Tests for fetch_outbox and fetch_thread functions in the Fetcher.
  Pure AP-level tests with no Bonfire dependencies.
  """
  use ActivityPub.DataCase, async: false
  use Oban.Testing, repo: repo()
  import Tesla.Mock

  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Object
  alias ActivityPub.Test.HttpRequestMock

  @karen_ap_id "https://mocked.local/users/karen"
  @outbox_url "https://mocked.local/users/karen/outbox"

  setup_all do
    mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  describe "fetch_outbox" do
    test "fetches outbox from actor data map" do
      {:ok, entries} =
        Fetcher.fetch_outbox(%{"outbox" => @outbox_url}, fetch_collection: true)

      assert is_list(entries)
      assert length(entries) == 2

      assert Enum.any?(entries, fn
               %Object{data: %{"id" => "https://mocked.local/objects/outbox-note-1"}} -> true
               _ -> false
             end)
    end

    test "fetches outbox from actor struct with data" do
      {:ok, actor} = Fetcher.fetch_object_from_id(@karen_ap_id)

      {:ok, entries} =
        Fetcher.fetch_outbox(actor, fetch_collection: true)

      assert is_list(entries)
      assert length(entries) == 2
    end

    test "fetches outbox by pointer lookup" do
      {:ok, actor} = Fetcher.fetch_object_from_id(@karen_ap_id)

      {:ok, entries} =
        Fetcher.fetch_outbox([pointer: actor.id], fetch_collection: true)

      assert is_list(entries)
      assert length(entries) == 2
    end

    test "handles actor without outbox URL" do
      result = Fetcher.fetch_outbox(%{"outbox" => nil}, fetch_collection: true)
      refute match?({:ok, [_ | _]}, result)
    end

    test "async mode queues fetch via Oban" do
      {:ok, _} = Fetcher.fetch_outbox(%{"outbox" => @outbox_url}, fetch_collection: :async)

      assert_enqueued(
        worker: ActivityPub.Federator.Workers.RemoteFetcherWorker,
        args: %{"op" => "fetch_remote", "id" => @outbox_url}
      )
    end
  end

  describe "fetch_thread" do
    test "processes object data with replies and inReplyTo" do
      data = %{
        "id" => "https://mocked.local/objects/outbox-note-2",
        "type" => "Note",
        "inReplyTo" => "https://mocked.local/objects/outbox-note-1",
        "replies" => %{
          "id" => "https://mocked.local/objects/outbox-note-2/replies",
          "type" => "OrderedCollection",
          "totalItems" => 0,
          "first" => "https://mocked.local/objects/outbox-note-2/replies?page=1"
        }
      }

      result = Fetcher.fetch_thread(data, fetch_collection: false)

      assert is_map(result)
      # fix_in_reply_to should have processed inReplyTo
      assert result["inReplyTo"]
    end

    test "fetches thread from object struct" do
      {:ok, note} =
        Fetcher.fetch_object_from_id(
          "https://mocked.local/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779"
        )

      result = Fetcher.fetch_thread(note, fetch_collection: false)
      assert is_map(result)
    end

    test "fetches thread by pointer lookup" do
      {:ok, note} =
        Fetcher.fetch_object_from_id(
          "https://mocked.local/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779"
        )

      result = Fetcher.fetch_thread([pointer: note.id], fetch_collection: false)
      assert is_map(result)
    end

    test "handles object with no replies gracefully" do
      data = %{
        "id" => "https://mocked.local/objects/no-replies",
        "type" => "Note",
        "content" => "A note without replies"
      }

      result = Fetcher.fetch_thread(data, fetch_collection: false)
      assert is_map(result)
      refute Map.has_key?(result, "replies")
    end

    test "returns error for non-existent pointer" do
      result = Fetcher.fetch_thread([pointer: Ecto.UUID.generate()], fetch_collection: false)
      assert {:error, _} = result
    end
  end
end
