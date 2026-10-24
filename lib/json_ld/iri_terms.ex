# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.JsonLd.IriTerms do
  @moduledoc """
  Which terms a JSON-LD `@context` defines as holding IRIs: the ones whose definition is a map with `"@type": "@id"`. A property with such a term holds an object or a reference to one (ActivityStreams Core §5.1), and a plain string value of it is an IRI.

  This reads term definitions and nothing else: no expansion, no compaction, no IRI resolution, no loading. A context is a map, a list of maps and URLs, or a URL; a URL is not looked at here (see `ActivityPub.JsonLd.Contexts` and `ActivityPub.Federator.NestedObjects.Terms`). What it does not handle is `@import`, scoped contexts and `@vocab`, which fediverse documents rarely use; a term they would define is simply not found.
  """

  @doc "The IRI-typed terms the maps of `context` define, as a `MapSet`."
  @spec of(term()) :: MapSet.t(String.t())
  def of(context) do
    context
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&Map.to_list/1)
    |> Enum.filter(fn {term, definition} ->
      is_binary(term) and iri_typed?(definition)
    end)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  # the `@context` of a context document, which is itself a map, a list or a URL
  @doc "Like `of/1`, for a whole context document (the value under its `@context` key)."
  @spec of_document(term()) :: MapSet.t(String.t())
  def of_document(%{"@context" => context}), do: of(context)
  def of_document(_), do: MapSet.new()

  defp iri_typed?(%{"@type" => "@id"}), do: true
  defp iri_typed?(_), do: false
end
