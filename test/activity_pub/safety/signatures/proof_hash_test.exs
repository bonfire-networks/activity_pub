defmodule ActivityPub.Safety.IntegrityProofs.ProofHashTest do
  use ExUnit.Case, async: true

  alias ActivityPub.Safety.IntegrityProofs.Proof
  alias ActivityPub.Test.IntegrityProofFixtures, as: Fixtures

  defp hex(binary), do: Base.encode16(binary, case: :lower)

  setup_all do
    mldsa = Fixtures.vector(:vc_di_mldsa44_jcs_2024)

    %{
      w3c: Fixtures.vector(:vc_di_eddsa_jcs_2022),
      fep: Fixtures.vector(:fep_8b32),
      mldsa: mldsa,
      mldsa_proof: mldsa["proofOptions"]
    }
  end

  describe "the combined hash of the spec vectors" do
    test "vc-di-eddsa: the credential and its proof options", %{w3c: w3c} do
      assert {:ok, hash} = Proof.hash_data(w3c["document"], w3c["proofOptions"])
      assert hex(hash) == w3c["expected"]["combinedHash"]
    end

    test "FEP-8b32: an ActivityPub Create and the proof it carries", %{fep: fep} do
      proof = fep["signedDocument"]["proof"]

      assert {:ok, hash} = Proof.hash_data(fep["document"], proof)
      assert hex(hash) == fep["expected"]["combinedHash"]
    end

    test "ML-DSA-44: its proof has no @context of its own, but was hashed as if it had the document's",
         %{mldsa: mldsa, mldsa_proof: proof} do
      refute Map.has_key?(proof, "@context")

      assert {:ok, hash} = Proof.hash_data(mldsa["document"], proof, context: :document)
      assert hex(hash) == mldsa["expected"]["combinedHash"]

      # read as given, which is the other way proofs without a @context are made, it is a different hash
      assert {:ok, as_given} = Proof.hash_data(mldsa["document"], proof)
      refute hex(as_given) == mldsa["expected"]["combinedHash"]
    end
  end

  describe "every hash a proof might have been signed over" do
    test "a proof with a @context is read one way, as given", %{fep: fep} do
      proof = fep["signedDocument"]["proof"]

      assert {:ok, [hash]} = Proof.hash_candidates(fep["document"], proof)
      assert hex(hash) == fep["expected"]["combinedHash"]
    end

    test "a proof without one is tried as given, then with the document's", %{
      mldsa: mldsa,
      mldsa_proof: proof
    } do
      assert {:ok, [as_given, injected]} = Proof.hash_candidates(mldsa["document"], proof)
      assert {:ok, ^as_given} = Proof.hash_data(mldsa["document"], proof)
      assert hex(injected) == mldsa["expected"]["combinedHash"]
    end

    test "a document with no @context has nothing to put in, so there is one way", %{fep: fep} do
      document = Map.delete(fep["document"], "@context")
      proof = fep["signedDocument"]["proof"] |> Map.delete("@context")

      assert {:ok, [_]} = Proof.hash_candidates(document, proof)
    end

    test "the proof's contexts must be the first ones of the document, in order", %{fep: fep} do
      document = fep["document"]
      proof = fep["signedDocument"]["proof"]
      [first, second] = document["@context"]

      assert {:ok, [_]} = Proof.hash_candidates(document, %{proof | "@context" => [first]})
      assert {:ok, [_]} = Proof.hash_candidates(document, %{proof | "@context" => first})

      for not_a_start <- [[second], [second, first], [first, second, "https://example.com/x"]] do
        assert Proof.hash_candidates(document, %{proof | "@context" => not_a_start}) ==
                 {:error, :context_mismatch}
      end
    end
  end

  describe "canonical forms" do
    test "FEP-8b32: the document and the proof configuration, byte for byte", %{fep: fep} do
      proof = fep["signedDocument"]["proof"]

      assert Proof.canonicalize(Proof.unsecured(fep["document"])) ==
               {:ok, fep["expected"]["canonicalDocument"]}

      assert Proof.canonicalize(Proof.proof_config(proof, fep["document"])) ==
               {:ok, fep["expected"]["canonicalProofConfig"]}
    end

    test "the proof configuration leaves out the proofValue", %{fep: fep} do
      config = Proof.proof_config(fep["signedDocument"]["proof"], fep["document"])

      refute Map.has_key?(config, "proofValue")
      assert config["cryptosuite"] == "eddsa-jcs-2022"
    end
  end

  describe "what is and is not part of the hash" do
    test "a proof's own @context is read as given, and stands in for the document's", %{fep: fep} do
      proof = fep["signedDocument"]["proof"]
      other = Map.put(proof, "@context", ["https://example.com/some-other-context"])

      {:ok, expected} = Proof.hash_data(fep["document"], proof)

      refute Proof.hash_data(fep["document"], other) == {:ok, expected}

      # the document is hashed with the proof's context in place of its own, so what the document says there does not matter
      changed = Map.put(fep["document"], "@context", ["https://example.com/yet-another"])
      assert Proof.hash_data(changed, other) == Proof.hash_data(fep["document"], other)
    end

    test "without one in the proof, the document's goes in only when asked", %{fep: fep} do
      proof = fep["signedDocument"]["proof"] |> Map.delete("@context")

      refute Map.has_key?(Proof.proof_config(proof, fep["document"]), "@context")

      assert Proof.proof_config(proof, fep["document"], context: :document)["@context"] ==
               fep["document"]["@context"]
    end

    test "a document with no @context adds nothing to the proof, even when asked" do
      proof = %{"type" => "DataIntegrityProof"}

      refute Map.has_key?(
               Proof.proof_config(proof, %{"id" => "https://example.com/1"}, context: :document),
               "@context"
             )
    end

    test "the proof member and a legacy LD signature are not hashed", %{fep: fep} do
      document = fep["document"]
      proof = fep["signedDocument"]["proof"]

      signed =
        document
        |> Map.put("proof", proof)
        |> Map.put("signature", %{
          "type" => "RsaSignature2017",
          "creator" => "https://server.example/users/alice#main-key",
          "signatureValue" => "c2lnbmF0dXJl"
        })

      assert Proof.hash_data(signed, proof) == Proof.hash_data(document, proof)
    end

    test "any change to the document changes the hash", %{fep: fep} do
      proof = fep["signedDocument"]["proof"]
      changed = put_in(fep["document"], ["object", "content"], "Hello world!")

      refute Proof.hash_data(fep["document"], proof) == Proof.hash_data(changed, proof)
    end

    test "any change to the proof configuration changes the hash", %{fep: fep} do
      document = fep["document"]
      proof = fep["signedDocument"]["proof"]

      refute Proof.hash_data(document, proof) ==
               Proof.hash_data(document, Map.put(proof, "created", "2024-01-01T00:00:00Z"))
    end
  end

  describe "canonicalisation (RFC 8785)" do
    # appendix B of the RFC: IEEE-754 bit pattern, then the text a JavaScript engine prints
    @numbers [
      {0x0000000000000000, "0"},
      {0x8000000000000000, "0"},
      {0x0000000000000001, "5e-324"},
      {0x8000000000000001, "-5e-324"},
      {0x7FEFFFFFFFFFFFFF, "1.7976931348623157e+308"},
      {0xFFEFFFFFFFFFFFFF, "-1.7976931348623157e+308"},
      {0x4340000000000000, "9007199254740992"},
      {0xC340000000000000, "-9007199254740992"},
      {0x4430000000000000, "295147905179352830000"},
      {0x44B52D02C7E14AF5, "9.999999999999997e+22"},
      {0x44B52D02C7E14AF6, "1e+23"},
      {0x44B52D02C7E14AF7, "1.0000000000000001e+23"},
      {0x444B1AE4D6E2EF4E, "999999999999999700000"},
      {0x444B1AE4D6E2EF4F, "999999999999999900000"},
      {0x444B1AE4D6E2EF50, "1e+21"},
      {0x3EB0C6F7A0B5ED8C, "9.999999999999997e-7"},
      {0x3EB0C6F7A0B5ED8D, "0.000001"},
      {0x41B3DE4355555553, "333333333.3333332"},
      {0x41B3DE4355555554, "333333333.33333325"},
      {0x41B3DE4355555555, "333333333.3333333"},
      {0x41B3DE4355555556, "333333333.3333334"},
      {0x41B3DE4355555557, "333333333.33333343"},
      {0xBECBF647612F3696, "-0.0000033333333333333333"},
      {0x43143FF3C1CB0959, "1424953923781206.2"}
    ]

    for {bits, text} <- @numbers do
      test "number 0x#{Integer.to_string(bits, 16)} is written as #{text}" do
        <<float::float-64>> = <<unquote(bits)::64>>
        assert Proof.canonicalize(%{"n" => float}) == {:ok, ~s({"n":#{unquote(text)}})}
      end
    end

    test "member names are sorted by UTF-16 code units, not code points" do
      input = %{
        "€" => "Euro Sign",
        "\r" => "Carriage Return",
        <<0xEF, 0xAC, 0xB3>> => "Hebrew Letter Dalet With Dagesh",
        "1" => "One",
        "\u{1F600}" => "Emoji: Grinning Face",
        "\u0080" => "Control",
        "ö" => "Latin Small Letter O With Diaeresis"
      }

      assert {:ok, json} = Proof.canonicalize(input)

      assert {:ok, decoded_order} = Jason.decode(json, objects: :ordered_objects)

      assert Enum.map(decoded_order.values, &elem(&1, 0)) == [
               "\r",
               "1",
               "\u0080",
               "ö",
               "€",
               "\u{1F600}",
               <<0xEF, 0xAC, 0xB3>>
             ]
    end

    test "control characters, quotes and backslashes are escaped the way the RFC says" do
      assert Proof.canonicalize(%{"s" => "\u0000\u0001\b\t\n\f\r\u001f\u007f"}) ==
               {:ok, ~s({"s":"\\u0000\\u0001\\b\\t\\n\\f\\r\\u001f\u007f"})}

      assert Proof.canonicalize(%{"s" => ~s(a"b\\c/d</script>)}) ==
               {:ok, ~s({"s":"a\\"b\\\\c/d</script>"})}
    end

    test "an integer past 2^53 has no canonical form, so it is an error, not a guess" do
      assert Proof.canonicalize(%{"n" => 9_007_199_254_740_993}) == {:error, :uncanonicalizable}

      assert Proof.canonicalize(%{"n" => 9_007_199_254_740_992}) ==
               {:ok, ~s({"n":9007199254740992})}
    end

    test "a string holding a Unicode noncharacter is an error (I-JSON)" do
      for text <- [<<0xEF, 0xBF, 0xBF>>, <<0xEF, 0xBF, 0xBE>>, <<0xEF, 0xB7, 0x90>>] do
        assert Proof.canonicalize(%{"s" => "a" <> text}) == {:error, :uncanonicalizable}
        assert Proof.canonicalize(%{text => 1}) == {:error, :uncanonicalizable}
      end
    end

    test "hash_data reports a document it cannot canonicalise instead of raising", %{fep: fep} do
      proof = fep["signedDocument"]["proof"]
      document = put_in(fep["document"], ["object", "likes"], 9_007_199_254_740_993)

      assert Proof.hash_data(document, proof) == {:error, :uncanonicalizable}
    end
  end
end
