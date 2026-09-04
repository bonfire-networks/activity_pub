# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.Web.ObjectView do
  use ActivityPub.Web, :view
  import Untangle
  use Arrows
  alias ActivityPub.Utils
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Object
  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Web.Collections

  def render("object.json", %{object: object} = assigns) do
    object
    # |> debug
    |> Transformer.prepare_outgoing(assigns[:opts] || [])
    ~> Transformer.preserve_privacy_of_outgoing(nil, :public)
  end

  def render("outbox.json", %{actor: actor, page: page}) when is_integer(page) do
    outbox_collection(actor, page: page)
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  @group_outbox_limit 50

  @doc false
  def group_outbox_limit, do: @group_outbox_limit

  # A GROUP's outbox is served as ONE capped collection with its items inline, newest first.
  #
  # Lemmy backfills a community by reading `orderedItems` from the top-level document and never follows pages; it also requires every item to be an `Announce`. Given anything else it backfills NOTHING rather than degrading, which is why our captures of real communities each hold exactly 50 items in a single unpaged collection.
  #
  # ⚠️ No root-level `first`, deliberately. PieFed copes with either shape but PREFERS `first` when it is present, following it for 10 items instead of reading the 50 already inline. History stays reachable through `last` and the `prev` chain, which is ordinary AS2, so nothing is lost.
  #
  # This is a response to how two implementations behave rather than to anything they promise, so the reasoning lives here: without it, `first` looks like an omission and gets added back.
  def render("outbox.json", %{actor: %{data: %{"type" => "Group"}} = actor}) do
    outbox_collection(actor, inline: true, page_size: @group_outbox_limit)
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  def render("outbox.json", %{actor: actor}) do
    outbox_collection(actor, [])
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  # embed each activity's object from cache (resolved in one batched list_cached), not a SQL join
  defp outbox_collection(actor, opts) do
    Collections.collection(
      "#{actor.ap_id}/outbox",
      [
        fetch: fn page, limit ->
          Object.get_outbox_for_actor(actor, page, load_object: :cache, limit: limit)
          |> render_objects()
        end,
        count: fn -> Object.count_outbox_for_actor(actor) end
      ] ++ opts
    )
  end

  # only for testing purposes
  def render("outbox.json", %{outbox: :shared_outbox} = params) do
    ap_base_url = Utils.ap_base_url()

    Collections.collection("#{ap_base_url}/shared_outbox",
      page: params[:page],
      fetch: fn page, limit ->
        Object.get_outbox_for_instance(page, load_object: :cache, limit: limit)
        |> render_objects()
      end,
      count: &Object.count_outbox_for_instance/0
    )
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  def render("inbox.json", %{inbox: :shared_inbox} = params) do
    ap_base_url = Utils.ap_base_url()

    Collections.collection("#{ap_base_url}/shared_inbox",
      page: params[:page],
      fetch: fn page, limit ->
        Object.get_inbox_for_instance(page, load_object: :cache, limit: limit) |> render_objects()
      end,
      count: &Object.count_inbox_for_instance/0
    )
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  def render("inbox.json", %{actor: actor} = params) do
    Collections.collection("#{actor.ap_id}/inbox",
      page: params[:page],
      fetch: fn page, limit ->
        Object.get_inbox_for_actor(actor, page, load_object: :cache, limit: limit)
        |> render_objects()
      end,
      count: fn -> Object.count_inbox_for_actor(actor) end
    )
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  defp render_objects(objects),
    do: Enum.map(objects, fn object -> render("object.json", %{object: object}) end)

  # MLS-over-ActivityPub `mls:messages`: the actor's inbox filtered to MLS activity/object types, so an
  # E2EE client can skip scanning the whole inbox. Owner-only (auth enforced in the controller).
  def render("mls_messages.json", %{actor: actor} = params) do
    Collections.collection("#{actor.ap_id}/mls_messages",
      # spec-compliant: ?page=N dereferences to an OrderedCollectionPage directly
      page: if(params[:paged], do: params[:page] || 1),
      fetch: fn page, limit ->
        Object.get_mls_messages_for_actor(actor, page, load_object: :cache, limit: limit)
        |> render_objects()
      end,
      count: fn -> Object.count_mls_messages_for_actor(actor) end
    )
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  # Serve a lib-owned generic collection (backed by `GenericCollectionStore`). Membership is read
  # fresh; the collection metadata object is cached. Items render as URIs by default, or embedded
  # objects with `embed: true`.
  # TODO: FEP-6606 — cursor (after/before) paging + filters; FEP-1985 — emit/honor orderType
  def render("collection.json", %{collection: collection} = assigns) do
    ordered? = (collection.data["type"] || "Collection") == "OrderedCollection"
    id = collection.data["id"]
    # adapter-owned collections (e.g. Pins/featured) supply their own count; else store fallback
    total = Adapter.collection_total(collection)
    page = assigns[:page]
    embed? = assigns[:embed] == true

    result =
      if is_integer(page) do
        custom_collection_page(collection, id, page, total, ordered?, embed?)
      else
        first = custom_collection_page(collection, id, 1, total, ordered?, embed?)
        extra = maybe_order_type(collection)
        Collections.top_level(id, Collections.collection_type(ordered?), total, first, extra)
      end

    Map.merge(result, Utils.make_json_ld_header(:object))
  end

  defp custom_collection_page(collection, iri, page, total, ordered?, embed?) do
    per = Collections.page_size()
    offset = (page - 1) * per

    # the read seam: an adapter may own the membership (else GenericCollectionStore fallback). We ask
    # the source for the shape we need — embedded objects, or bare ap_id URIs — so it can produce
    # them efficiently (e.g. canonical URLs without building full AP objects).
    items =
      if embed? do
        Adapter.collection_items(collection, limit: per, offset: offset, return: :ap_objects)
        |> Enum.map(&render("object.json", %{object: &1}))
      else
        Adapter.collection_items(collection, limit: per, offset: offset, return: :ap_ids)
      end

    Collections.page(iri, page, total, items,
      page_type: Collections.page_type(ordered?),
      items_key: Collections.items_key(ordered?),
      next?: offset + per < total
    )
  end

  defp maybe_order_type(collection) do
    case collection.data["orderType"] do
      nil -> %{}
      order_type -> %{"orderType" => order_type}
    end
  end
end
