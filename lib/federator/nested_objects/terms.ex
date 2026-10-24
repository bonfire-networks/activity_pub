# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.Federator.NestedObjects.Terms do
  @moduledoc """
  Which fields of a document hold objects that `ActivityPub.Federator.NestedObjects` stores as objects of their own.

  A string value carries no marker; the document's `@context` says which terms have IRI values (`"@type": "@id"`, ActivityStreams Core §5.1), so the fields are read from there. No JSON-LD expansion is involved, only the term definitions (`ActivityPub.JsonLd.IriTerms`).

  The set is a union with one subtraction:

    * the IRI-typed terms of the contexts the document names that are bundled (`ActivityPub.JsonLd.Contexts`, read once at compile time)
    * the terms the document's own inline context defines
    * the terms of any other context it names, fetched once and cached, a few at most per document, since the sender chooses the URLs. A context that cannot be fetched adds nothing and is not asked for again for an hour
    * the terms added in config (`include_fields`)
    * minus the fields that are never ingested, also in config (`exclude_fields`): those that name somebody or something else (`actor`, `attributedTo`, `inReplyTo`, `to`...) and the structure of collections and endpoints

  Config, under the `:activity_pub` app, with the same names as the options of `fields/3`, whose lists are added to these and win over them:

      config :activity_pub, :nested_objects,
        default_policy: :authenticate_or_store,
        include_fields: [],
        exclude_fields: [...],
        max_remote_contexts: 5
  """

  import Untangle

  alias ActivityPub.Config
  alias ActivityPub.JsonLd.{Contexts, IriTerms}
  alias ActivityPub.Utils

  # object-valued in the vocabulary, but not ours to ingest: they name who or what a document is about or addressed to, media and tags (handled by their own extensions), and the pages, endpoints and links around a collection
  @exclude_fields [
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

  # what is done with a nested object nobody vouched for: "authenticate" is what needs no request (its own proof, or its owner's signed wrapper); then fetch the origin's copy or not; then store or drop what is still not vouched for (`ActivityPub.Federator.NestedObjects` applies them)
  @policies [
    :authenticate_or_store,
    :authenticate_or_drop,
    :authenticate_or_fetch_or_store,
    :authenticate_or_fetch_or_drop
  ]
  @default_policy :authenticate_or_store

  @doc """
  The fields of a document that hold objects to ingest, as a `MapSet`.

  An object nested in an activity usually has no `@context` of its own, the activity's applies, so that can be passed as the second argument. Both are read when both are there.

  Options, for one call, with the same names as the config keys, added to those and winning over them: `:include_fields`, fields to ingest even if no context defines them or `exclude_fields` names them, and `:exclude_fields`, fields to leave alone.
  """
  @spec fields(map(), term(), keyword()) :: MapSet.t(String.t())
  def fields(document, enclosing_context \\ nil, opts \\ []),
    do: document |> policies(enclosing_context, opts) |> Map.keys() |> MapSet.new()

  @doc """
  The fields of a document that hold objects to ingest, as `fields/3` finds them, each with what is done with a nested object in it that nobody vouched for (see `@policies`).

  `include_fields`, in config and in the options, says it per field: a plain name keeps the policy the field already has, or gets the default (`default_policy` in config, `#{inspect(@default_policy)}` when unset); a `{name, policy}` pair (or a map of them) sets it. A call's entries win over the config's, and `exclude_fields` leaves a field out whatever its policy.
  """
  @spec policies(map(), term(), keyword()) :: %{String.t() => atom()}
  def policies(document, enclosing_context \\ nil, opts \\ [])

  def policies(document, enclosing_context, opts) when is_map(document) do
    document
    |> context_terms(enclosing_context)
    |> Map.new(&{&1, nil})
    |> with_included(include_fields())
    |> Map.drop(List.wrap(exclude_fields()))
    |> with_included(Keyword.get(opts, :include_fields, []))
    |> Map.drop(List.wrap(Keyword.get(opts, :exclude_fields, [])))
    |> Map.new(fn {field, policy} -> {field, policy || default_policy()} end)
  end

  def policies(_document, _enclosing_context, _opts), do: %{}

  # a plain name adds the field and keeps what policy it has; a pair sets it
  defp with_included(policies, included) do
    Enum.reduce(included, policies, fn
      {field, policy}, acc when is_binary(field) ->
        Map.put(acc, field, valid_policy(field, policy))

      field, acc when is_binary(field) ->
        Map.put_new(acc, field, nil)

      other, acc ->
        warn(other, "not a field name, nor a {field, policy} pair") && acc
    end)
  end

  defp valid_policy(_field, policy) when policy in @policies, do: policy

  defp valid_policy(field, policy) do
    warn(policy, "unknown policy for nested objects in #{field}, using the default")
    nil
  end

  # the IRI-typed terms of the contexts the document names, and of the enclosing one
  defp context_terms(document, enclosing_context) do
    {urls, inline} =
      (List.wrap(Map.get(document, "@context")) ++ List.wrap(enclosing_context))
      |> Enum.split_with(&is_binary/1)

    {bundled, unknown} = urls |> Enum.uniq() |> Enum.split_with(&Contexts.bundled?/1)

    from_bundled = Enum.map(bundled, &Contexts.iri_terms/1)

    from_remote =
      unknown
      |> Enum.take(max_remote_contexts())
      |> Enum.map(&remote_terms/1)

    Enum.reduce(
      [IriTerms.of(inline) | from_bundled ++ from_remote],
      MapSet.new(),
      &MapSet.union/2
    )
  end

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

  defp include_fields, do: config(:include_fields, [])

  defp default_policy do
    case config(:default_policy, @default_policy) do
      policy when policy in @policies ->
        policy

      other ->
        warn(
          other,
          "unknown default_policy for nested objects, using #{inspect(@default_policy)}"
        )

        @default_policy
    end
  end

  defp exclude_fields, do: config(:exclude_fields, @exclude_fields)
  defp max_remote_contexts, do: config(:max_remote_contexts, @max_remote_contexts)

  defp config(key, default), do: Config.get([:nested_objects, key], default)
end
