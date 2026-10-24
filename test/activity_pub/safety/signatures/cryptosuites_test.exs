defmodule ActivityPub.Safety.IntegrityProofs.CryptosuitesTest do
  use ExUnit.Case, async: true

  alias ActivityPub.Safety.IntegrityProofs.{Cryptosuites, Proof}
  alias ActivityPub.Safety.Multibase
  alias ActivityPub.Test.IntegrityProofFixtures, as: Fixtures

  # OTP only has ML-DSA when the OpenSSL it was built against does; without it these tests are not defined, and the "unsupported" ones below cover what happens instead
  @mldsa44? :mldsa44 in :crypto.supports(:public_keys)

  # the hash, signature and key of a vector, the way a verifier gets them from a proof and an actor
  defp ed25519_vector(
         %{"document" => document, "publicKeyMultibase" => key} = vector,
         proof,
         proof_value
       ) do
    {:ok, hash} = Proof.hash_data(document, proof)
    {:ok, signature} = Multibase.decode(proof_value)
    {:ok, key} = Multibase.decode_multikey(key)

    assert match?({:ed25519, _}, key)
    {hash, signature, key, vector}
  end

  setup_all do
    w3c = Fixtures.vector(:vc_di_eddsa_jcs_2022)
    fep = Fixtures.vector(:fep_8b32)

    %{
      w3c_vector: ed25519_vector(w3c, w3c["proofOptions"], w3c["expected"]["proofValue"]),
      fep_vector:
        ed25519_vector(fep, fep["signedDocument"]["proof"], fep["expected"]["proofValue"])
    }
  end

  describe "eddsa-jcs-2022" do
    test "verifies the W3C vector", %{w3c_vector: {hash, signature, key, _}} do
      assert Cryptosuites.verify("eddsa-jcs-2022", hash, signature, key) == :ok
    end

    test "verifies the FEP-8b32 vector", %{fep_vector: {hash, signature, key, _}} do
      assert Cryptosuites.verify("eddsa-jcs-2022", hash, signature, key) == :ok
    end

    test "refuses a hash that differs by one bit", %{w3c_vector: {hash, signature, key, _}} do
      <<first, rest::binary>> = hash
      flipped = <<Bitwise.bxor(first, 1), rest::binary>>

      assert Cryptosuites.verify("eddsa-jcs-2022", flipped, signature, key) ==
               {:error, :bad_signature}
    end

    test "refuses another key", %{w3c_vector: {hash, signature, _key, _}} do
      {other, _} = :crypto.generate_key(:eddsa, :ed25519)

      assert Cryptosuites.verify("eddsa-jcs-2022", hash, signature, {:ed25519, other}) ==
               {:error, :bad_signature}
    end

    test "refuses a signature of the wrong size, without trying it", %{
      w3c_vector: {hash, signature, key, _}
    } do
      for bad <- [binary_part(signature, 0, 63), signature <> <<0>>, <<>>] do
        assert Cryptosuites.verify("eddsa-jcs-2022", hash, bad, key) ==
                 {:error, :bad_signature_size}
      end
    end

    test "refuses a hash that is not the 64 bytes this construction signs", %{
      w3c_vector: {hash, signature, key, _}
    } do
      assert Cryptosuites.verify("eddsa-jcs-2022", binary_part(hash, 0, 32), signature, key) ==
               {:error, :bad_hash}
    end
  end

  if @mldsa44? do
    describe "mldsa44-jcs-2024" do
      setup do
        mldsa = Fixtures.vector(:vc_di_mldsa44_jcs_2024)

        # the draft's proof has no @context but was hashed as if it had the document's
        {:ok, hash} =
          Proof.hash_data(mldsa["document"], mldsa["proofOptions"], context: :document)

        {:ok, signature} = Multibase.decode(mldsa["expected"]["proofValue"])
        {:ok, key} = Multibase.decode_multikey(mldsa["publicKeyMultibase"])

        %{hash: hash, signature: signature, key: key}
      end

      test "verifies the spec's own signed credential", %{
        hash: hash,
        signature: signature,
        key: key
      } do
        assert byte_size(signature) == 2420
        assert Cryptosuites.verify("mldsa44-jcs-2024", hash, signature, key) == :ok
      end

      test "refuses a hash that differs by one bit", %{hash: hash, signature: signature, key: key} do
        <<first, rest::binary>> = hash
        flipped = <<Bitwise.bxor(first, 1), rest::binary>>

        assert Cryptosuites.verify("mldsa44-jcs-2024", flipped, signature, key) ==
                 {:error, :bad_signature}
      end

      test "refuses a signature of the wrong size", %{hash: hash, signature: signature, key: key} do
        for bad <- [binary_part(signature, 0, 2419), signature <> <<0>>, :binary.copy(<<0>>, 64)] do
          assert Cryptosuites.verify("mldsa44-jcs-2024", hash, bad, key) ==
                   {:error, :bad_signature_size}
        end
      end
    end
  end

  describe "which suite and which key" do
    test "eddsa-jcs-2022 is always supported, and the list says so" do
      assert "eddsa-jcs-2022" in Cryptosuites.supported()
      assert "mldsa44-jcs-2024" in Cryptosuites.supported() == @mldsa44?
    end

    test "a suite we do not implement is not a crash", %{w3c_vector: {hash, signature, key, _}} do
      # real suites, but the RDF-canonicalisation ones need a JSON-LD processor, and ECDSA is not what the fediverse uses
      for suite <- [
            "eddsa-rdfc-2022",
            "ecdsa-jcs-2019",
            "ecdsa-rdfc-2019",
            "nonsense",
            "",
            nil,
            42
          ] do
        assert Cryptosuites.verify(suite, hash, signature, key) ==
                 {:error, :unsupported_cryptosuite},
               "#{inspect(suite)} should be unsupported"
      end
    end

    test "a suite our OpenSSL cannot do is unsupported, as an unknown one is", %{
      w3c_vector: {hash, signature, key, _}
    } do
      assert Cryptosuites.verify("mldsa44-jcs-2024", hash, signature, key,
               supported: ["eddsa-jcs-2022"]
             ) == {:error, :unsupported_cryptosuite}
    end

    test "a key of one type does not verify a proof of the other suite", %{
      w3c_vector: {hash, signature, {:ed25519, key}, _}
    } do
      assert Cryptosuites.verify("mldsa44-jcs-2024", hash, signature, {:ed25519, key},
               supported: ["eddsa-jcs-2022", "mldsa44-jcs-2024"]
             ) == {:error, :key_type_mismatch}

      assert Cryptosuites.verify("eddsa-jcs-2022", hash, signature, {:mldsa44, key}) ==
               {:error, :key_type_mismatch}
    end
  end
end
