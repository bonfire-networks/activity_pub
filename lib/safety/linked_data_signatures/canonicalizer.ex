defmodule ActivityPub.Safety.LinkedDataSignatures.Canonicalizer do
  @moduledoc """
  JSON-LD canonicalization (URDNA2015/RDFC-1.0) for Linked Data Signature verification.

  Expands a JSON-LD map, converts to RDF, canonicalizes the dataset, serializes
  to N-Quads, and returns a SHA-256 hex digest. This matches Mastodon's approach
  for RsaSignature2017.
  """

  alias ActivityPub.Safety.LinkedDataSignatures.DocumentLoader

  @doc """
  Canonicalize a JSON-LD map and return its SHA-256 hex digest.

  Returns `{:ok, hex_string}` where `hex_string` is a 64-char lowercase hex
  SHA-256 digest of the URDNA2015-canonicalized N-Quads representation.
  """
  @spec hash(map()) :: {:ok, String.t()} | {:error, term()}
  def hash(json_map) do
    case canonicalize(json_map) do
      {:ok, nquads} ->
        digest =
          :crypto.hash(:sha256, nquads)
          |> Base.encode16(case: :lower)

        {:ok, digest}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Canonicalize a JSON-LD map to an N-Quads string using RDFC-1.0 (URDNA2015).
  """
  @spec canonicalize(map()) :: {:ok, String.t()} | {:error, term()}
  def canonicalize(json_map) do
    options = JSON.LD.Options.new(document_loader: DocumentLoader)

    dataset =
      json_map
      |> JSON.LD.expand(options)
      |> JSON.LD.Decoder.to_rdf(options)

    {canonical_dataset, _state} = RDF.Canonicalization.canonicalize(dataset)
    nquads = RDF.NQuads.Encoder.encode!(canonical_dataset)

    {:ok, nquads}
  rescue
    e -> {:error, e}
  end
end
