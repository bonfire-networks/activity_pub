# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.Federator.NestedObjects.Terms do
  @moduledoc """
  Which fields of a document hold objects that `ActivityPub.Federator.NestedObjects` stores as objects of their own.

  A string value carries no marker; the document's `@context` says which terms have IRI values (`"@type": "@id"`, ActivityStreams Core §5.1), so the fields are read from there. No JSON-LD expansion is involved, only the term definitions (`ActivityPub.JsonLd.IriTerms`).

  The set is a union with one subtraction:

    * the IRI-typed terms of the contexts the document names that are bundled (`ActivityPub.JsonLd.Contexts`, read once at compile time)
    * the terms the document's own inline context defines
    * the terms of any other context it names, fetched once and cached, a few at most per document, since the sender chooses the URLs. A context that cannot be fetched adds nothing and is not asked for again for an hour
    * the terms added in config
    * minus the fields that are never ingested, also in config: those that name somebody or something else (`actor`, `attributedTo`, `inReplyTo`, `to`...) and the structure of collections and endpoints

  Config, under the `:activity_pub` app:

      config :activity_pub, :nested_objects,
        extra_terms: [],
        never_ingest: [...],
        max_remote_contexts: 5
  """

  import Untangle

  alias ActivityPub.Config
  alias ActivityPub.JsonLd.{Contexts, IriTerms}
  alias ActivityPub.Utils

  # object-valued in the vocabulary, but not ours to ingest: they name who or what a document is about or addressed to, media and tags (handled by their own extensions), and the pages, endpoints and links around a collection
  @never_ingest [
    "type",
    "formerType",
    "actor",
    "object",
    "attributedTo",
    "audience",
    "context",
    "inReplyTo",
    "replies",
    "icon",
    "image",
    "attachment",
    "tag",
    "url",
    "to",
    "bto",
    "cc",
    "bcc",
    "first",
    "last",
    "next",
    "prev",
    "current",
    "partOf",
    "items",
    "orderedItems",
    "inbox",
    "outbox",
    "followers",
    "following",
    "members",
    "moderators",
    "liked",
    "likes",
    "shares",
    "streams",
    "endpoints",
    "sharedInbox",
    "href",
    "proxyUrl",
    "uploadMedia",
    "oauthAuthorizationEndpoint",
    "oauthTokenEndpoint",
    "provideClientKey",
    "signClientKey",
    # "alsoKnownAs",
    "Public"
  ]

  @max_remote_contexts 5
  @cache :ap_context_cache
  # how long a context we could not fetch is left alone
  @failed_ttl to_timeout(hour: 1)

  @doc """
  The fields of a document that hold objects to ingest, as a `MapSet`.

  An object nested in an activity usually has no `@context` of its own, the activity's applies, so that can be passed as the second argument. Both are read when both are there.

  Options, for one call, which win over config: `:include`, fields to ingest even if no context defines them or the never-ingest list names them, and `:exclude`, fields to leave alone.
  """
  @spec fields(map(), term(), keyword()) :: MapSet.t(String.t())
  def fields(document, enclosing_context \\ nil, opts \\ [])

  def fields(document, enclosing_context, opts) when is_map(document) do
    {urls, inline} =
      (List.wrap(Map.get(document, "@context")) ++ List.wrap(enclosing_context))
      |> Enum.split_with(&is_binary/1)

    {bundled, unknown} = urls |> Enum.uniq() |> Enum.split_with(&Contexts.bundled?/1)

    from_bundled = Enum.map(bundled, &Contexts.iri_terms/1)

    from_remote =
      unknown
      |> Enum.take(max_remote_contexts())
      |> Enum.map(&remote_terms/1)

    [IriTerms.of(inline) | from_bundled ++ from_remote]
    |> Enum.reduce(MapSet.new(extra_terms()), &MapSet.union/2)
    |> MapSet.difference(MapSet.new(never_ingest()))
    |> MapSet.union(MapSet.new(Keyword.get(opts, :include, [])))
    |> MapSet.difference(MapSet.new(Keyword.get(opts, :exclude, [])))
  end

  def fields(_document, _enclosing_context, _opts), do: MapSet.new()

  defp remote_terms(url) do
    case Utils.cachex_fetch(@cache, url, fn -> fetch_terms(url) end) do
      {:ok, %MapSet{} = terms} -> terms
      {:commit, %MapSet{} = terms} -> terms
      {:commit, %MapSet{} = terms, _options} -> terms
      other -> warn(other, "unexpected result reading the terms of #{url}") && MapSet.new()
    end
  end

  # through the same checks as other federation requests, since the URL is chosen by whoever sent the document
  defp fetch_terms(url) do
    case JSON.LD.DocumentLoader.RemoteDocument.load(
           url,
           [],
           ActivityPub.Safety.LinkedDataSignatures.HTTPClient
         ) do
      {:ok, %{document: document}} ->
        {:commit, IriTerms.of_document(document)}

      other ->
        debug(other, "could not fetch the context #{url}")
        {:commit, MapSet.new(), expire: @failed_ttl}
    end
  end

  defp extra_terms, do: config(:extra_terms, [])
  defp never_ingest, do: config(:never_ingest, @never_ingest)
  defp max_remote_contexts, do: config(:max_remote_contexts, @max_remote_contexts)

  defp config(key, default), do: Config.get([:nested_objects, key], default)
end
