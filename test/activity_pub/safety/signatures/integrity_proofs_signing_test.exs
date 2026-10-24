defmodule ActivityPub.Safety.IntegrityProofsSigningTest do
  @moduledoc """
  `IntegrityProofs.sign/3` puts a FEP-8b32 proof on a document an actor of ours authored, with the actor's derived Ed25519 key (`Keys.ed25519_keypair/1`).

  Two things show it right. The verifier accepts what it signs, and it gives the very same document as the independent construction in the test helper (`ActivityPub.Test.IntegrityProofHelpers.sign/3`, built from the same hashing with a throwaway key): Ed25519 is deterministic, so the same key, document and time give the same bytes.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Safety.IntegrityProofs
  alias ActivityPub.Safety.Keys
  alias ActivityPub.Safety.Multibase

  @created "2026-10-24T09:30:00Z"

  setup do
    %{username: username} = local_actor()
    {:ok, actor} = ActivityPub.Actor.get_cached(username: username)
    {:ok, {public, private}} = Keys.ed25519_keypair(actor)
    {:ok, actor} = ActivityPub.Actor.get_cached(username: username)
    actor_id = actor.data["id"]

    # a verifier asks the actor's server for its document, which lists the derived key
    document = ActivityPub.Web.ActorView.render("actor.json", %{actor: actor})

    Tesla.Mock.mock(fn
      %{method: :get, url: ^actor_id} -> Tesla.Mock.json(document)
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    key = %{
      type: :ed25519,
      public: public,
      private: private,
      multibase: Multibase.encode(<<0xED, 0x01>> <> public, :base58btc)
    }

    %{actor: actor, actor_id: actor_id, key: key}
  end

  test "signs a document so that it verifies, as the actor", %{actor: actor, actor_id: actor_id} do
    note = create_note(actor_id)

    assert {:ok, signed} = IntegrityProofs.sign(note, actor)
    assert IntegrityProofs.verify(signed) == {:ok, actor_id}
  end

  test "gives the document the independent construction gives", %{
    actor: actor,
    actor_id: actor_id,
    key: key
  } do
    note = create_note(actor_id)

    assert {:ok, signed} = IntegrityProofs.sign(note, actor, created: @created)
    assert signed == sign(note, key, created: @created)
  end

  test "adds a proof and changes nothing else", %{actor: actor, actor_id: actor_id} do
    note = create_note(actor_id)

    assert {:ok, signed} = IntegrityProofs.sign(note, actor)
    assert Map.delete(signed, "proof") == note
  end

  test "the proof names the suite, the purpose, the key and the time, and carries the context", %{
    actor: actor,
    actor_id: actor_id
  } do
    note = create_note(actor_id)

    assert {:ok, %{"proof" => proof}} = IntegrityProofs.sign(note, actor, created: @created)

    assert %{
             "type" => "DataIntegrityProof",
             "cryptosuite" => "eddsa-jcs-2022",
             "proofPurpose" => "assertionMethod",
             "created" => @created
           } = proof

    assert proof["verificationMethod"] == actor_id <> "#ed25519-key"
    assert proof["@context"] == note["@context"]
    assert String.starts_with?(proof["proofValue"], "z")
  end

  test "the time is now, in UTC to the second, when none is given", %{
    actor: actor,
    actor_id: actor_id
  } do
    before = DateTime.utc_now() |> DateTime.add(-1, :second)

    assert {:ok, %{"proof" => %{"created" => created}}} =
             IntegrityProofs.sign(create_note(actor_id), actor)

    assert {:ok, at, 0} = DateTime.from_iso8601(created)
    assert String.ends_with?(created, "Z")
    assert at.microsecond == {0, 0}
    assert DateTime.compare(at, before) in [:gt, :eq]
  end

  test "signs a document whose @context holds an inline map of terms, as ours do", %{
    actor: actor,
    actor_id: actor_id
  } do
    context = [
      "https://www.w3.org/ns/activitystreams",
      %{
        "@language" => "en",
        "quote" => %{"@id" => "https://w3id.org/fep/044f#quote", "@type" => "@id"},
        "sensitive" => "as:sensitive"
      },
      "https://w3id.org/security/data-integrity/v2"
    ]

    note = actor_id |> create_note() |> Map.put("@context", context)

    assert {:ok, signed} = IntegrityProofs.sign(note, actor)
    assert IntegrityProofs.verify(signed) == {:ok, actor_id}

    # and after the trip through JSON that every delivery makes
    assert signed |> Jason.encode!() |> Jason.decode!() |> IntegrityProofs.verify() ==
             {:ok, actor_id}
  end

  test "a document changed after it was signed does not verify", %{
    actor: actor,
    actor_id: actor_id
  } do
    {:ok, signed} = IntegrityProofs.sign(create_note(actor_id, "<p>as signed</p>"), actor)

    changed = put_in(signed, ["object", "content"], "<p>as changed</p>")

    assert IntegrityProofs.verify(changed) == {:error, :bad_signature}
  end

  describe "refuses" do
    test "a cryptosuite it cannot sign with", %{actor: actor, actor_id: actor_id} do
      assert IntegrityProofs.sign(create_note(actor_id), actor, cryptosuite: "ecdsa-rdfc-2019") ==
               {:error, :unsupported_cryptosuite}
    end

    test "a document somebody else authored", %{actor: actor} do
      stranger = "https://stranger-#{System.unique_integer([:positive])}.example/users/alice"

      assert IntegrityProofs.sign(create_note(stranger), actor) == {:error, :not_the_owner}
    end

    test "a document that already has a proof", %{actor: actor, actor_id: actor_id, key: key} do
      signed = actor_id |> create_note() |> sign(key)

      assert IntegrityProofs.sign(signed, actor) == {:error, :already_signed}
    end

    test "an actor that is not ours", %{actor: actor, actor_id: actor_id} do
      remote = %{actor | local: false}

      assert {:error, _} = IntegrityProofs.sign(create_note(actor_id), remote)
    end
  end
end
