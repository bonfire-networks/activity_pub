defmodule ActivityPub.ObjectListCachedTest do
  @moduledoc """
  `ActivityPub.Object.list_cached/2` — the batched, N+1-avoiding sibling of `get_cached/1`. Resolves
  a list of refs (ap_id URIs / pointer ULIDs) with **one query per kind** for the cache misses,
  populating the cache the same way `get_with_cache` does, and returning results in input order.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Object
  alias ActivityPub.Utils

  test "returns objects for ap_id refs in input order" do
    [a, b, c] = for _ <- 1..3, do: insert(:note)
    refs = [a.data["id"], c.data["id"], b.data["id"]]

    result = Object.list_cached(refs)

    assert Enum.map(result, & &1.data["id"]) == refs
  end

  test "drops missing refs by default; keeps nil with keep_nil: true" do
    a = insert(:note)
    ghost = "https://nowhere.local/objects/#{System.unique_integer([:positive])}"

    assert [obj] = Object.list_cached([a.data["id"], ghost])
    assert obj.data["id"] == a.data["id"]

    assert [obj2, nil] = Object.list_cached([a.data["id"], ghost], keep_nil: true)
    assert obj2.data["id"] == a.data["id"]
  end

  test "resolves N uncached ap_id refs with a single batched query (no N+1)" do
    notes = for _ <- 1..3, do: insert(:note)
    ap_ids = Enum.map(notes, & &1.data["id"])

    handler_id = {__MODULE__, make_ref()}
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    query_event =
      (Bonfire.Common.Repo.config()[:telemetry_prefix] || [:bonfire, :repo]) ++ [:query]

    # attach AFTER the inserts, detach after the call → only list_cached's queries fall in the window
    :telemetry.attach(
      handler_id,
      query_event,
      fn _event, _measure, _meta, _cfg -> Agent.update(counter, &(&1 + 1)) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert length(Object.list_cached(ap_ids)) == 3
    # one batched SELECT for all three misses, not three (cache off → no cache reads either)
    assert Agent.get(counter, & &1) == 1
  end

  test "populates the cache (and aliases) so a later get_cached hits" do
    Process.put(:activity_pub_enable_cache, true)
    on_exit(fn -> Utils.cache_clear() end)

    notes = for _ <- 1..2, do: insert(:note)
    ap_ids = Enum.map(notes, & &1.data["id"])

    assert length(Object.list_cached(ap_ids)) == 2

    # delete the rows; if list_cached populated the cache, get_cached still resolves them
    Enum.each(notes, &repo().delete/1)

    for note <- notes do
      assert {:ok, obj} = Object.get_cached(ap_id: note.data["id"])
      assert obj.data["id"] == note.data["id"]
    end
  end

  test "query(ap_id:) matches by non-canonical `url` fallback (single + batch heads)" do
    canonical = "https://remote.test/objects/#{System.unique_integer([:positive])}"
    url = "https://remote.test/notes/#{System.unique_integer([:positive])}"

    {:ok, _} =
      %Object{}
      |> Ecto.Changeset.change(%{
        data: %{"id" => canonical, "url" => url, "type" => "Note"},
        local: false,
        public: true,
        is_object: true
      })
      |> repo().insert()

    # the query heads themselves resolve by url (the md5(url) branch) — single value and list
    assert [a] = repo().all(Object.query(ap_id: url))
    assert a.data["id"] == canonical

    assert [b] = repo().all(Object.query(ap_id: [url]))
    assert b.data["id"] == canonical
  end

  test "resolves pointer-ULID refs" do
    # a real pointer with no ap_object yet (local users resolve via the adapter, not ap_object)
    pointer_id = local_actor().user.id
    ap_id = "https://remote.test/objects/#{System.unique_integer([:positive])}"

    {:ok, _} =
      %Object{}
      |> Ecto.Changeset.change(%{
        data: %{"id" => ap_id, "type" => "Note"},
        pointer_id: pointer_id,
        local: false,
        public: true,
        is_object: true
      })
      |> repo().insert()

    assert [obj] = Object.list_cached([pointer_id])
    assert obj.pointer_id == pointer_id
  end
end
