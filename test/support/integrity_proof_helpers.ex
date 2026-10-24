defmodule ActivityPub.Test.IntegrityProofHelpers do
  @moduledoc """
  Builds signed documents for tests, with throwaway keys, using the same hashing as verification (`ActivityPub.Safety.IntegrityProofs.Proof`).

  Not the signer: that is a later phase of FEP-8b32 and will live in `lib/`. This only makes inputs, so that a test can change one thing about a document (its owner, the proof's `domain`, its expiry) and sign it again. The spec vectors and the captures from Mitra are what show the construction itself is right.
  """

  alias ActivityPub.Safety.IntegrityProofs.Proof
  alias ActivityPub.Safety.Multibase

  @doc "A throwaway key: `%{type:, public:, private:, multibase:}`, the multibase being what an actor lists as `publicKeyMultibase`."
  def new_key(:ed25519) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    %{
      type: :ed25519,
      public: public,
      private: private,
      multibase: Multibase.encode(<<0xED, 0x01>> <> public, :base58btc)
    }
  end

  def new_key(:mldsa44) do
    {public, private} = :crypto.generate_key(:mldsa44, [])

    %{
      type: :mldsa44,
      public: public,
      private: private,
      multibase: Multibase.encode(Multibase.encode_varint(0x1210) <> public, :base64url)
    }
  end

  @doc "The Multikey entry an actor lists under `assertionMethod` for a key."
  def multikey(actor_id, key, fragment \\ "ed25519-key") do
    %{
      "id" => actor_id <> "#" <> fragment,
      "type" => "Multikey",
      "controller" => actor_id,
      "publicKeyMultibase" => key.multibase
    }
  end

  @doc """
  Adds a proof to a document.

  Options: `:verification_method` (default: the actor's `#ed25519-key`, the actor being the document's `actor` or `attributedTo`), `:created`, and `:proof`, a map merged over the proof before it is signed (to add `expires`, `domain`, `previousProof`, a different `proofPurpose`, and so on).

  `:context_style` is how the proof's `@context` is handled, the three ways in use (see `ActivityPub.Safety.IntegrityProofs.Proof`): `:spec` (default) puts the document's `@context` in the proof, `:mitra` leaves it out and hashes without it, `:draft` leaves it out but hashes as if it were there.
  """
  def sign(document, key, opts \\ []) do
    suite = if key.type == :mldsa44, do: "mldsa44-jcs-2024", else: "eddsa-jcs-2022"
    style = opts[:context_style] || :spec

    proof =
      %{
        "type" => "DataIntegrityProof",
        "cryptosuite" => suite,
        "verificationMethod" => opts[:verification_method] || default_method(document),
        "proofPurpose" => "assertionMethod",
        "created" => opts[:created] || "2026-10-23T12:00:00Z"
      }
      |> Map.merge(opts[:proof] || %{})
      |> put_spec_context(document, style)

    {:ok, hash} =
      Proof.hash_data(document, proof, if(style == :draft, do: [context: :document], else: []))

    Map.put(document, "proof", Map.put(proof, "proofValue", sign_hash(key, hash)))
  end

  defp put_spec_context(proof, %{"@context" => context}, :spec) when not is_nil(context),
    do: Map.put_new(proof, "@context", context)

  defp put_spec_context(proof, _document, _style), do: proof

  defp sign_hash(%{type: :ed25519} = key, hash) do
    Multibase.encode(:crypto.sign(:eddsa, :none, hash, [key.private, :ed25519]), :base58btc)
  end

  defp sign_hash(%{type: :mldsa44} = key, hash) do
    Multibase.encode(:crypto.sign(:mldsa44, :none, hash, key.private), :base64url)
  end

  # the owner of an activity is its actor, of an object its attributedTo, and of an actor document the actor itself
  defp default_method(document) do
    owner = document["actor"] || document["attributedTo"] || document["id"]
    owner <> "#ed25519-key"
  end

  @doc "A public `Create` of a `Note`, by `actor_id`, with ids on the actor's own origin."
  def create_note(actor_id, content \\ "<p>hello</p>") do
    n = System.unique_integer([:positive])

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/data-integrity/v2"
      ],
      "id" => "#{actor_id}/activities/#{n}",
      "type" => "Create",
      "actor" => actor_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "object" => %{
        "id" => "#{actor_id}/objects/#{n}",
        "type" => "Note",
        "attributedTo" => actor_id,
        "content" => content,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }
    }
  end
end
