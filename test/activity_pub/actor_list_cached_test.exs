defmodule ActivityPub.ActorListCachedTest do
  @moduledoc """
  `ActivityPub.Actor.list_cached/2` — batched actor resolution (avoids n+1): local actors via the Adapter's `get_actors_by_ids/1`, remote actors via the `ap_object` query, in one pass.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Actor

  test "resolves multiple local actors by pointer id (via the Adapter batch), in input order" do
    a = local_actor()
    b = local_actor()

    # pointer ids (what `get_*_local_ids` return), not the %Actor{}.id
    result = Actor.list_cached([a.user.id, b.user.id])

    assert [a.data["id"], b.data["id"]] == Enum.map(result, & &1.ap_id)
  end

  test "resolves a remote actor by ap_id (via the ap_object query)" do
    remote = insert(:actor)

    assert [actor] = Actor.list_cached([remote.data["id"]])
    assert actor.ap_id == remote.data["id"]
    refute actor.local
  end

  test "resolves local (pointer) + remote (ap_id) actors in one pass, in input order" do
    local = local_actor()
    remote = insert(:actor)

    result = Actor.list_cached([remote.data["id"], local.user.id])

    assert [remote.data["id"], local.data["id"]] == Enum.map(result, & &1.ap_id)
  end

  test "caches resolved actors so a later get_cached hits (no re-resolve)" do
    Process.put(:activity_pub_enable_cache, true)
    on_exit(fn -> ActivityPub.Utils.cache_clear() end)

    remote = insert(:actor)
    assert [_] = Actor.list_cached([remote.data["id"]])

    # remove the underlying row; if list_cached populated the actor cache, get_cached still resolves
    assert {:ok, _} = repo().delete(remote)
    assert {:ok, cached} = Actor.get_cached(ap_id: remote.data["id"])
    assert cached.ap_id == remote.data["id"]
  end

  test "drops unresolved refs (and an empty list is a no-op)" do
    a = local_actor()
    ghost = "01J0000000000000000GHOST00"

    assert [resolved] = Actor.list_cached([a.user.id, ghost])
    assert resolved.ap_id == a.data["id"]

    assert [] == Actor.list_cached([])
  end
end
