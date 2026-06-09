defmodule ActivityPub.Web.Collections do
  @moduledoc """
  Shared AS2 `Collection`/`CollectionPage` envelope builders.

  Used by the outbox/inbox, followers/following, and lib-owned (e.g. keyPackages) renderers so the
  paging envelope isn't reimplemented per source. Callers fetch and shape their own `items` (URIs
  or embedded objects); this module only assembles the surrounding envelope.
  """

  @page_size 10
  def page_size, do: @page_size

  @doc "Top-level (unpaged) collection envelope: id, type, totalItems and a `first` page link/object."
  def top_level(id, type, total, first_page, extra \\ %{}) do
    Map.merge(
      %{"id" => id, "type" => type, "totalItems" => total, "first" => first_page},
      extra
    )
  end

  @doc """
  A single page envelope. `items` is already built. Options: `page_type` (default
  `"CollectionPage"`), `items_key` (default `"orderedItems"`), `next?` (include a `next` link).
  """
  def page(iri, page_num, total, items, opts \\ []) do
    map = %{
      "id" => "#{iri}?page=#{page_num}",
      "type" => Keyword.get(opts, :page_type, "CollectionPage"),
      "partOf" => iri,
      "totalItems" => total,
      Keyword.get(opts, :items_key, "orderedItems") => items
    }

    if Keyword.get(opts, :next?, false),
      do: Map.put(map, "next", "#{iri}?page=#{page_num + 1}"),
      else: map
  end

  def collection_type(true), do: "OrderedCollection"
  def collection_type(_), do: "Collection"
  def page_type(true), do: "OrderedCollectionPage"
  def page_type(_), do: "CollectionPage"
  def items_key(true), do: "orderedItems"
  def items_key(_), do: "items"
end
