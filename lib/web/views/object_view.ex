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
      "type" => "Collection",
      "first" => collection(outbox, "#{actor.ap_id}/outbox", 1, total),
      "totalItems" => total
    }
    |> Map.merge(Utils.make_json_ld_header(:object))
  end

  # only for testing purposes
  def render("outbox.json", %{outbox: :shared_outbox} = params) do
    instance = ActivityPub.Web.base_url()
    page = params[:page] || 1
    outbox = Object.get_outbox_for_instance()

    total = length(outbox)

    %{
      "id" => "#{instance}/shared_outbox",
      "type" => "Collection",
      "first" => collection(outbox, "#{instance}/shared_outbox", page, total),
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
      |> debug()

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
  end
end
