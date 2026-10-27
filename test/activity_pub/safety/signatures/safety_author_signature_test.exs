defmodule ActivityPub.Safety.AuthorSignatureTest do
  @moduledoc """
  `Safety.author_signature/2` says whether a document carries its AUTHOR's own signature, one that holds wherever it is passed on to, so a copy of it can be kept and relayed instead of fetched. A proof (FEP-8b32) already has to be by the document's owner. An LD signature has to be too: one that holds but was made by somebody else vouches for nothing about who wrote the document.

  The owner as `IntegrityProofs` reads it: an actor document's own `id`, an activity's `actor`, anything else's `attributedTo`.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Test.LinkedDataSignatureHelpers

  alias ActivityPub.Safety

  @context ["https://www.w3.org/ns/activitystreams", "https://w3id.org/security/v1"]

  setup do
    n = System.unique_integer([:positive])

    %{
      alice: rsa_signer!("https://alice-#{n}.local/users/alice"),
      mallory: rsa_signer!("https://mallory-#{n}.local/users/mallory")
    }
  end

  defp note(%{ap_id: author}) do
    %{
      "@context" => @context,
      "id" => author <> "/notes/#{System.unique_integer([:positive])}",
      "type" => "Note",
      "attributedTo" => author,
      "content" => "<p>hi</p>"
    }
  end

  defp create_by(%{ap_id: actor} = author) do
    %{
      "@context" => @context,
      "id" => actor <> "/activities/#{System.unique_integer([:positive])}",
      "type" => "Create",
      "actor" => actor,
      "object" => author |> note() |> Map.delete("@context")
    }
  end

  test "an LD signature by the document's author holds", %{alice: alice} do
    assert Safety.author_signature(alice |> note() |> ld_sign(alice)) == {:ok, :ld_signature}
    assert Safety.author_signature(alice |> create_by() |> ld_sign(alice)) == {:ok, :ld_signature}
  end

  test "an LD signature by somebody else is not taken as the author's", %{
    alice: alice,
    mallory: mallory
  } do
    refute Safety.author_signature(alice |> note() |> ld_sign(mallory)) == {:ok, :ld_signature}

    refute Safety.author_signature(alice |> create_by() |> ld_sign(mallory)) ==
             {:ok, :ld_signature}
  end

  test "an LD signature on a document with several owners is not taken as the author's", %{
    alice: alice,
    mallory: mallory
  } do
    shared = alice |> note() |> Map.put("attributedTo", [alice.ap_id, mallory.ap_id])

    refute Safety.author_signature(ld_sign(shared, alice)) == {:ok, :ld_signature}
  end
end
