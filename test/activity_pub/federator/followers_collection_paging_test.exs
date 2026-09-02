defmodule ActivityPub.Web.FollowersCollectionPagingTest do
  @moduledoc """
  TDD for the `followers` / `following` collection endpoints (see
  team-docs/plans/ap-followers-collections-tdd.md).

  Inside Bonfire this suite runs against `Bonfire.Federate.ActivityPub.Adapter` (real users, real
  `Follows` edges, Bonfire's router), so these are end-to-end.

  Covers:
  - T1-a: no `next` link when everything fits on one page; `next` only when a further page exists
  - T1-b: pages are disjoint and stable; a page beyond the last is a valid empty page
  - T2-a: a page request never asks the adapter to resolve more than one page of actors
  - T5:   serving pages never writes follower actors into `:ap_actor_cache`
  """
  use ActivityPub.Web.ConnCase, async: false
  use Repatch.ExUnit
  import ActivityPub.Factory
  import Plug.Conn
  import Phoenix.ConnTest

  alias ActivityPub.Utils
  alias ActivityPub.Test.HttpRequestMock

  @page_size ActivityPub.Web.Collections.page_size()

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  defp nickname(%{username: nickname}), do: nickname
  defp nickname(%{user: %{character: %{username: nickname}}}), do: nickname

  defp followers_url(actor, page \\ nil) do
    base = "#{Utils.ap_base_url()}/actors/#{nickname(actor)}/followers"
    if page, do: "#{base}?page=#{page}", else: base
  end

  defp following_url(actor, page \\ nil) do
    base = "#{Utils.ap_base_url()}/actors/#{nickname(actor)}/following"
    if page, do: "#{base}?page=#{page}", else: base
  end

  defp get_json(conn, url), do: conn |> get(url) |> json_response(200)

  # `n` local actors following `user`
  defp add_followers(user, n) do
    for _ <- 1..n do
      follower = local_actor()
      follow(follower, user)
      follower
    end
  end

  # `user` follows `n` local actors
  defp add_following(user, n) do
    for _ <- 1..n do
      followed = local_actor()
      follow(user, followed)
      followed
    end
  end

  describe "T1-a: `next` link is only present when a further page exists" do
    test "top-level collection has no `next` when all followers fit on page 1", %{conn: conn} do
      user = local_actor()
      add_followers(user, 3)

      result = get_json(conn, followers_url(user))

      assert result["totalItems"] == 3
      assert length(result["first"]["orderedItems"]) == 3
      refute Map.has_key?(result["first"], "next")
    end

    test "page 1 has `next`, last page has none (followers)", %{conn: conn} do
      user = local_actor()
      add_followers(user, @page_size + 5)

      page1 = get_json(conn, followers_url(user, 1))
      assert page1["next"] == "#{ap_id(user)}/followers?page=2"

      page2 = get_json(conn, followers_url(user, 2))
      assert length(page2["orderedItems"]) == 5
      refute Map.has_key?(page2, "next")
    end

    test "exactly one full page has no `next` (followers)", %{conn: conn} do
      user = local_actor()
      add_followers(user, @page_size)

      result = get_json(conn, followers_url(user))
      assert length(result["first"]["orderedItems"]) == @page_size
      refute Map.has_key?(result["first"], "next")
    end

    test "page 1 has `next`, last page has none (following)", %{conn: conn} do
      user = local_actor()
      add_following(user, @page_size + 5)

      page1 = get_json(conn, following_url(user, 1))
      assert page1["next"] == "#{ap_id(user)}/following?page=2"

      page2 = get_json(conn, following_url(user, 2))
      assert length(page2["orderedItems"]) == 5
      refute Map.has_key?(page2, "next")
    end
  end

  describe "hostile page params are handled, not 500s" do
    # any remote can append these; a negative page reaches SQL as a negative OFFSET, which
    # Postgres rejects, and a non-numeric page used to raise in `Integer.parse |> elem(0)`
    for param <- ["0", "-5", "abc", ""] do
      test "?page=#{inspect(param)} serves a page instead of erroring", %{conn: conn} do
        user = local_actor()
        add_followers(user, 3)

        result = get_json(conn, followers_url(user) <> "?page=#{unquote(param)}")

        assert result["totalItems"] == 3
        assert is_list(result["orderedItems"] || result["first"]["orderedItems"])
      end
    end
  end

  describe "T1-b: pages are disjoint, stable, and a page past the end is empty" do
    test "followers: page 1 and page 2 are disjoint and together cover everyone", %{conn: conn} do
      user = local_actor()
      followers = add_followers(user, @page_size + 5)
      expected = followers |> Enum.map(&ap_id/1) |> MapSet.new()

      page1 = get_json(conn, followers_url(user, 1))["orderedItems"]
      page2 = get_json(conn, followers_url(user, 2))["orderedItems"]

      assert length(page1) == @page_size
      assert length(page2) == 5
      assert MapSet.disjoint?(MapSet.new(page1), MapSet.new(page2))
      assert MapSet.union(MapSet.new(page1), MapSet.new(page2)) == expected
    end

    test "followers: the same page returns the same order on repeated requests", %{conn: conn} do
      user = local_actor()
      add_followers(user, @page_size + 5)

      first = get_json(conn, followers_url(user, 1))["orderedItems"]
      again = get_json(conn, followers_url(user, 1))["orderedItems"]

      assert first == again
    end

    test "followers: a page beyond the last is an empty page with the right total", %{conn: conn} do
      user = local_actor()
      add_followers(user, @page_size + 5)

      page3 = get_json(conn, followers_url(user, 3))

      assert page3["orderedItems"] == []
      assert page3["totalItems"] == @page_size + 5
      refute Map.has_key?(page3, "next")
    end

    test "following: page 1 and page 2 are disjoint and together cover everyone", %{conn: conn} do
      user = local_actor()
      followed = add_following(user, @page_size + 5)
      expected = followed |> Enum.map(&ap_id/1) |> MapSet.new()

      page1 = get_json(conn, following_url(user, 1))["orderedItems"]
      page2 = get_json(conn, following_url(user, 2))["orderedItems"]

      assert MapSet.disjoint?(MapSet.new(page1), MapSet.new(page2))
      assert MapSet.union(MapSet.new(page1), MapSet.new(page2)) == expected
    end
  end

  describe "T2-a: a page request never resolves more than one page of actors" do
    # Spy on the lib-side adapter facade (adapter-agnostic): whichever resolution function the
    # page path uses, it must be asked for at most `page_size` ids, once per request.
    test "followers: adapter resolution is called once with <= page_size ids", %{conn: conn} do
      user = local_actor()
      add_followers(user, @page_size + 5)

      Repatch.spy(ActivityPub.Federator.Adapter)

      _ = get_json(conn, followers_url(user, 1))

      calls =
        Repatch.history(module: ActivityPub.Federator.Adapter)
        |> Enum.filter(fn {_m, f, _args, _} ->
          f in [:get_actors_by_ids, :get_actor_ap_ids_by_ids]
        end)

      assert length(calls) == 1,
             "expected exactly one batched resolution call, got: #{inspect(calls)}"

      [{_m, _f, [ids], _}] = calls
      assert is_list(ids)

      assert length(ids) <= @page_size,
             "expected at most #{@page_size} ids to be resolved, got #{length(ids)}"
    end

    test "followers: the top-level (unpaged) collection also resolves only one page", %{conn: conn} do
      user = local_actor()
      add_followers(user, @page_size + 5)

      Repatch.spy(ActivityPub.Federator.Adapter)

      _ = get_json(conn, followers_url(user))

      ids_resolved =
        Repatch.history(module: ActivityPub.Federator.Adapter)
        |> Enum.filter(fn {_m, f, _args, _} ->
          f in [:get_actors_by_ids, :get_actor_ap_ids_by_ids]
        end)
        |> Enum.flat_map(fn {_m, _f, [ids], _} -> ids end)

      assert length(ids_resolved) <= @page_size
    end
  end

  describe "T5: serving collection pages never writes follower actors into the actor cache" do
    setup do
      Process.put(:activity_pub_enable_cache, true)
      on_exit(fn -> Utils.cache_clear() end)
      :ok
    end

    test "cache size does not grow with the follower list", %{conn: conn} do
      user = local_actor()
      add_followers(user, @page_size + 5)

      # fixture creation itself caches every actor (`local_actor/1` calls `Actor.get_cached`), so
      # start from an empty cache, then warm ONLY the served actor's own entries (what the
      # controller's get_cached(username:) does). The measurement below then sees exactly what the
      # page path adds. (Warming with a page request would hide the problem: today that request
      # already writes every follower into the cache.)
      Utils.cache_clear()
      {:ok, _} = ActivityPub.Actor.get_cached(username: nickname(user))
      {:ok, before} = Cachex.size(:ap_actor_cache)

      _ = get_json(conn, followers_url(user, 1))
      _ = get_json(conn, followers_url(user, 2))
      {:ok, after_pages} = Cachex.size(:ap_actor_cache)

      assert after_pages == before,
             "page requests wrote #{after_pages - before} entries into :ap_actor_cache (expected 0)"
    end
  end
end
