defmodule ActivityPub.Web.Collections do
  @moduledoc """
  Shared AS2 `Collection`/`CollectionPage` envelope builders.

  Used by the outbox/inbox, followers/following, and lib-owned (e.g. keyPackages) renderers so the
  paging envelope isn't reimplemented per source. Callers fetch and shape their own `items` (URIs
  or embedded objects); this module only assembles the surrounding envelope.
  """

  @page_size 10
  def page_size, do: @page_size

  @doc """
  The one envelope builder: tell it how to fetch a page and how to count the whole, and it returns either the top-level collection or a single page.

  This exists because every renderer used to do its own arithmetic, and they disagreed. `totalItems` was `length(page)` in five of them, reporting 10 however much was there, and `next` was emitted whenever a page came back full, which links to an empty page whenever the total is an exact multiple of the page size. Both are computed here once, from a real count.

  Options:

  - `:fetch` — `fn page, page_size -> items`, already rendered by the caller
  - `:count` — `fn -> integer`, the whole collection, not this page
  - `:page` — a page number, or nil for the top level
  - `:page_size` — defaults to `page_size/0`
  - `:ordered?` — picks `OrderedCollection` and `orderedItems`, defaults to true
  - `:items_key` — override just the items key. The followers collection is a plain `Collection` that has always carried `orderedItems`, and changing that would be a wire change unrelated to this refactor
  - `:extra` — merged into the top-level document
  - `:inline` — serve the items IN the top-level document, with no `first` and a `last` for whatever does not fit. This is the shape a Group's outbox needs
  """
  def collection(iri, opts) do
    fetch = Keyword.fetch!(opts, :fetch)
    page_size = Keyword.get(opts, :page_size, @page_size)
    ordered? = Keyword.get(opts, :ordered?, true)
    items_key = Keyword.get(opts, :items_key, items_key(ordered?))
    total = Keyword.fetch!(opts, :count).()

    case Keyword.get(opts, :page) do
      page when is_integer(page) ->
        build_page(iri, page, total, fetch, page_size, ordered?, items_key)

      _ ->
        if Keyword.get(opts, :inline, false) do
          %{
            "id" => iri,
            "type" => collection_type(ordered?),
            "totalItems" => total,
            items_key => fetch.(1, page_size)
          }
          |> Map.merge(last_page_link(iri, total, page_size))
          |> Map.merge(Keyword.get(opts, :extra, %{}))
        else
          top_level(
            iri,
            collection_type(ordered?),
            total,
            build_page(iri, 1, total, fetch, page_size, ordered?, items_key),
            Keyword.get(opts, :extra, %{})
          )
        end
    end
  end

  defp build_page(iri, page, total, fetch, page_size, ordered?, items_key) do
    items = fetch.(page, page_size)

    page(iri, page, total, items,
      page_type: page_type(ordered?),
      items_key: items_key,
      # exact, so a page that exactly fills does not link to an empty one
      next?: (page - 1) * page_size + length(items) < total
    )
  end

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
