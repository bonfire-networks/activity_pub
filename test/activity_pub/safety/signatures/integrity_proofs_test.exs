defmodule ActivityPub.Safety.IntegrityProofsTest do
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers
  import Tesla.Mock

  alias ActivityPub.Safety.IntegrityProofs
  alias ActivityPub.Test.IntegrityProofFixtures, as: Fixtures

  @our_origin "https://our.example"
  @mldsa44? :mldsa44 in :crypto.supports(:public_keys)

  setup do
    # an unknown URL is a 404, so a test that fetches what it should not fails to find it
    mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)
    :ok
  end

  # verification the way a receiver does it: "our" origin is fixed, so a proof's domain means the same in every test
  defp verify(document, opts \\ []),
    do: IntegrityProofs.verify(document, Keyword.merge([origin: @our_origin], opts))

  # an actor on its own origin, with its own key, listed as the proof's verification method; a fresh id per call because the actor cache outlives a test's transaction
  defp new_actor(type \\ :ed25519, opts \\ []) do
    n = System.unique_integer([:positive])
    host = opts[:host] || "signer-#{n}.example"
    actor_id = "https://#{host}/users/#{opts[:name] || "alice"}"
    key = new_key(type)
    actor(ap_id: actor_id, data: %{"assertionMethod" => [multikey(actor_id, key)]})
    %{id: actor_id, key: key}
  end

  defp signed_by(signer, opts \\ []), do: signer.id |> create_note() |> sign(signer.key, opts)

  describe "documents from the specs and from Mitra" do
    test "the FEP-8b32 vector verifies, and its controller is alice" do
      fep = Fixtures.vector(:fep_8b32)

      actor(
        ap_id: fep["actor"]["id"],
        data: %{"assertionMethod" => fep["actor"]["assertionMethod"]}
      )

      assert verify(fep["signedDocument"]) == {:ok, "https://server.example/users/alice"}
    end

    # Mitra's actor as its server serves it, and three activities as its server delivered them: test/fixtures/mitra/
    defp mitra_actor! do
      mitra = Fixtures.mitra("actor")
      actor(ap_id: mitra["id"], data: %{"assertionMethod" => mitra["assertionMethod"]})
      mitra
    end

    for kind <- ["create", "follow", "undo"] do
      test "an activity real Mitra sent verifies: #{kind}" do
        mitra = mitra_actor!()

        assert verify(Fixtures.mitra(unquote(kind))) == {:ok, mitra["id"]}
      end
    end

    test "a Mitra activity whose text was changed after signing does not" do
      mitra_actor!()

      changed =
        put_in(Fixtures.mitra("create"), ["object", "content"], "<p>edited by a relay</p>")

      assert verify(changed) == {:error, :bad_signature}
    end

    test "the RSA key Mitra lists as a Multikey is not one we verify with" do
      mitra_actor!()

      document =
        put_in(
          Fixtures.mitra("follow"),
          ["proof", "verificationMethod"],
          "https://public.mitra.social/users/mayel#main-key"
        )

      assert verify(document) == {:error, :unsupported_key_type}
    end
  end

  describe "a document signed here" do
    test "verifies, whatever the object is: a Create, and a Note by itself" do
      signer = new_actor()

      assert verify(signed_by(signer)) == {:ok, signer.id}

      note = %{
        "id" => signer.id <> "/objects/1",
        "type" => "Note",
        "attributedTo" => signer.id,
        "content" => "<p>just the object</p>"
      }

      assert verify(sign(note, signer.key)) == {:ok, signer.id}
    end

    if @mldsa44? do
      test "verifies with an ML-DSA-44 key" do
        signer = new_actor(:mldsa44)
        assert verify(signed_by(signer)) == {:ok, signer.id}
      end
    end

    test "is refused when its content was changed after signing" do
      signer = new_actor()
      document = put_in(signed_by(signer), ["object", "content"], "<p>changed</p>")

      assert verify(document) == {:error, :bad_signature}
    end

    test "is refused when the proof itself was changed" do
      signer = new_actor()
      document = put_in(signed_by(signer), ["proof", "created"], "2027-01-01T00:00:00Z")

      assert verify(document) == {:error, :bad_signature}
    end

    test "is refused when another key signed it" do
      signer = new_actor()

      document =
        signer.id
        |> create_note()
        |> sign(new_key(:ed25519), verification_method: signer.id <> "#ed25519-key")

      assert verify(document) == {:error, :bad_signature}
    end

    test "is not a document we can canonicalise" do
      signer = new_actor()
      document = put_in(signed_by(signer), ["object", "likes"], 9_007_199_254_740_993)

      assert verify(document) == {:error, :uncanonicalizable}
    end

    test "with a legacy LD signature as well still verifies, since that is added after the proof" do
      signer = new_actor()

      document =
        Map.put(signed_by(signer), "signature", %{
          "type" => "RsaSignature2017",
          "creator" => signer.id <> "#main-key",
          "signatureValue" => "c2lnbmF0dXJl"
        })

      assert verify(document) == {:ok, signer.id}
    end
  end

  describe "the proof's own fields" do
    setup do
      %{signer: new_actor()}
    end

    test "a type other than DataIntegrityProof", %{signer: s} do
      assert verify(signed_by(s, proof: %{"type" => "Ed25519Signature2020"})) ==
               {:error, :unsupported_proof_type}
    end

    test "a cryptosuite we do not implement", %{signer: s} do
      assert verify(signed_by(s, proof: %{"cryptosuite" => "ecdsa-rdfc-2019"})) ==
               {:error, :unsupported_cryptosuite}
    end

    test "a purpose other than assertionMethod", %{signer: s} do
      assert verify(signed_by(s, proof: %{"proofPurpose" => "authentication"})) ==
               {:error, :wrong_proof_purpose}
    end

    test "no verificationMethod", %{signer: s} do
      document = signed_by(s) |> update_in(["proof"], &Map.delete(&1, "verificationMethod"))
      assert verify(document) == {:error, :missing_verification_method}
    end

    test "no proofValue", %{signer: s} do
      document = signed_by(s) |> update_in(["proof"], &Map.delete(&1, "proofValue"))
      assert verify(document) == {:error, :missing_proof_value}
    end

    test "a proofValue that is not multibase", %{signer: s} do
      document = put_in(signed_by(s), ["proof", "proofValue"], "f6869")
      assert verify(document) == {:error, :unsupported_multibase}
    end

    test "a proof that has expired, and one that has not", %{signer: s} do
      assert verify(signed_by(s, proof: %{"expires" => "2020-01-01T00:00:00Z"})) ==
               {:error, :expired_proof}

      next_year = DateTime.utc_now() |> DateTime.add(365 * 86_400) |> DateTime.to_iso8601()
      assert verify(signed_by(s, proof: %{"expires" => next_year})) == {:ok, s.id}
    end

    test "a created that is not a date", %{signer: s} do
      assert verify(signed_by(s, created: "yesterday")) == {:error, :invalid_created}
    end

    test "a created in any of the forms found in the wild", %{signer: s} do
      for created <- [
            "2026-10-23T12:00:00Z",
            "2026-10-23T12:00:00.123Z",
            # Mitra writes nanoseconds
            "2026-10-23T12:00:00.484859648Z",
            "2026-10-23T14:00:00+02:00",
            # no offset at all: Data Integrity lets a verifier read it as UTC
            "2026-10-23T12:00:00"
          ] do
        assert verify(signed_by(s, created: created)) == {:ok, s.id}, "created #{created}"
      end
    end

    test "a proof that is one link of a chain", %{signer: s} do
      assert verify(signed_by(s, proof: %{"previousProof" => "urn:uuid:1"})) ==
               {:error, :unsupported_proof_chain}
    end

    test "no proof at all, or an empty list of them", %{signer: s} do
      document = create_note(s.id)
      assert verify(document) == {:error, :no_proof}
      assert verify(Map.put(document, "proof", [])) == {:error, :no_proof}
    end
  end

  describe "the three ways a proof treats the @context" do
    # see the moduledoc of `IntegrityProofs.Proof`: the spec's signer puts the document's in the proof, Mitra leaves it out and hashes without, the ML-DSA draft leaves it out and hashes with
    test "proofs made each way verify" do
      signer = new_actor()

      for style <- [:spec, :mitra, :draft] do
        assert verify(signed_by(signer, context_style: style)) == {:ok, signer.id},
               "#{style} style"
      end
    end

    test "a proof naming contexts the document does not start with is refused" do
      signer = new_actor()

      document = signed_by(signer, proof: %{"@context" => ["https://example.com/x"]})

      assert verify(document) == {:error, :context_mismatch}
    end

    test "a proof naming only the first of the document's contexts is fine" do
      signer = new_actor()

      document =
        signer.id
        |> create_note()
        |> sign(signer.key, proof: %{"@context" => "https://www.w3.org/ns/activitystreams"})

      assert verify(document) == {:ok, signer.id}
    end
  end

  describe "who owns what was signed" do
    # alice and bob share a host, so the key is on the document's origin and only the owner is wrong
    test "alice's valid proof on a document that is bob's is refused" do
      host = "shared-#{System.unique_integer([:positive])}.example"
      alice = new_actor(:ed25519, host: host, name: "alice")
      bob = new_actor(:ed25519, host: host, name: "bob")

      document =
        bob.id
        |> create_note()
        |> sign(alice.key, verification_method: alice.id <> "#ed25519-key")

      assert verify(document) == {:error, :controller_not_owner}
    end

    test "the same goes for an object: its owner is attributedTo" do
      host = "shared-#{System.unique_integer([:positive])}.example"
      alice = new_actor(:ed25519, host: host, name: "alice")
      bob = new_actor(:ed25519, host: host, name: "bob")

      note = %{"id" => bob.id <> "/objects/9", "type" => "Note", "attributedTo" => bob.id}

      assert verify(sign(note, alice.key, verification_method: alice.id <> "#ed25519-key")) ==
               {:error, :controller_not_owner}
    end

    test "a document with several owners is refused rather than reduced to the first" do
      alice = new_actor()
      bob = new_actor()

      document = %{
        "id" => alice.id <> "/activities/1",
        "type" => "Create",
        "actor" => [alice.id, bob.id]
      }

      assert verify(sign(document, alice.key, verification_method: alice.id <> "#ed25519-key")) ==
               {:error, :multiple_owners}
    end

    test "a document with no owner is refused" do
      alice = new_actor()
      document = %{"id" => alice.id <> "/things/1", "type" => "Note"}

      assert verify(sign(document, alice.key, verification_method: alice.id <> "#ed25519-key")) ==
               {:error, :no_owner}
    end

    test "a key on another origin than the document's id is refused" do
      alice = new_actor()
      document = create_note(alice.id) |> Map.put("id", "https://elsewhere.example/activities/1")

      signed = sign(document, alice.key, verification_method: alice.id <> "#ed25519-key")

      assert verify(signed) == {:error, :key_origin_mismatch}
    end

    test "the origin includes the scheme and the port" do
      alice = new_actor()
      http_id = String.replace(alice.id, "https://", "http://")
      document = create_note(alice.id) |> Map.put("id", http_id <> "/activities/1")

      signed = sign(document, alice.key, verification_method: alice.id <> "#ed25519-key")

      assert verify(signed) == {:error, :key_origin_mismatch}
    end
  end

  # FEP-fe34: the owner of an actor is the actor itself, so an actor document names no `actor` or `attributedTo` and is still owned
  describe "an actor document" do
    defp actor_document(actor_id, type \\ "Person", extra \\ %{}) do
      Map.merge(
        %{
          "@context" => [
            "https://www.w3.org/ns/activitystreams",
            "https://w3id.org/security/data-integrity/v2"
          ],
          "id" => actor_id,
          "type" => type,
          "preferredUsername" => "alice",
          "inbox" => actor_id <> "/inbox",
          "outbox" => actor_id <> "/outbox"
        },
        extra
      )
    end

    test "signed by its own key is owned by itself" do
      for type <- ["Person", "Group", "Application", "Service", "Organization"] do
        signer = new_actor()
        document = signer.id |> actor_document(type) |> sign(signer.key)

        assert verify(document) == {:ok, signer.id}, "#{type}"
      end
    end

    test "signed by another actor's key is not" do
      host = "shared-#{System.unique_integer([:positive])}.example"
      alice = new_actor(:ed25519, host: host, name: "alice")
      bob = new_actor(:ed25519, host: host, name: "bob")

      document =
        bob.id
        |> actor_document()
        |> sign(alice.key, verification_method: alice.id <> "#ed25519-key")

      assert verify(document) == {:error, :controller_not_owner}
    end

    test "with a key on another origin than its id is not" do
      alice = new_actor()
      document = actor_document("https://elsewhere.example/users/alice")

      assert verify(sign(document, alice.key, verification_method: alice.id <> "#ed25519-key")) ==
               {:error, :key_origin_mismatch}
    end

    test "a type list that includes an actor type counts" do
      signer = new_actor()
      document = signer.id |> actor_document(["Person", "Object"]) |> sign(signer.key)

      assert verify(document) == {:ok, signer.id}
    end

    test "something that is not an actor, with no actor or attributedTo, still has no owner" do
      signer = new_actor()
      document = %{"id" => signer.id <> "/things/1", "type" => "Note"}

      assert verify(sign(document, signer.key, verification_method: signer.id <> "#ed25519-key")) ==
               {:error, :no_owner}
    end
  end

  describe "a did:key verification method" do
    test "is accepted when the owner's actor lists that key, and refused when it does not" do
      key = new_key(:ed25519)
      listed_id = "https://signer-#{System.unique_integer([:positive])}.example/users/alice"
      listed_entry = %{multikey(listed_id, key) | "id" => listed_id <> "#key-1"}
      actor(ap_id: listed_id, data: %{"assertionMethod" => [listed_entry]})

      did = "did:key:" <> key.multibase <> "#" <> key.multibase
      signed = listed_id |> create_note() |> sign(key, verification_method: did)

      assert verify(signed) == {:ok, listed_id}

      stranger = new_actor()
      stranger_doc = stranger.id |> create_note() |> sign(key, verification_method: did)

      assert verify(stranger_doc) == {:error, :did_key_not_listed}
    end
  end

  describe "the proof's domain" do
    setup do
      %{signer: new_actor()}
    end

    test "is not required", %{signer: s} do
      for mode <- [:strict, :relay, :off] do
        assert verify(signed_by(s), domain_check: mode) == {:ok, s.id}
      end
    end

    test "naming us passes in every mode, written as a host or as an origin", %{signer: s} do
      for domain <- ["our.example", "https://our.example", ["somewhere.example", "our.example"]],
          mode <- [:strict, :relay, :off] do
        assert verify(signed_by(s, proof: %{"domain" => domain}), domain_check: mode) ==
                 {:ok, s.id}
      end
    end

    test "naming someone else is refused, unless the check is off", %{signer: s} do
      document = signed_by(s, proof: %{"domain" => "other.example"})

      assert verify(document, domain_check: :strict) == {:error, :wrong_domain}
      assert verify(document, domain_check: :relay) == {:error, :wrong_domain}
      assert verify(document, domain_check: :off) == {:ok, s.id}
    end

    test "naming the group that relayed it passes only in relay mode", %{signer: s} do
      document = signed_by(s, proof: %{"domain" => "group-host.example"})
      relayed_by = "https://group-host.example/pub/group/1"

      assert verify(document, domain_check: :relay, relayed_by: relayed_by) == {:ok, s.id}

      assert verify(document, domain_check: :strict, relayed_by: relayed_by) ==
               {:error, :wrong_domain}

      assert verify(document, domain_check: :relay, relayed_by: "https://another.example/g") ==
               {:error, :wrong_domain}
    end

    test "defaults to relay mode" do
      assert IntegrityProofs.domain_check_mode() == :relay
    end
  end

  describe "more than one proof" do
    test "one that verifies is enough, and the controller returned is the one that did" do
      alice = new_actor()
      bob = new_actor()

      bad = signed_by(bob) |> Map.fetch!("proof") |> Map.put("proofValue", "z2NEpo7TZRRrLZSi2U")
      good = alice.id |> create_note() |> sign(alice.key)
      document = Map.put(good, "proof", [bad, good["proof"]])

      assert verify(document) == {:ok, alice.id}
    end

    test "two that do not verify are not enough" do
      alice = new_actor()
      good = signed_by(alice)
      bad = Map.put(good["proof"], "proofValue", "z2NEpo7TZRRrLZSi2U")
      document = Map.put(good, "proof", [bad, bad])

      assert {:error, _} = verify(document)
    end
  end

  describe "a key that has been rotated" do
    setup do
      %{test_pid: self()}
    end

    defp serve_actor(actor_id, key, test_pid) do
      body =
        Jason.encode!(%{
          "@context" => ["https://www.w3.org/ns/activitystreams"],
          "id" => actor_id,
          "type" => "Person",
          "preferredUsername" => "alice",
          "inbox" => actor_id <> "/inbox",
          "outbox" => actor_id <> "/outbox",
          "assertionMethod" => [multikey(actor_id, key)]
        })

      # every request is reported to the test; only the actor's own address answers
      mock(fn %{method: :get, url: url} ->
        send(test_pid, {:fetched, url})

        if url == actor_id,
          do: %Tesla.Env{
            status: 200,
            body: body,
            headers: [{"content-type", "application/activity+json"}]
          },
          else: %Tesla.Env{status: 404, body: ""}
      end)
    end

    # how many times the actor itself was asked for: what gets stored when an actor arrives may ask for other things too, and those are not what is counted
    defp actor_fetches(actor_id) do
      Stream.repeatedly(fn ->
        receive do
          {:fetched, url} -> url
        after
          0 -> :none
        end
      end)
      |> Enum.take_while(&(&1 != :none))
      |> Enum.count(&(&1 == actor_id))
    end

    test "is picked up from the server when the key we hold fails, once", %{test_pid: test_pid} do
      old = new_actor()
      new_key = new_key(:ed25519)
      serve_actor(old.id, new_key, test_pid)

      document = old.id |> create_note() |> sign(new_key)

      assert verify(document) == {:ok, old.id}
      assert actor_fetches(old.id) == 1
    end

    test "does not turn a forged signature into a loop of fetches", %{test_pid: test_pid} do
      signer = new_actor()
      serve_actor(signer.id, signer.key, test_pid)

      forged = signer.id |> create_note() |> sign(new_key(:ed25519))

      assert verify(forged) == {:error, :bad_signature}
      assert actor_fetches(signer.id) == 1
    end
  end

  # `check/2` is what a receiver wants to know: can I rely on this proof, is it evidence against the document, or can I just not tell
  describe "check/2" do
    test "a proof that verifies names its controller" do
      signer = new_actor()
      assert IntegrityProofs.check(signed_by(signer), origin: @our_origin) == {:valid, signer.id}
    end

    test "a proof that is evidence against the document is invalid, with the reason" do
      signer = new_actor()
      altered = put_in(signed_by(signer), ["object", "content"], "<p>changed</p>")

      assert IntegrityProofs.check(altered, origin: @our_origin) == {:invalid, :bad_signature}

      host = "shared-#{System.unique_integer([:positive])}.example"
      alice = new_actor(:ed25519, host: host, name: "alice")
      bob = new_actor(:ed25519, host: host, name: "bob")

      forged =
        bob.id
        |> create_note()
        |> sign(alice.key, verification_method: alice.id <> "#ed25519-key")

      assert IntegrityProofs.check(forged, origin: @our_origin) ==
               {:invalid, :controller_not_owner}

      elsewhere = create_note(alice.id) |> Map.put("id", "https://elsewhere.example/activities/1")
      elsewhere = sign(elsewhere, alice.key, verification_method: alice.id <> "#ed25519-key")

      assert IntegrityProofs.check(elsewhere, origin: @our_origin) ==
               {:invalid, :key_origin_mismatch}
    end

    test "a proof we cannot check is unverifiable, not evidence of anything" do
      signer = new_actor()

      for {document, reason} <- [
            {signed_by(signer, proof: %{"cryptosuite" => "ecdsa-rdfc-2019"}),
             :unsupported_cryptosuite},
            {signed_by(signer, proof: %{"expires" => "2020-01-01T00:00:00Z"}), :expired_proof},
            {signed_by(signer, proof: %{"domain" => "other.example"}), :wrong_domain},
            {signed_by(signer, proof: %{"previousProof" => "urn:uuid:1"}),
             :unsupported_proof_chain}
          ] do
        assert IntegrityProofs.check(document, origin: @our_origin) == {:unverifiable, reason}
      end
    end

    test "a key we cannot get is unverifiable too" do
      stranger_id = "https://nobody-#{System.unique_integer([:positive])}.example/users/alice"
      document = stranger_id |> create_note() |> sign(new_key(:ed25519))

      assert {:unverifiable, _} = IntegrityProofs.check(document, origin: @our_origin)
    end

    test "no proof is none" do
      assert IntegrityProofs.check(create_note("https://x.example/users/a"), origin: @our_origin) ==
               :none
    end
  end

  # A `Create` or `Update` may be signed on its object only (FEP-8b32 allows either). A receiver with only the object's proof in hand authenticates the activity by it, when the object's owner is the activity's actor.
  describe "check/2 of a Create or Update signed on its object only" do
    defp signed_on_object(signer, type \\ "Create") do
      document = create_note(signer.id) |> Map.put("type", type)
      Map.update!(document, "object", &sign(&1, signer.key))
    end

    test "is valid when the object's proof is by the activity's actor" do
      signer = new_actor()

      for type <- ["Create", "Update"] do
        assert IntegrityProofs.check(signed_on_object(signer, type), origin: @our_origin) ==
                 {:valid, signer.id}
      end
    end

    test "is none when the object belongs to someone else than the activity's actor" do
      sender = new_actor()
      author = new_actor()

      document =
        create_note(sender.id)
        |> put_in(["object", "attributedTo"], author.id)
        |> put_in(["object", "id"], author.id <> "/objects/1")
        |> Map.update!("object", &sign(&1, author.key))

      assert IntegrityProofs.check(document, origin: @our_origin) == :none,
             "the object stands on its own proof; it does not authenticate the activity of someone else"
    end

    test "is invalid when the object's proof does not hold" do
      signer = new_actor()
      altered = put_in(signed_on_object(signer), ["object", "content"], "<p>changed</p>")

      assert IntegrityProofs.check(altered, origin: @our_origin) == {:invalid, :bad_signature}
    end

    test "is unverifiable when the object's proof cannot be checked" do
      signer = new_actor()

      document =
        create_note(signer.id)
        |> Map.update!(
          "object",
          &sign(&1, signer.key, proof: %{"cryptosuite" => "ecdsa-rdfc-2019"})
        )

      assert IntegrityProofs.check(document, origin: @our_origin) ==
               {:unverifiable, :unsupported_cryptosuite}
    end

    test "leaves a proof on the activity itself as it was" do
      signer = new_actor()
      assert IntegrityProofs.check(signed_by(signer), origin: @our_origin) == {:valid, signer.id}
    end

    test "does not look inside any other activity" do
      signer = new_actor()
      other = new_actor()

      announce = %{
        "id" => signer.id <> "/activities/boost-1",
        "type" => "Announce",
        "actor" => signer.id,
        "object" => sign(create_note(other.id)["object"], other.key)
      }

      assert IntegrityProofs.check(announce, origin: @our_origin) == :none
    end
  end

  describe "has_proof?/1" do
    test "is true for one proof or several, false for none" do
      assert IntegrityProofs.has_proof?(%{"proof" => %{"type" => "DataIntegrityProof"}})
      assert IntegrityProofs.has_proof?(%{"proof" => [%{"type" => "DataIntegrityProof"}]})
      refute IntegrityProofs.has_proof?(%{"proof" => []})
      refute IntegrityProofs.has_proof?(%{"proof" => nil})
      refute IntegrityProofs.has_proof?(%{"type" => "Create"})
      refute IntegrityProofs.has_proof?("not a map")
    end
  end
end
