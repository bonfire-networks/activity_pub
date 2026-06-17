defmodule ActivityPub.ObjectCacheTest do
  @moduledoc """
  Characterization of `ActivityPub.Object.get_cached/1` (built on `Utils.get_with_cache/5`) — pins the
  caching mechanics that `list_cached/2` must reproduce and that the (future) DRY refactor must
  preserve:

  - a cache **hit avoids the DB** (a fetched object is still returned after its row is deleted);
  - **alias population** (`maybe_multi_cache`): fetching by one key (`ap_id`) also caches the row under
    its other keys (`id`), so a later lookup by a different key hits without a DB read;
  - `:not_found` is **negatively cached**.

  Uses unique ids per test so the shared (global) cache doesn't bleed across tests; `async: false`
  for the same reason.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Object
  alias ActivityPub.Utils

  setup do
    # caching is bypassed in the test env by default (cachex_fetch short-circuit); opt this process in
    # so the real hit/alias/negative-cache mechanics run. Unique ids per test keep entries isolated.
    Process.put(:activity_pub_enable_cache, true)
    on_exit(fn -> Utils.cache_clear() end)
    :ok
  end

  describe "get_with_cache/5 (the primitive)" do
    # use the `:json` key so `maybe_multi_cache` is skipped (the getter returns a plain map, not an
    # Object with id/ap_id/pointer to alias) — isolating the bare cache-once behaviour
    test "invokes the getter once, then serves subsequent calls from cache" do
      id = "cachetest-#{System.unique_integer([:positive])}"
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      getter = fn [{:json, ^id}] ->
        Agent.update(counter, &(&1 + 1))
        {:ok, %{"value" => "hello"}}
      end

      assert {:ok, %{"value" => "hello"}} =
               Utils.get_with_cache(getter, :ap_object_cache, :json, id)

      assert {:ok, %{"value" => "hello"}} =
               Utils.get_with_cache(getter, :ap_object_cache, :json, id)

      assert Agent.get(counter, & &1) == 1
    end

    test "negatively caches :not_found (getter not re-invoked)" do
      id = "cachemiss-#{System.unique_integer([:positive])}"
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      getter = fn [{:json, ^id}] ->
        Agent.update(counter, &(&1 + 1))
        {:error, :not_found}
      end

      assert {:error, :not_found} = Utils.get_with_cache(getter, :ap_object_cache, :json, id)
      assert {:error, :not_found} = Utils.get_with_cache(getter, :ap_object_cache, :json, id)

      assert Agent.get(counter, & &1) == 1
    end
  end

  test "a cache hit avoids the DB (still resolves after the row is deleted)" do
    note = insert(:note)
    ap_id = note.data["id"]

    assert {:ok, cached} = Object.get_cached(ap_id: ap_id)
    assert cached.data["id"] == ap_id

    # delete the underlying row directly, leaving the cache populated
    assert {:ok, _} = repo().delete(note)

    # still served from cache despite the row being gone → proves it didn't hit the DB
    assert {:ok, again} = Object.get_cached(ap_id: ap_id)
    assert again.data["id"] == ap_id
  end

  test "fetching by ap_id also populates the :id alias (maybe_multi_cache)" do
    note = insert(:note)
    ap_id = note.data["id"]
    uuid = note.id

    # populate the cache via the ap_id key
    assert {:ok, _} = Object.get_cached(ap_id: ap_id)

    # remove the row so a DB lookup would now miss
    assert {:ok, _} = repo().delete(note)

    # the ap_id fetch also cached the row under its :id key → this hits cache, not the (gone) row
    assert {:ok, by_id} = Object.get_cached(id: uuid)
    assert by_id.data["id"] == ap_id
  end

  test ":not_found is negatively cached" do
    ghost = "https://nowhere.local/objects/#{System.unique_integer([:positive])}"

    assert {:error, :not_found} = Object.get_cached(ap_id: ghost)

    # inserting a row with that id afterwards does not surface until the negative cache expires
    {:ok, _} =
      %Object{}
      |> Ecto.Changeset.change(%{
        data: %{"id" => ghost, "type" => "Note", "content" => "now i exist"},
        local: false,
        public: true,
        is_object: true
      })
      |> repo().insert()

    assert {:error, :not_found} = Object.get_cached(ap_id: ghost)
  end

  test "Object.insert/4 busts a prior negative ap_id cache entry for an activity (no child object)" do
    # regression: a Follow has no child object to carry `set_cache`, so a stale `:not_found` entry
    # for its ap_id used to survive the insert — surfacing as `get_cached(ap_id:) => {:error, :not_found}`
    # (and `get_cached!` => nil) later in the same request (auto-accept / `follow/2`).
    ap_id = "https://nowhere.local/activities/#{System.unique_integer([:positive])}"

    # prime the negative cache
    assert {:error, :not_found} = Object.get_cached(ap_id: ap_id)

    follow_data = %{
      "id" => ap_id,
      "type" => "Follow",
      "actor" => "https://nowhere.local/actors/alice-#{System.unique_integer([:positive])}",
      "object" => "https://nowhere.local/actors/bob-#{System.unique_integer([:positive])}"
    }

    assert {:ok, _activity} = Object.insert(follow_data, false)

    # after insert the stale negative entry must be gone → resolves to the inserted object
    assert {:ok, %Object{} = obj} = Object.get_cached(ap_id: ap_id)
    assert obj.data["id"] == ap_id
  end
end
