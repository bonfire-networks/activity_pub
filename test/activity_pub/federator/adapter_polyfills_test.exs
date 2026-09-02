defmodule ActivityPub.Federator.AdapterPolyfillsTest do
  @moduledoc """
  T2-b (team-docs/plans/ap-followers-collections-tdd.md): the lib's polyfills for the optional
  paging / counting / URI-resolution adapter callbacks.

  Inside Bonfire the real adapter implements all of these, so the polyfills are never exercised by
  the endpoint tests — but other host apps rely on them. This test swaps in a stub adapter that
  only exports the pre-existing 2-arity callbacks and checks the lib fills in the rest.
  """
  use ActivityPub.DataCase, async: false
  use Repatch.ExUnit

  alias ActivityPub.Actor
  alias ActivityPub.Federator.Adapter

  # 15 pointer ids, in a fixed order the stub returns for every call
  @ids Enum.map(1..15, &"01ARZ3NDEKTSV4RRFFQ69G5F#{String.pad_leading(Integer.to_string(&1), 2, "0")}")

  defmodule StubAdapter do
    @ids Enum.map(1..15, &"01ARZ3NDEKTSV4RRFFQ69G5F#{String.pad_leading(Integer.to_string(&1), 2, "0")}")

    def ids, do: @ids

    # only the legacy 2-arity id-list callbacks
    def get_follower_local_ids(_actor, _purpose \\ nil), do: @ids
    def get_following_local_ids(_actor, _purpose \\ nil), do: Enum.reverse(@ids)

    # legacy batch struct resolution — the polyfill for `get_actor_ap_ids_by_ids/1` must map these
    def get_actors_by_ids(ids) do
      Enum.map(ids, fn id ->
        %Actor{id: id, pointer_id: id, ap_id: "https://stub.local/actors/#{id}", username: id, local: true, data: %{}}
      end)
    end

    def base_url, do: "https://stub.local"
  end

  setup do
    Repatch.patch(Adapter, :adapter, fn -> StubAdapter end)
    :ok
  end

  @actor %Actor{id: "stub", pointer_id: "stub", ap_id: "https://stub.local/actors/stub", username: "stub", local: true, data: %{}}

  describe "get_follower_local_ids/3 with page opts (polyfill = slice of the 2-arity result)" do
    test "returns the requested page" do
      assert Adapter.get_follower_local_ids(@actor, nil, page: 1, page_size: 10) ==
               Enum.slice(@ids, 0, 10)

      assert Adapter.get_follower_local_ids(@actor, nil, page: 2, page_size: 10) ==
               Enum.slice(@ids, 10, 10)
    end

    test "a page beyond the end is empty" do
      assert Adapter.get_follower_local_ids(@actor, nil, page: 3, page_size: 10) == []
    end

    test "without page opts it behaves like the 2-arity" do
      assert Adapter.get_follower_local_ids(@actor, nil, []) == @ids
      assert Adapter.get_follower_local_ids(@actor, nil) == @ids
    end
  end

  describe "get_following_local_ids/3 with page opts" do
    test "returns the requested page" do
      assert Adapter.get_following_local_ids(@actor, nil, page: 2, page_size: 10) ==
               @ids |> Enum.reverse() |> Enum.slice(10, 10)
    end
  end

  describe "count_followers/2 and count_following/2 (polyfill = length of the 2-arity result)" do
    test "counts" do
      assert Adapter.count_followers(@actor, nil) == 15
      assert Adapter.count_following(@actor, nil) == 15
    end
  end

  describe "get_actor_ap_ids_by_ids/1 (polyfill = get_actors_by_ids |> ap_id, input order kept)" do
    test "maps ids to ap_ids preserving input order" do
      ids = Enum.slice(@ids, 0, 3) |> Enum.reverse()

      assert Adapter.get_actor_ap_ids_by_ids(ids) ==
               Enum.map(ids, &"https://stub.local/actors/#{&1}")
    end

    test "empty in, empty out (no adapter call needed)" do
      assert Adapter.get_actor_ap_ids_by_ids([]) == []
    end
  end
end
