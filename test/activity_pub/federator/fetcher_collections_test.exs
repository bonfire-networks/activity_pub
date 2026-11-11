defmodule ActivityPub.Federator.FetcherCollectionsTest do
  @moduledoc """
  Tests for fetch_outbox and fetch_thread functions in the Fetcher.
  Pure AP-level tests with no Bonfire dependencies.
  """
  use ActivityPub.DataCase, async: false
  use Oban.Testing, repo: repo()
  use Repatch.ExUnit
  import Tesla.Mock
  import ActivityPub.Factory, only: [local_actor: 0]

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
        next_page =>
          ordered_collection_page(next_page, collection, %{"orderedItems" => [next_entry]})
      })

      assert {:ok, _} = Fetcher.fetch_collection(collection, mode: :entries_async)

      assert_fetch_enqueued(first_entry)
      assert_fetch_enqueued(next_entry)
    end
  end

  # a members-only collection (Mobilizon serves its members only to a signed member) is read as the actor given, never from the copy we hold of what a non-member sees, and `max_items` lifts the cap on how many items are read
  describe "fetch_collection signed as an actor" do
    @members_root "https://members.local/groups/g/members"
    @member_ids for n <- 1..23, do: "https://members.local/actors/m-#{n}"

    setup do
      test = self()
      {:ok, signer} = ActivityPub.Actor.get_cached(username: local_actor().username)
      {:ok, signer} = ActivityPub.Safety.Keys.ensure_keys_present(signer)

      # the non-member shape, as we may hold it from an earlier unsigned read: the count and no items
      {:ok, _} =
        Object.do_insert(%{
          data: %{
            "id" => @members_root,
            "type" => "OrderedCollection",
            "totalItems" => 23
          },
          local: false,
          is_object: true
        })

      pages =
        @member_ids
        |> Enum.chunk_every(10)
        |> Enum.with_index(1)
        |> Map.new(fn {ids, n} ->
          page = %{
            "id" => "#{@members_root}?page=#{n}",
            "type" => "OrderedCollectionPage",
            "partOf" => @members_root,
            "orderedItems" => ids
          }

          {page["id"],
           if(n < 3, do: Map.put(page, "next", "#{@members_root}?page=#{n + 1}"), else: page)}
        end)

      docs =
        Map.put(pages, @members_root, %{
          "id" => @members_root,
          "type" => "OrderedCollection",
          "totalItems" => 23,
          "first" => "#{@members_root}?page=1"
        })

      mock(fn %{method: :get, url: url, headers: headers} ->
        signed_by_signer? =
          Enum.any?(headers, fn {k, v} ->
            String.downcase(k) in ["signature", "signature-input"] and
              String.contains?(v, signer.ap_id)
          end)

        send(test, {:members_get, url, signed_by_signer?})

        cond do
          not Map.has_key?(docs, url) -> %Tesla.Env{status: 404, body: ""}
          signed_by_signer? -> json(docs[url])
          true -> %Tesla.Env{status: 403, body: ""}
        end
      end)

      {:ok, signer: signer}
    end

    defp members_gets(acc \\ []) do
      receive do
        {:members_get, url, signed?} -> members_gets([{url, signed?} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "signs the root and each page as that actor, and does not serve the root from the copy we hold",
         %{signer: signer} do
      assert {:ok, entries} =
               Fetcher.fetch_collection(@members_root,
                 mode: :entries_async,
                 current_actor: {:ok, signer},
                 max_items: 50
               )

      assert Enum.sort(entries) == Enum.sort(@member_ids)

      gets = members_gets()
      assert {@members_root, true} in gets
      assert {"#{@members_root}?page=1", true} in gets
      assert {"#{@members_root}?page=3", true} in gets
    end

    test "reads the root fresh, signed as the user, when only the user's id is passed", %{
      signer: signer
    } do
      assert {:ok, entries} =
               Fetcher.fetch_collection(@members_root,
                 mode: :entries_async,
                 user_id: signer.id,
                 max_items: 50
               )

      assert length(entries) == 23
      assert {@members_root, true} in members_gets()
    end

    test "control: without `max_items`, 10 items are read", %{signer: signer} do
      assert {:ok, entries} =
               Fetcher.fetch_collection(@members_root,
                 mode: :entries_async,
                 current_actor: {:ok, signer}
               )

      assert length(entries) == 10
    end

    # the job reads the collection as the user it carries, whole, and hands its items to the adapter with the type and owner it was queued with, so the extension that claims the type applies them
    test "a fetch job with a collection type hands the items to the adapter", %{signer: signer} do
      test = self()

      Repatch.patch(ActivityPub.Federator.Adapter, :handle_remote_collection, fn collection,
                                                                                 items ->
        send(test, {:handled, collection, items})
        {:ok, :handled}
      end)

      args = %{
        "op" => "fetch_collection",
        "id" => @members_root,
        "collection_type" => "members",
        "owner" => "https://members.local/groups/g",
        "user_id" => signer.id,
        "fetch_collection_entries" => "none",
        "max_items" => 50,
        "max_pages" => 5,
        "max_total" => 50
      }

      assert {:ok, :handled} =
               perform_job(ActivityPub.Federator.Workers.RemoteFetcherWorker, args)

      assert_received {:handled, %{type: "members", owner: "https://members.local/groups/g"},
                       items}

      assert Enum.sort(items) == Enum.sort(@member_ids)

      # the control: a collection over the number of items asked for is not read past its root, nor handed over
      flush_members_gets()

      assert {:cancel, _} =
               perform_job(
                 ActivityPub.Federator.Workers.RemoteFetcherWorker,
                 Map.put(args, "max_total", 5)
               )

      refute_received {:handled, _, _}
      assert [{@members_root, true}] = members_gets()
    end

    defp flush_members_gets, do: members_gets()
  end

  # a fetch made for one of our users is signed as them, so what the origin shows its members (or refuses to a signed-out reader) is what that user sees; the service actor signs the rest
  describe "a fetch made for a user" do
    @for_user_url "https://signing.local/objects/1"

    setup do
      test = self()
      {:ok, user_actor} = ActivityPub.Actor.get_cached(username: local_actor().username)
      {:ok, other_actor} = ActivityPub.Actor.get_cached(username: local_actor().username)
      {:ok, service_actor} = ActivityPub.Utils.service_actor()

      mock(fn
        %{method: :get, url: @for_user_url, headers: headers} ->
          send(test, {:signed_with, @for_user_url, signing_headers(headers)})

          json(%{
            "id" => @for_user_url,
            "type" => "Note",
            "content" => "hello",
            "attributedTo" => "https://signing.local/users/a"
          })

        env ->
          HttpRequestMock.request(env)
      end)

      {:ok, user: user_actor, other: other_actor, service: service_actor}
    end

    defp signing_headers(headers) do
      for {k, v} <- headers, String.downcase(k) in ["signature", "signature-input"], do: v
    end

    defp signed_by?(actor) do
      assert_received {:signed_with, @for_user_url, values}
      Enum.any?(values, &String.contains?(&1, actor.ap_id))
    end

    test "is signed as that user when it carries a local user's id", %{user: user} do
      assert {:ok, _} = Fetcher.fetch_remote_object_from_id(@for_user_url, user_id: user.id)
      assert signed_by?(user)
    end

    test "is signed as that user when it carries them as `current_user`, too", %{user: user} do
      assert {:ok, _} =
               Fetcher.fetch_remote_object_from_id(@for_user_url, current_user: user.pointer)

      assert signed_by?(user)
    end

    # their keys are made at the start of the fetch (the work it leads to runs in a transaction, where making them failed), and the request is signed with them
    test "a user with no keys yet gets them, and the fetch is signed with them", %{user: user} do
      # the Note has no addressing, so handling it is refused: what is checked is the signing
      _ = Fetcher.fetch_object_from_id(@for_user_url, user_id: user.id)

      assert signed_by?(user)
      assert {:ok, %{keys: keys}} = ActivityPub.Actor.get_cached(pointer: user.id)
      assert is_binary(keys)
    end

    test "is signed as that user when a fetch job carries their id", %{user: user} do
      perform_job(ActivityPub.Federator.Workers.RemoteFetcherWorker, %{
        "op" => "fetch_remote",
        "id" => @for_user_url,
        "user_id" => user.id
      })

      assert signed_by?(user)
    end

    test "control: with no user it is signed as the service actor", %{
      user: user,
      service: service
    } do
      assert {:ok, _} = Fetcher.fetch_remote_object_from_id(@for_user_url)
      assert_received {:signed_with, @for_user_url, values}
      assert Enum.any?(values, &String.contains?(&1, service.ap_id))
      refute Enum.any?(values, &String.contains?(&1, user.ap_id))
    end

    test "control: an explicit `current_actor` wins over the user's id", %{
      user: user,
      other: other
    } do
      assert {:ok, _} =
               Fetcher.fetch_remote_object_from_id(@for_user_url,
                 user_id: user.id,
                 current_actor: {:ok, other}
               )

      assert signed_by?(other)
    end

    test "control: the id of a user who is not local falls back to the service actor", %{
      service: service
    } do
      {:ok, _} = Fetcher.fetch_object_from_id(@karen_ap_id)
      {:ok, remote} = ActivityPub.Actor.get_cached(ap_id: @karen_ap_id)
      refute remote.local, "control: a remote actor"
      assert {:ok, _} = Fetcher.fetch_remote_object_from_id(@for_user_url, user_id: remote.id)
      assert signed_by?(service)
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
