defmodule ActivityPub.Test.LinkedDataSignatureHelpers do
  @moduledoc """
  LD signatures (`RsaSignature2017`, as Mastodon makes them) for tests, generated with a throwaway RSA key rather than taken from a capture, as rewriting a capture's hosts breaks its signature.
  """
  import ActivityPub.Factory

  alias ActivityPub.Safety.Keys
  alias ActivityPub.Safety.LinkedDataSignatures.Canonicalizer

  @doc "A remote actor we hold, `ap_id`, with an RSA key as Mastodon's (`publicKey`): `%{ap_id: ap_id, private_key: key}` to sign with."
  def rsa_signer!(ap_id) do
    {:ok, pem} = Keys.generate_rsa_pem()
    {:ok, private_key, public_key} = Keys.keypair_from_pem(pem)

    public_key_pem =
      :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)
      |> then(&:public_key.pem_encode([&1]))

    actor(
      ap_id: ap_id,
      data: %{
        "publicKey" => %{
          "id" => ap_id <> "#main-key",
          "owner" => ap_id,
          "publicKeyPem" => public_key_pem
        }
      }
    )

    %{ap_id: ap_id, private_key: private_key}
  end

  @doc "`document` with an LD signature by `signer` (from `rsa_signer!/1`), as Mastodon signs: the hash of the signature options, then of the document, signed with RSA-SHA256."
  def ld_sign(document, %{ap_id: ap_id, private_key: private_key}) do
    options = %{
      "creator" => ap_id <> "#main-key",
      "created" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:ok, options_hash} =
      Canonicalizer.hash(Map.put(options, "@context", "https://w3id.org/identity/v1"))

    {:ok, document_hash} = Canonicalizer.hash(document)

    value =
      (options_hash <> document_hash)
      |> :public_key.sign(:sha256, private_key)
      |> Base.encode64()

    Map.put(
      document,
      "signature",
      Map.merge(options, %{"type" => "RsaSignature2017", "signatureValue" => value})
    )
  end
end
