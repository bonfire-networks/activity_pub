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
  @outbox_ids_url "https://mocked.local/users/karen/outbox_ids"

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

    test "fetches outbox with IDs-only entries (no inline objects)" do
      {:ok, entries} =
        Fetcher.fetch_outbox(%{"outbox" => @outbox_ids_url}, fetch_collection: true)

      assert is_list(entries)
      assert length(entries) == 2

      # a bare object URL should be fetched
      assert Enum.any?(entries, fn
               %Object{
                 data: %{
                   "id" => "https://mocked.local/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779"
                 }
               } ->
                 true

               _ ->
                 false
             end)

      # a Create activity wrapping an object ID (not inline) should also be fetched
      assert Enum.any?(entries, fn
               %Object{
                 data: %{
                   "id" => "https://testing.local/objects/d953809b-d968-49c8-aa8f-7545b9480a12"
                 }
               } ->
                 true

               _ ->
                 false
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

  # the collection is read here, and a fetch of each entry is queued, wherever the collection lists its entries: on itself, or on pages it links, as Bonfire serves a group's `narrower`
  describe "fetch_collection with mode: :entries_async" do
    @entries ["https://paged.local/actors/topic-1", "https://paged.local/actors/topic-2"]

    test "queues a fetch of each entry listed on the collection itself" do
      collection = "https://paged.local/collections/inline"

      serve(%{
        collection => ordered_collection(collection, %{"orderedItems" => @entries})
      })

      assert {:ok, _} = Fetcher.fetch_collection(collection, mode: :entries_async)

      for id <- @entries, do: assert_fetch_enqueued(id)
    end

    test "queues a fetch of each entry listed on the page the collection links as `first`" do
      collection = "https://paged.local/collections/linked-first"
      page = "#{collection}?page=1"

      serve(%{
        collection => ordered_collection(collection, %{"first" => page}),
        page => ordered_collection_page(page, collection, %{"orderedItems" => @entries})
      })

      assert {:ok, _} = Fetcher.fetch_collection(collection, mode: :entries_async)

      for id <- @entries, do: assert_fetch_enqueued(id)
    end

    test "queues a fetch of each entry on the `next` page of a `first` page embedded in the collection" do
      [first_entry, next_entry] = @entries
      collection = "https://paged.local/collections/embedded-first"
      next_page = "#{collection}?page=2"

      serve(%{
        collection =>
          ordered_collection(collection, %{
            "first" => %{
              "type" => "OrderedCollectionPage",
              "orderedItems" => [first_entry],
              "next" => next_page
            }
          }),
        next_page => ordered_collection_page(next_page, collection, %{"orderedItems" => [next_entry]})
      })

      assert {:ok, _} = Fetcher.fetch_collection(collection, mode: :entries_async)

      assert_fetch_enqueued(first_entry)
      assert_fetch_enqueued(next_entry)
    end
  end

  defp assert_fetch_enqueued(id) do
    assert_enqueued(
      worker: ActivityPub.Federator.Workers.RemoteFetcherWorker,
      args: %{"op" => "fetch_remote", "id" => id}
    )
  end

  defp serve(docs) do
    mock(fn %{method: :get, url: url} ->
      case docs[url] do
        nil -> %Tesla.Env{status: 404, body: ""}
        doc -> json(doc)
      end
    end)
  end

  defp ordered_collection(id, attrs) do
    Map.merge(
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => id,
        "type" => "OrderedCollection",
        "totalItems" => length(@entries)
      },
      attrs
    )
  end

  defp ordered_collection_page(id, collection, attrs) do
    Map.merge(
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => id,
        "type" => "OrderedCollectionPage",
        "partOf" => collection
      },
      attrs
    )
  end
end
