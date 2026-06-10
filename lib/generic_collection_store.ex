defmodule ActivityPub.GenericCollectionStore do
  @moduledoc """
  The fallback backing store for ActivityPub collections that the lib itself owns — i.e. AP-native
  collections with no host-domain home, such as an actor's `keyPackages` (per the MLS-over-AP spec).

  Used when no adapter claims a collection via `ActivityPub.Federator.Adapter.collection_items/2`.
  Collections projected from host data (outbox/followers/…) do *not* use this; they're served by
  the adapter callback.

  Design: the collection's **identity/metadata** is a normal cached `ap_object` (rarely changes),
  while **membership** lives in `ap_collection_member` and is read fresh/uncached so single-use
  consumption (e.g. a consumed key package) is reflected immediately. Members are loaded for
  embedded rendering via `ActivityPub.Object.get_cached/1` (objects cached once, by id).
  """
  use Arrows
  import Ecto.Query
  import Untangle
  import ActivityPub.Utils, only: [repo: 0]

  alias ActivityPub.Object
  alias ActivityPub.Object.CollectionMember

  @doc """
  Get (or lazily create) the Collection `ap_object` identified by `(type, uuid)`, owned by
  `owner_ap_id` (its `attributedTo`). Idempotent.

  Options: `ordered: true` for an `OrderedCollection`, `order_type:` for an explicit FEP-1985
  `orderType`, `local:` (default `true`).
  """
  def get_or_create_collection(type, uuid, owner_ap_id, opts \\ []) do
    id = ActivityPub.Utils.collection_ap_id(type, uuid)

    case Object.get_cached(ap_id: id) do
      {:ok, %Object{} = collection} -> {:ok, collection}
      _ -> create_collection(id, owner_ap_id, type, opts)
    end
  end

  defp create_collection(id, owner_ap_id, type, opts) do
    # ordered-ness is a property of the collection type (e.g. keyPackages, featured), overridable
    ordered? =
      Keyword.get(opts, :ordered, ActivityPub.Config.type_in?(type, :ordered_collection_types))

    data =
      %{
        "id" => id,
        "type" => if(ordered?, do: "OrderedCollection", else: "Collection"),
        "attributedTo" => owner_ap_id,
        "totalItems" => 0
      }
      # TODO: FEP-1985 — orderType drives ORDER BY direction when serving
      |> maybe_put("orderType", Keyword.get(opts, :order_type))

    %Object{}
    |> Ecto.Changeset.change(%{
      data: data,
      local: Keyword.get(opts, :local, true),
      public: true,
      is_object: true
    })
    |> Ecto.Changeset.unique_constraint(:data, name: "ap_object__data____id_index")
    |> repo().insert()
    |> case do
      {:ok, %Object{} = collection} ->
        {:ok, collection}

      {:error, _changeset} ->
        # lost a create race (or already exists): fetch the existing one
        Object.get_uncached(ap_id: id)
    end
  end

  @doc """
  Add `object` (an `%Object{}`, an ap_id URI, or a map with an `"id"`) to `collection`. Idempotent.

  Records the local FK (`object_id`) when the member is a materialised `ap_object`, and always the
  URI (`object_ap_id`). Membership itself is uncached, so no cache to bust.
  """
  def add_member(%Object{} = collection, object, _opts \\ []) do
    {object_id, object_ap_id} = member_keys(object)

    CollectionMember.changeset(%{
      collection_id: collection.id,
      object_id: object_id,
      object_ap_id: object_ap_id
    })
    |> repo().insert(
      on_conflict: :nothing,
      conflict_target: [:collection_id, :object_ap_id]
    )
  end

  @doc "Remove the member with the given ap_id (URI) from `collection`. Idempotent."
  def remove_member(%Object{} = collection, object) do
    {_object_id, object_ap_id} = member_keys(object)

    {count, _} =
      from(m in CollectionMember,
        where: m.collection_id == ^collection.id and m.object_ap_id == ^object_ap_id
      )
      |> repo().delete_all()

    {:ok, count}
  end

  @doc "Fresh, ordered list of member ap_ids (URIs) — the URI-only fast path, no object loads. Supports `limit:`/`offset:`."
  def member_ap_ids(%Object{} = collection, opts \\ []) do
    base_query(collection, opts)
    |> select([m], m.object_ap_id)
    |> repo().all()
  end

  @doc "Fresh, ordered list of member objects (embedded rendering): member ap_ids then a single batched `Object.list_cached/2` (no n+1)."
  def member_objects(%Object{} = collection, opts \\ []) do
    member_ap_ids(collection, opts)
    |> Object.list_cached()
  end

  @doc "Count of members (for `totalItems`)."
  def member_count(%Object{} = collection) do
    from(m in CollectionMember, where: m.collection_id == ^collection.id)
    |> repo().aggregate(:count)
  end

  @doc """
  Remove an object from *every* lib-owned collection it belongs to, by ap_id.

  Called on `Delete`: since `Object.delete/1` tombstones (keeps the row) rather than hard-deleting,
  the FK `ON DELETE CASCADE` doesn't fire, so we prune memberships explicitly.
  """
  def remove_object_everywhere(object_ap_id) when is_binary(object_ap_id) do
    {count, _} =
      from(m in CollectionMember, where: m.object_ap_id == ^object_ap_id)
      |> repo().delete_all()

    {:ok, count}
  end

  def remove_object_everywhere(_), do: {:ok, 0}

  defp base_query(collection, opts) do
    dir = order_dir(collection, opts)

    query =
      from(m in CollectionMember,
        where: m.collection_id == ^collection.id,
        # object_ap_id is the deterministic tiebreaker (part of the composite PK; no surrogate id)
        order_by: [{^dir, m.inserted_at}, {^dir, m.object_ap_id}]
      )

    # TODO: FEP-6606 — cursor (after/before) keyset paging; for now offset/limit
    query
    |> maybe_limit(opts[:limit])
    |> maybe_offset(opts[:offset])
  end

  # AP default is reverse-chronological; FEP-1985 ForwardChronological flips to ascending.
  defp order_dir(collection, opts) do
    cond do
      opts[:order] in [:asc, :desc] ->
        opts[:order]

      collection.data["orderType"] in [
        "ForwardChronological",
        "https://w3id.org/fep/1985/ForwardChronological"
      ] ->
        :asc

      true ->
        :desc
    end
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit) when is_integer(limit), do: limit(query, ^limit)
  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, offset) when is_integer(offset), do: offset(query, ^offset)

  # Resolve a member into `{local_object_id_or_nil, ap_id}`.
  defp member_keys(%Object{id: id, data: %{"id" => ap_id}}) when is_binary(ap_id),
    do: {id, ap_id}

  defp member_keys(%{"id" => ap_id}) when is_binary(ap_id), do: member_keys(ap_id)

  defp member_keys(ap_id) when is_binary(ap_id) do
    # prefer to resolve to a local row so the FK is set (and embedded rendering/cascade work)
    case Object.get_cached(ap_id: ap_id) do
      {:ok, %Object{id: id}} -> {id, ap_id}
      # TODO: FEP-400e — unresolved-remote member (appendable walls/forums): keep URI only for now
      _ -> {nil, ap_id}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
