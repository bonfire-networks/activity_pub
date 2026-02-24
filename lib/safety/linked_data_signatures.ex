defmodule ActivityPub.Safety.LinkedDataSignatures do
  @moduledoc """
  Verify incoming Linked Data Signatures (RsaSignature2017) on ActivityPub activities.

  LD signatures attach a cryptographic signature to the JSON-LD activity body itself,
  unlike HTTP signatures which sign the HTTP request. This allows verification of
  activities forwarded via relays or from servers that have shut down.

  This module implements verify-only — we verify incoming LD signatures but do not
  sign outgoing activities with them (HTTP signatures cover that).

  The verification algorithm matches Mastodon's implementation:
  1. Extract the `signature` field and validate it's RsaSignature2017
  2. Build an options hash from the signature metadata + identity context
  3. Build a document hash from the activity without the signature
  4. Concatenate both SHA-256 hex digests
  5. RSA-verify against the signer's public key
  """

  import Untangle

  alias ActivityPub.Safety.LinkedDataSignatures.Canonicalizer
  alias ActivityPub.Safety.Keys

  @identity_context "https://w3id.org/identity/v1"
  @signature_type "RsaSignature2017"

  @doc """
  Verify a Linked Data Signature on an activity.

  Returns `{:ok, creator_ap_id}` if the signature is valid,
  or `{:error, reason}` if verification fails.
  """
  @spec verify(map()) :: {:ok, String.t()} | {:error, term()}
  def verify(%{"signature" => %{"type" => @signature_type} = signature} = json) do
    creator_uri = signature["creator"]
    signature_value = signature["signatureValue"]

    with true <- is_binary(creator_uri) and is_binary(signature_value),
         {:ok, options_hash} <- build_options_hash(signature),
         {:ok, document_hash} <- build_document_hash(json),
         to_be_verified = options_hash <> document_hash,
         {:ok, creator_ap_id} <- resolve_creator(creator_uri),
         {:ok, public_key_pem} <- fetch_public_key(creator_ap_id),
         {:ok, public_key} <- Keys.public_key_decode(public_key_pem),
         {:ok, decoded_sig} <- decode_signature(signature_value),
         true <- :public_key.verify(to_be_verified, :sha256, decoded_sig, public_key) do
      info("Linked Data Signature verified for #{creator_ap_id}")
      {:ok, creator_ap_id}
    else
      false ->
        {:error, :invalid_signature}

      {:error, _} = error ->
        error

      other ->
        error(other, "LD Signature verification failed")
        {:error, :verification_failed}
    end
  end

  def verify(%{"signature" => %{"type" => type}}) do
    debug(type, "Unsupported LD Signature type")
    {:error, :unsupported_signature_type}
  end

  def verify(%{"signature" => _}) do
    {:error, :malformed_signature}
  end

  def verify(_) do
    {:error, :no_signature}
  end

  @doc """
  Check whether an activity JSON contains an LD signature that we can verify.
  """
  @spec has_verifiable_signature?(map()) :: boolean()
  def has_verifiable_signature?(%{"signature" => %{"type" => @signature_type}}), do: true
  def has_verifiable_signature?(_), do: false

  # Build the options hash: take signature metadata, strip type/id/signatureValue,
  # add @context, then canonicalize and SHA-256 hash.
  defp build_options_hash(signature) do
    options =
      signature
      |> Map.drop(["type", "id", "signatureValue"])
      |> Map.put("@context", @identity_context)

    Canonicalizer.hash(options)
  end

  # Build the document hash: remove the signature field, then canonicalize
  # and SHA-256 hash.
  defp build_document_hash(json) do
    json
    |> Map.delete("signature")
    |> Canonicalizer.hash()
  end

  # Resolve a key URI like "https://example.com/users/alice#main-key" to an actor AP ID.
  defp resolve_creator(creator_uri) do
    Keys.key_id_to_actor_id(creator_uri)
  end

  # Fetch the public key for an actor, trying cache first then remote.
  defp fetch_public_key(ap_id) do
    case Keys.get_public_key_for_ap_id(ap_id) do
      {:ok, _} = ok -> ok
      _ -> Keys.fetch_public_key_for_ap_id(ap_id)
    end
  end

  defp decode_signature(signature_value) do
    case Base.decode64(signature_value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64}
    end
  end
end
