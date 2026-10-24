# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.Safety.IntegrityProofs.Proof do
  @moduledoc """
  What a Data Integrity proof signs: the bytes that `eddsa-jcs-2022` and `mldsa44-jcs-2024` both sign, and no more.

  The two JCS cryptosuites share one construction (https://www.w3.org/TR/vc-di-eddsa/#hashing-eddsa-jcs-2022): canonicalise the proof configuration, canonicalise the document without its proof, hash each with SHA-256, and join the two hashes, the configuration's first. Only the signature algorithm differs, and that is in `ActivityPub.Safety.IntegrityProofs.Cryptosuites`.

  ## The `@context` of the proof configuration

  The proof configuration is the proof without its `proofValue`. Whether the document's `@context` goes into it is the one place where signers disagree, and each way is in use:

    1. The proof carries its own `@context`, the document's. This is what `eddsa-jcs-2022` says a signer does ("If unsecuredDocument.@context is present, set proof.@context"), and how its verifier reads it: the proof as it is, and the document taken with the proof's `@context`. The FEP-8b32 and vc-di-eddsa vectors are made this way.
    2. The proof has no `@context`, and none is added when hashing. The spec calls step 1 "strongly advised" and notes that some implementers skip it. Mitra does, on every activity it sends (checked against three of its activities).
    3. The proof has no `@context`, but the signer hashed the document's as if it had one. The ML-DSA vectors of the quantum-resistant cryptosuites draft are made this way.

  So a proof that carries a `@context` is read as given (way 1), and one that does not is tried as given (way 2) and then with the document's context put in (way 3). Each is a signature over bytes that include the whole document, so accepting either lets nothing through that the key's owner did not sign.

  This module knows nothing about ActivityPub, actors or keys, so it can move into a package of its own.
  """

  import Untangle

  @doc """
  The canonical form of some JSON data (RFC 8785), or `{:error, :uncanonicalizable}` when it has none.

  Two things have no canonical form: an integer a double cannot hold exactly (past 2^53, where a JavaScript signer would have hashed a rounded number), and a string holding a Unicode noncharacter (I-JSON forbids them). Both are rare in ActivityPub documents. The caller decides what to do: a signer sends the document unsigned, a verifier treats the proof as one it cannot check.
  """
  @spec canonicalize(term()) :: {:ok, binary()} | {:error, :uncanonicalizable}
  def canonicalize(term) do
    case RFC8785.encode(term) do
      {:ok, json} ->
        {:ok, json}

      {:error, error} ->
        debug(Exception.message(error), "no canonical form")
        {:error, :uncanonicalizable}
    end
  end

  @doc "The document as it was before any proof was added: without `proof`, and without a legacy `signature` (FEP-8b32: a linked data signature is added after the proof, so it is left out when checking it)."
  @spec unsecured(map()) :: map()
  def unsecured(%{} = document), do: Map.drop(document, ["proof", "signature"])

  @doc """
  The proof configuration: the proof without its `proofValue`.

  With `context: :document`, the document's `@context` is put into it (way 3 above). By default it is left as the proof has it.
  """
  @spec proof_config(map(), map(), keyword()) :: map()
  def proof_config(%{} = proof, %{} = document, opts \\ []) do
    config = Map.delete(proof, "proofValue")

    case {opts[:context], document["@context"]} do
      {:document, context} when not is_nil(context) -> Map.put(config, "@context", context)
      _ -> config
    end
  end

  @doc """
  The 64 bytes that get signed: the hash of the proof configuration, then the hash of the unsecured document.

  When the configuration has a `@context`, the document is hashed with that `@context` in place of its own, as the verification algorithm of `eddsa-jcs-2022` has it. They are the same unless the proof names fewer contexts than the document.

  Options: `context: :document`, see `proof_config/3`.
  """
  @spec hash_data(map(), map(), keyword()) :: {:ok, binary()} | {:error, :uncanonicalizable}
  def hash_data(%{} = document, %{} = proof, opts \\ []) do
    config = proof_config(proof, document, opts)

    unsecured =
      case config["@context"] do
        nil -> unsecured(document)
        context -> document |> unsecured() |> Map.put("@context", context)
      end

    with {:ok, config} <- canonicalize(config),
         {:ok, unsecured} <- canonicalize(unsecured) do
      {:ok, :crypto.hash(:sha256, config) <> :crypto.hash(:sha256, unsecured)}
    end
  end

  @doc """
  Every hash a proof might have been signed over, in the order to try them.

    * a proof with a `@context`: the one way, as given. The spec requires its `@context` to start the document's, in the same order, and `{:error, :context_mismatch}` says it does not.
    * a proof without: as given, then with the document's `@context` in it. Just the first when the document has none.
  """
  @spec hash_candidates(map(), map()) ::
          {:ok, [binary()]} | {:error, :uncanonicalizable | :context_mismatch}
  def hash_candidates(%{} = document, %{} = proof) do
    cond do
      Map.has_key?(proof, "@context") ->
        if context_starts?(document["@context"], proof["@context"]),
          do: with({:ok, hash} <- hash_data(document, proof), do: {:ok, [hash]}),
          else: {:error, :context_mismatch}

      is_nil(document["@context"]) ->
        with {:ok, hash} <- hash_data(document, proof), do: {:ok, [hash]}

      true ->
        with {:ok, as_given} <- hash_data(document, proof),
             {:ok, injected} <- hash_data(document, proof, context: :document) do
          {:ok, [as_given, injected]}
        end
    end
  end

  # the proof's contexts are the first ones of the document, in order
  defp context_starts?(document_context, proof_context) do
    proof_context = List.wrap(proof_context)
    document_context |> List.wrap() |> Enum.take(length(proof_context)) == proof_context
  end
end
