# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.Web.ObjectView do
  use ActivityPub.Web, :view
  import Untangle
  use Arrows
  alias ActivityPub.Utils
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Object

  def render("object.json", %{object: object}) do
    object
    # |> debug 
    |> Transformer.prepare_outgoing()
    ~> Transformer.preserve_privacy_of_outgoing()
  end

  def render("outbox.json", %{actor: actor, page: page}) do
    outbox = Object.get_outbox_for_actor(actor, page)

    total = length(outbox)

    collection(outbox, "#{actor.ap_id}/outbox", page, total)
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  def render("outbox.json", %{actor: actor}) do
    outbox = Object.get_outbox_for_actor(actor)

    total = length(outbox)

    %{
      "id" => "#{actor.ap_id}/outbox",
      "type" => "OrderedCollection",
      "first" => collection(outbox, "#{actor.ap_id}/outbox", 1, total),
      "totalItems" => total
    }
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  # only for testing purposes
  def render("outbox.json", %{outbox: :shared_outbox} = params) do
    ap_base_url = Utils.ap_base_url()
    page = params[:page] || 1
    outbox = Object.get_outbox_for_instance(page)

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
    outbox = Object.get_inbox(:shared, page)

    total = length(outbox)

    %{
      "id" => "#{ap_base_url}/shared_inbox",
      "type" => "OrderedCollection",
      "first" => collection(outbox, "#{ap_base_url}/shared_inbox", page, total),
      "totalItems" => total
    }
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  def collection(collection, iri, page, total \\ nil) do
    offset = (page - 1) * 10

    items =
      collection
      |> debug()
      |> Enum.map(fn object ->
        render("object.json", %{object: object})
      end)

    total = total || length(collection)

    map = %{
      "id" => "#{iri}?page=#{page}",
      "type" => "CollectionPage",
      "partOf" => iri,
      "totalItems" => total,
      "orderedItems" => items
    }

    if offset < total do
      Map.put(map, "next", "#{iri}?page=#{page + 1}")
    else
      map
    end
    |> debug()
  end
end
