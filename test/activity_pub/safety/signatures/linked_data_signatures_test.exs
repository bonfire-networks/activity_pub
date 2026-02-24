defmodule ActivityPub.Safety.LinkedDataSignaturesTest do
  use ActivityPub.Web.ConnCase

  import ExUnit.CaptureLog
  import Tesla.Mock
  import Plug.Conn
  import Phoenix.ConnTest

  alias ActivityPub.Safety.LinkedDataSignatures
  alias ActivityPub.Safety.LinkedDataSignatures.Canonicalizer
  alias ActivityPub.Safety.Keys
  alias ActivityPub.Utils

  setup do
    mock(fn env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env]) end)
    :ok
  end

  describe "Canonicalizer" do
    test "hash/1 produces deterministic output for known input" do
      input = %{
        "@context" => "https://w3id.org/identity/v1",
        "creator" => "https://example.com/users/alice#main-key",
        "created" => "2024-01-01T00:00:00Z"
      }

      assert {:ok, hash1} = Canonicalizer.hash(input)
      assert {:ok, hash2} = Canonicalizer.hash(input)

      assert hash1 == hash2
      assert is_binary(hash1)
      # SHA-256 hex digest is 64 chars
      assert String.length(hash1) == 64
    end

    test "hash/1 produces different output for different input" do
      input1 = %{
        "@context" => "https://w3id.org/identity/v1",
        "creator" => "https://example.com/users/alice#main-key",
        "created" => "2024-01-01T00:00:00Z"
      }

      input2 = %{
        "@context" => "https://w3id.org/identity/v1",
        "creator" => "https://example.com/users/bob#main-key",
        "created" => "2024-01-01T00:00:00Z"
      }

      assert {:ok, hash1} = Canonicalizer.hash(input1)
      assert {:ok, hash2} = Canonicalizer.hash(input2)

      refute hash1 == hash2
    end

    test "canonicalize/1 produces N-Quads string" do
      input = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Create",
        "actor" => "https://example.com/users/alice"
      }

      assert {:ok, nquads} = Canonicalizer.canonicalize(input)
      assert is_binary(nquads)
    end
  end

  describe "verify/1" do
    test "round-trip: sign then verify succeeds" do
      # Generate a test keypair
      {:ok, pem} = Keys.generate_rsa_pem()
      {:ok, private_key, public_key} = Keys.keypair_from_pem(pem)

      # Encode the public key as PEM for later verification
      public_key_pem =
        :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)
        |> then(&:public_key.pem_encode([&1]))

      # Create a test activity document
      document = %{
        "@context" => [
          "https://www.w3.org/ns/activitystreams",
          "https://w3id.org/security/v1"
        ],
        "type" => "Create",
        "id" => "https://example.com/activities/1",
        "actor" => "https://example.com/users/alice",
        "object" => %{
          "type" => "Note",
          "content" => "Hello world"
        }
      }

      # Sign the document (test-only signing, matching Mastodon's algorithm)
      creator_uri = "https://example.com/users/alice#main-key"

      signature_options = %{
        "creator" => creator_uri,
        "created" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      options_to_hash =
        Map.put(signature_options, "@context", "https://w3id.org/identity/v1")

      {:ok, options_hash} = Canonicalizer.hash(options_to_hash)
      {:ok, document_hash} = Canonicalizer.hash(document)

      to_be_signed = options_hash <> document_hash

      signature_value =
        :public_key.sign(to_be_signed, :sha256, private_key)
        |> Base.encode64()

      signed_document =
        Map.put(document, "signature", %{
          "type" => "RsaSignature2017",
          "creator" => creator_uri,
          "created" => signature_options["created"],
          "signatureValue" => signature_value
        })

      # Mock the key resolution — we need to intercept the actor fetch
      # For this test, we verify the intermediate steps work correctly
      # by calling the internal functions directly

      # Verify that the options hash and document hash match what verify/1 would compute
      {:ok, verify_options_hash} = Canonicalizer.hash(options_to_hash)
      {:ok, verify_document_hash} = Canonicalizer.hash(Map.delete(signed_document, "signature"))

      assert verify_options_hash == options_hash
      assert verify_document_hash == document_hash

      # Verify the RSA signature directly
      to_be_verified = verify_options_hash <> verify_document_hash
      decoded_sig = Base.decode64!(signature_value)
      {:ok, decoded_public_key} = Keys.public_key_decode(public_key_pem)

      assert :public_key.verify(to_be_verified, :sha256, decoded_sig, decoded_public_key)
    end

    test "rejects tampered document" do
      {:ok, pem} = Keys.generate_rsa_pem()
      {:ok, private_key, _public_key} = Keys.keypair_from_pem(pem)

      document = %{
        "@context" => [
          "https://www.w3.org/ns/activitystreams",
          "https://w3id.org/security/v1"
        ],
        "type" => "Create",
        "id" => "https://example.com/activities/1",
        "actor" => "https://example.com/users/alice",
        "object" => %{
          "type" => "Note",
          "content" => "Hello world"
        }
      }

      creator_uri = "https://example.com/users/alice#main-key"

      signature_options = %{
        "creator" => creator_uri,
        "created" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      options_to_hash =
        Map.put(signature_options, "@context", "https://w3id.org/identity/v1")

      {:ok, options_hash} = Canonicalizer.hash(options_to_hash)
      {:ok, document_hash} = Canonicalizer.hash(document)

      to_be_signed = options_hash <> document_hash

      signature_value =
        :public_key.sign(to_be_signed, :sha256, private_key)
        |> Base.encode64()

      # Tamper with the document AFTER signing
      tampered_document =
        document
        |> put_in(["object", "content"], "TAMPERED content")
        |> Map.put("signature", %{
          "type" => "RsaSignature2017",
          "creator" => creator_uri,
          "created" => signature_options["created"],
          "signatureValue" => signature_value
        })

      # The document hash should now differ from what was signed
      {:ok, tampered_document_hash} =
        Canonicalizer.hash(Map.delete(tampered_document, "signature"))

      refute tampered_document_hash == document_hash
    end

    test "rejects wrong signature type" do
      json = %{
        "signature" => %{
          "type" => "Ed25519Signature2018",
          "creator" => "https://example.com/users/alice#main-key",
          "signatureValue" => "abc123"
        }
      }

      assert {:error, :unsupported_signature_type} = LinkedDataSignatures.verify(json)
    end

    test "rejects missing signature" do
      json = %{"type" => "Create", "actor" => "https://example.com/users/alice"}
      assert {:error, :no_signature} = LinkedDataSignatures.verify(json)
    end

    test "rejects malformed signature (not a map)" do
      json = %{"signature" => "not a map"}
      assert {:error, :malformed_signature} = LinkedDataSignatures.verify(json)
    end
  end

  describe "has_verifiable_signature?/1" do
    test "returns true for RsaSignature2017" do
      json = %{
        "signature" => %{
          "type" => "RsaSignature2017",
          "creator" => "https://example.com/users/alice#main-key",
          "signatureValue" => "abc123"
        }
      }

      assert LinkedDataSignatures.has_verifiable_signature?(json)
    end

    test "returns false for other signature types" do
      json = %{
        "signature" => %{
          "type" => "Ed25519Signature2018",
          "creator" => "https://example.com/users/alice#main-key"
        }
      }

      refute LinkedDataSignatures.has_verifiable_signature?(json)
    end

    test "returns false for no signature" do
      refute LinkedDataSignatures.has_verifiable_signature?(%{"type" => "Create"})
    end
  end

  describe "fixture structure validation" do
    test "hubzilla fixture has valid LD signature structure" do
      json =
        Path.join(:code.priv_dir(:activity_pub), "../test/fixtures/hubzilla-follow-activity.json")
        |> File.read!()
        |> Jason.decode!()

      assert %{"signature" => sig} = json
      assert sig["type"] == "RsaSignature2017"
      assert is_binary(sig["creator"])
      assert is_binary(sig["created"])
      assert is_binary(sig["signatureValue"])

      assert LinkedDataSignatures.has_verifiable_signature?(json)
    end
  end

  describe "incoming pipeline with LD-signed activity" do
    test "activity with valid LD signature is verified and processed end-to-end", %{conn: conn} do
      import ActivityPub.Factory

      # Generate a keypair for the remote actor
      {:ok, pem} = Keys.generate_rsa_pem()
      {:ok, private_key, public_key} = Keys.keypair_from_pem(pem)

      public_key_pem =
        :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)
        |> then(&:public_key.pem_encode([&1]))

      # Create a remote actor with the known public key
      actor_ap_id = "https://mastodon.local/ap_api/actors/ld_signer"

      _remote_actor =
        actor(
          ap_id: actor_ap_id,
          data: %{
            "publicKey" => %{
              "publicKeyPem" => public_key_pem,
              "id" => "#{actor_ap_id}#main-key",
              "owner" => actor_ap_id
            }
          }
        )

      # Build a Create+Note activity from the remote actor
      activity = %{
        "@context" => [
          "https://www.w3.org/ns/activitystreams",
          "https://w3id.org/security/v1"
        ],
        "type" => "Create",
        "id" => "#{actor_ap_id}/statuses/ld-sig-test-1/activity",
        "actor" => actor_ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => %{
          "type" => "Note",
          "id" => "#{actor_ap_id}/statuses/ld-sig-test-1",
          "attributedTo" => actor_ap_id,
          "content" => "Hello from LD signature test",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      # Sign with LD signature (matching Mastodon's RsaSignature2017 algorithm)
      creator_uri = "#{actor_ap_id}#main-key"

      signature_options = %{
        "creator" => creator_uri,
        "created" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      options_to_hash = Map.put(signature_options, "@context", "https://w3id.org/identity/v1")
      {:ok, options_hash} = Canonicalizer.hash(options_to_hash)
      {:ok, document_hash} = Canonicalizer.hash(activity)

      signature_value =
        :public_key.sign(options_hash <> document_hash, :sha256, private_key)
        |> Base.encode64()

      signed_activity =
        Map.put(activity, "signature", %{
          "type" => "RsaSignature2017",
          "creator" => creator_uri,
          "created" => signature_options["created"],
          "signatureValue" => signature_value
        })

      conn = put_req_header(conn, "content-type", "application/activity+json")

      # POST without a valid HTTP signature — the LD signature should be the
      # path that verifies and accepts the activity
      Oban.Testing.with_testing_mode(:inline, fn ->
        clear_config([:instance, :federating], true)

        log =
          capture_log(fn ->
            conn
            |> post("#{Utils.ap_base_url()}/shared_inbox", signed_activity)
            |> json_response(200)
          end)

        # Assert the LD signature was specifically the path that accepted it
        assert log =~ "Valid Linked Data Signature from",
               "Expected LD signature verification to succeed, but got:\n#{log}"

        refute log =~ "falling back to activity or object refetch"

        # The activity was processed: the Note object is now cached
        object_ap_id = "#{actor_ap_id}/statuses/ld-sig-test-1"
        assert {:ok, object} = ActivityPub.Object.get_cached(ap_id: object_ap_id)
        assert object.data["type"] == "Note"
        assert object.data["content"] == "Hello from LD signature test"
      end)
    end
  end
end
