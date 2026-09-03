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

  @doc """
  A `last` link for a collection served with its items inline rather than behind a `first`.

  Walking back from `last` through `prev` is ordinary AS2, and it is how history stays reachable for a consumer that wants more than the inline page — without a root `first`, which some implementations prefer over the inline items and then fetch a smaller page.

  Empty when there is nothing beyond what is already inline, since a `last` pointing at the page you are holding says nothing.
  """
  def last_page_link(iri, total, page_size) when is_integer(total) and total > page_size do
    %{"last" => "#{iri}?page=#{ceil(total / page_size)}"}
  end

  def last_page_link(_iri, _total, _page_size), do: %{}

  def collection_type(true), do: "OrderedCollection"
  def collection_type(_), do: "Collection"
  def page_type(true), do: "OrderedCollectionPage"
  def page_type(_), do: "CollectionPage"
  def items_key(true), do: "orderedItems"
  def items_key(_), do: "items"
end
