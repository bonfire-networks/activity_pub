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
    # embed each activity's object from cache (resolved in one batched list_cached), not a SQL join
    outbox = Object.get_outbox_for_actor(actor, page, load_object: :cache)

    total = length(outbox)

    collection(outbox, "#{actor.ap_id}/outbox", page, total)
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  def render("outbox.json", %{actor: actor}) do
    outbox = Object.get_outbox_for_actor(actor, 1, load_object: :cache)

    total = length(outbox)
    url = "#{actor.ap_id}/outbox"

    %{
      "id" => url,
      "type" => "OrderedCollection",
      "first" => collection(outbox, url, 1, total),
      "totalItems" => total
    }
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  # only for testing purposes
  def render("outbox.json", %{outbox: :shared_outbox} = params) do
    ap_base_url = Utils.ap_base_url()
    page = params[:page] || 1
    outbox = Object.get_outbox_for_instance(page, load_object: :cache)

    total = length(outbox)

    %{
      "id" => "#{ap_base_url}/shared_outbox",
      "type" => "OrderedCollection",
      "first" => collection(outbox, "#{ap_base_url}/shared_outbox", page, total),
      "totalItems" => total
    }
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  def render("inbox.json", %{inbox: :shared_inbox} = params) do
    ap_base_url = Utils.ap_base_url()
    page = params[:page] || 1
    outbox = Object.get_inbox_for_instance(page, load_object: :cache)

    total = length(outbox)

    %{
      "id" => "#{ap_base_url}/shared_inbox",
      "type" => "OrderedCollection",
      "first" => collection(outbox, "#{ap_base_url}/shared_inbox", page, total),
      "totalItems" => total
    }
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  def render("inbox.json", %{actor: actor} = params) do
    ap_base_url = Utils.ap_base_url()
    page = params[:page] || 1
    outbox = Object.get_inbox_for_actor(actor, page, load_object: :cache)

    total = length(outbox)

    url = "#{actor.ap_id}/inbox"

    %{
      "id" => url,
      "type" => "OrderedCollection",
      "first" => collection(outbox, url, page, total),
      "totalItems" => total
    }
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  # MLS-over-ActivityPub `mls:messages`: the actor's inbox filtered to MLS activity/object types, so an
  # E2EE client can skip scanning the whole inbox. Owner-only (auth enforced in the controller).
  def render("mls_messages.json", %{actor: actor} = params) do
    page = params[:page] || 1
    messages = Object.get_mls_messages_for_actor(actor, page, load_object: :cache)

    total = length(messages)
    url = "#{actor.ap_id}/mls_messages"

    result =
      if params[:paged] do
        # Spec-compliant: ?page=N dereferences to an OrderedCollectionPage directly.
        collection(messages, url, page, total)
      else
        %{
          "id" => url,
          "type" => "OrderedCollection",
          "first" => collection(messages, url, page, total),
          "totalItems" => total
        }
      end

    Map.merge(result, Utils.make_json_ld_header(:object))
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

  def collection(collection, iri, page, total \\ nil) do
    offset = (page - 1) * Collections.page_size()
    items = Enum.map(collection, fn object -> render("object.json", %{object: object}) end)
    total = total || length(collection)

    Collections.page(iri, page, total, items,
      page_type: "OrderedCollectionPage",
      items_key: "orderedItems",
      next?: offset < total or total == Collections.page_size()
    )
  end
end
