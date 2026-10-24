defmodule ActivityPub.Safety.MultibaseTest do
  use ExUnit.Case, async: true

  alias ActivityPub.Safety.Multibase
  alias ActivityPub.Test.IntegrityProofFixtures, as: Fixtures

  # The keys come from the spec vectors, so they are checked against what the specs publish rather than against our own encoder
  setup_all do
    w3c = Fixtures.vector(:vc_di_eddsa_jcs_2022)
    mldsa = Fixtures.vector(:vc_di_mldsa44_jcs_2024)

    # the secret key is 0x8026 and the 32-byte seed; the public key is derivable from the seed
    {:ok, <<0x80, 0x26, seed::binary-size(32)>>} = Multibase.decode(w3c["secretKeyMultibase"])
    {ed25519_public, _} = :crypto.generate_key(:eddsa, :ed25519, seed)

    %{w3c: w3c, mldsa: mldsa, ed25519_public: ed25519_public}
  end

  describe "base58btc ('z')" do
    test "decodes the published Ed25519 key to its multicodec prefix and the 32 key bytes", %{
      w3c: w3c,
      ed25519_public: ed25519_public
    } do
      assert {:ok, <<0xED, 0x01, key::binary-size(32)>>} =
               Multibase.decode(w3c["publicKeyMultibase"])

      assert key == ed25519_public
    end

    test "known answers from the multibase specification and the usual examples" do
      assert Multibase.encode("yes mani !", :base58btc) == "z7paNL19xttacUY"
      assert Multibase.encode("Hello World!", :base58btc) == "z2NEpo7TZRRrLZSi2U"
      assert Multibase.decode("z7paNL19xttacUY") == {:ok, "yes mani !"}
    end

    test "leading zero bytes become leading '1's and come back" do
      assert Multibase.encode(<<0, 0, 1, 2, 3>>, :base58btc) |> String.starts_with?("z11")

      for bytes <- [
            <<>>,
            <<0>>,
            <<0, 0>>,
            <<0, 0, 1, 2, 3>>,
            <<255>>,
            :crypto.strong_rand_bytes(64)
          ] do
        assert {:ok, ^bytes} = bytes |> Multibase.encode(:base58btc) |> Multibase.decode()
      end
    end

    test "the W3C proofValue decodes to the 64-byte signature the spec lists", %{w3c: w3c} do
      assert {:ok, signature} = Multibase.decode(w3c["expected"]["proofValue"])
      assert byte_size(signature) == 64
      assert Base.encode16(signature, case: :lower) == w3c["expected"]["signatureHex"]
    end

    test "a character outside the alphabet is an error, not a crash" do
      # 0, O, I and l are left out of base58 so as not to be mistaken for each other
      for bad <- ["z0", "zO", "zI", "zl", "z2NEpo7T ZRRrLZSi2U", "z+/"] do
        assert Multibase.decode(bad) == {:error, :invalid_base58}, "#{bad} should be refused"
      end
    end
  end

  describe "base64url without padding ('u')" do
    test "the ML-DSA key decodes to its two-byte prefix and the 1312 key bytes the spec lists", %{
      mldsa: mldsa
    } do
      assert {:ok, <<0x90, 0x24, key::binary>>} = Multibase.decode(mldsa["publicKeyMultibase"])
      assert byte_size(key) == 1312
      assert key == Base.decode16!(mldsa["publicKeyHex"], case: :lower)
    end

    test "encodes without padding and decodes it back" do
      assert Multibase.encode(<<1>>, :base64url) == "uAQ"
      assert Multibase.encode(<<251, 255>>, :base64url) == "u-_8"

      for bytes <- [<<>>, <<1>>, <<1, 2>>, <<1, 2, 3>>, :crypto.strong_rand_bytes(100)] do
        assert {:ok, ^bytes} = bytes |> Multibase.encode(:base64url) |> Multibase.decode()
      end
    end

    test "a character outside the alphabet is an error" do
      assert Multibase.decode("u+/+/") == {:error, :invalid_base64url}
      assert Multibase.decode("uA===") == {:error, :invalid_base64url}
    end
  end

  describe "headers it does not read" do
    test "other bases are refused by name" do
      # 'f' is base16, 'm' is base64: valid multibase, but not what these specs use
      for bad <- ["f6869", "mSGk", "bnbswy3dp", ""] do
        assert Multibase.decode(bad) == {:error, :unsupported_multibase}, "#{inspect(bad)}"
      end
    end

    test "something that is not a string" do
      assert Multibase.decode(nil) == {:error, :unsupported_multibase}
      assert Multibase.decode(123) == {:error, :unsupported_multibase}
    end
  end

  describe "multicodec varints" do
    test "match the two prefixes in the specs" do
      assert Multibase.encode_varint(0xED) == <<0xED, 0x01>>
      assert Multibase.encode_varint(0x1210) == <<0x90, 0x24>>
    end

    test "one byte up to 127, two from 128" do
      assert Multibase.encode_varint(0) == <<0>>
      assert Multibase.encode_varint(127) == <<127>>
      assert Multibase.encode_varint(128) == <<0x80, 0x01>>
    end
  end

  describe "decode_multikey/1" do
    test "reads an Ed25519 key", %{w3c: w3c, ed25519_public: ed25519_public} do
      assert Multibase.decode_multikey(w3c["publicKeyMultibase"]) ==
               {:ok, {:ed25519, ed25519_public}}
    end

    test "reads an ML-DSA-44 key", %{mldsa: mldsa} do
      assert {:ok, {:mldsa44, key}} = Multibase.decode_multikey(mldsa["publicKeyMultibase"])
      assert key == Base.decode16!(mldsa["publicKeyHex"], case: :lower)
    end

    test "refuses a key type it does not know" do
      # 0xE7 0x01 is secp256k1-pub, a real multicodec entry we do not use
      unknown = Multibase.encode(<<0xE7, 0x01>> <> :binary.copy(<<7>>, 33), :base58btc)
      assert Multibase.decode_multikey(unknown) == {:error, :unsupported_key_type}
    end

    test "refuses a key of the wrong length for its type" do
      short_ed25519 = Multibase.encode(<<0xED, 0x01>> <> :binary.copy(<<7>>, 31), :base58btc)
      assert Multibase.decode_multikey(short_ed25519) == {:error, :bad_key_length}

      short_mldsa = Multibase.encode(<<0x90, 0x24>> <> :binary.copy(<<7>>, 1311), :base64url)
      assert Multibase.decode_multikey(short_mldsa) == {:error, :bad_key_length}
    end

    test "passes on a multibase error" do
      assert Multibase.decode_multikey("f6869") == {:error, :unsupported_multibase}
    end
  end
end
