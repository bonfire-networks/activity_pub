# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.JsonLd.Contexts do
  @moduledoc """
  The JSON-LD contexts bundled in `priv/json_ld_contexts`, read and decoded once at compile time. Everything that needs a well-known context goes through here, so there is one list of them and no file is read at runtime: the loader for LD signatures, and the set of terms that hold objects (`ActivityPub.Federator.NestedObjects.Terms`).

  To bundle another context, put its file in the directory and add its URL below.
  """

  alias ActivityPub.JsonLd.IriTerms

  @bundled %{
    "https://www.w3.org/ns/activitystreams" => "activitystreams.json",
    "https://w3id.org/security/v1" => "security_v1.json",
    "https://w3id.org/identity/v1" => "identity_v1.json",
    # FEP-8b32: what a document with an integrity proof names (`proof`; `Multikey` and `assertionMethod`). Copied from the URLs as they serve them
    "https://w3id.org/security/data-integrity/v2" => "data_integrity_v2.json",
    "https://www.w3.org/ns/cid/v1" => "cid_v1.json"
  }

  @dir Path.expand("../../priv/json_ld_contexts", __DIR__)

  for {_url, file} <- @bundled, do: @external_resource(Path.join(@dir, file))

  @documents Map.new(@bundled, fn {url, file} ->
               {url, @dir |> Path.join(file) |> File.read!() |> Jason.decode!()}
             end)

  @iri_terms Map.new(@documents, fn {url, document} -> {url, IriTerms.of_document(document)} end)

  @doc "Whether this URL is a bundled context."
  def bundled?(url), do: is_map_key(@documents, url)

  @doc "The decoded document of a bundled context, `nil` for any other URL."
  def get(url), do: Map.get(@documents, url)

  @doc "The IRI-typed terms of a bundled context, `nil` for any other URL."
  def iri_terms(url), do: Map.get(@iri_terms, url)
end
