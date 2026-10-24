defmodule ActivityPub.Federator.Transformer.SignedCopyTest do
  @moduledoc """
  A proof or LD signature covers the exact bytes its signer produced. `Transformer.fix_object/2` rewrites documents into our internal shape, so a normalised copy no longer matches what was signed, and a broken signature is worse than none: our own `signature_check/1` refuses an invalid one outright, where an absent one is accepted. A document that normalisation left alone keeps its signature, since it still verifies.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Object
  alias ActivityPub.Test.IntegrityProofFixtures, as: Fixtures

  defp note(n) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "https://signer-#{n}.example/notes/#{n}",
      "type" => "Note",
      "attributedTo" => "https://signer-#{n}.example/users/alice",
      "content" => "<p>hello</p>",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }
  end

  # a document normalisation leaves as it is, found by normalising once
  defp already_normalised(n), do: n |> note() |> Transformer.fix_object()

  defp with_ld_signature(document),
    do: Map.put(document, "signature", %{"type" => "RsaSignature2017", "signatureValue" => "abc"})

  test "keeps the proof of a document normalisation does not change" do
    n = System.unique_integer([:positive])
    document = already_normalised(n) |> sign(new_key(:ed25519))

    assert Transformer.fix_object(document) == document
  end

  test "keeps the LD signature of a document normalisation does not change" do
    n = System.unique_integer([:positive])
    document = already_normalised(n) |> with_ld_signature()

    assert Transformer.fix_object(document) == document
  end

  test "drops the proof and the signature of a document normalisation changes" do
    n = System.unique_integer([:positive])

    # no `summary`: normalisation adds an empty one
    document =
      note(n)
      |> sign(new_key(:ed25519))
      |> with_ld_signature()

    fixed = Transformer.fix_object(document)

    refute Map.has_key?(fixed, "proof")
    refute Map.has_key?(fixed, "signature")
    assert fixed["content"] == "<p>hello</p>", "the rest of the document is still there"
  end

  # A real Create from Mitra (test/fixtures/mitra/create.json), signed on the activity, delivered with its proof verified. What we store of it has been normalised, so none of it can still carry the proof it arrived with.
  test "a real Mitra Create is stored without the proof it arrived with" do
    Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    mitra = Fixtures.mitra("actor")
    actor(ap_id: mitra["id"], data: %{"assertionMethod" => mitra["assertionMethod"]})
    create = Fixtures.mitra("create")

    assert {:ok, _} =
             Transformer.handle_incoming(create,
               from_inbox: true,
               authenticated: :integrity_proof,
               signed_by: mitra["id"]
             )

    for id <- [create["id"], create["object"]["id"]] do
      assert {:ok, %Object{data: stored}} = Object.get_cached(ap_id: id)

      refute Map.has_key?(stored, "proof"), "#{id} was stored with a proof that no longer holds"
      refute Map.has_key?(stored, "signature")
    end
  end

  test "drops them when a field is rewritten, as it does when one is added" do
    n = System.unique_integer([:positive])

    # a `null` summary is rewritten to an empty one
    document =
      already_normalised(n)
      |> Map.put("summary", nil)
      |> sign(new_key(:ed25519))

    fixed = Transformer.fix_object(document)

    refute fixed == Map.delete(document, "proof")
    refute Map.has_key?(fixed, "proof")
  end
end
