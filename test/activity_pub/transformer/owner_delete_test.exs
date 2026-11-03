defmodule ActivityPub.Federator.Transformer.OwnerDeleteTest do
  @moduledoc """
  FEP-fe34 lets the owner of an object delete it. A `Delete` that is authenticated as the object's owner (by an HTTP signature, a proof or an LD signature) therefore needs no confirmation from the object's origin. Everything else still gets one: an unauthenticated `Delete`, one authenticated as somebody else (an admin), and the `Delete` of an actor.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Object

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    n = System.unique_integer([:positive])
    owner_id = "https://owner-#{n}.example/users/owner"
    actor(ap_id: owner_id, data: %{"assertionMethod" => [multikey(owner_id, new_key(:ed25519))]})

    # the note as the owner's server served it when we first stored it
    note_id = "#{owner_id}/notes/#{n}"

    note = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{owner_id}/activities/#{n}",
      "type" => "Create",
      "actor" => owner_id,
      "to" => [@public],
      "object" => %{
        "id" => note_id,
        "type" => "Note",
        "attributedTo" => owner_id,
        "content" => "<p>to be deleted</p>",
        "to" => [@public]
      }
    }

    Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    assert {:ok, _} =
             Transformer.handle_incoming(note,
               from_inbox: true,
               authenticated: :http_signature,
               signed_by: owner_id
             )

    %{n: n, owner_id: owner_id, note_id: note_id}
  end

  defp delete_of(object_id, actor_id) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{actor_id}/activities/delete-#{System.unique_integer([:positive])}",
      "type" => "Delete",
      "actor" => actor_id,
      "to" => [@public],
      "object" => object_id
    }
  end

  # the origin cannot be reached, so there is no way to confirm anything with it
  defp origin_unreachable(test_pid) do
    Tesla.Mock.mock(fn %{method: :get, url: url} ->
      send(test_pid, {:fetched, url})
      {:error, :nxdomain}
    end)
  end

  # the origin still serves the object as it was
  defp origin_still_serves(test_pid, object_id) do
    Tesla.Mock.mock(fn %{method: :get, url: url} ->
      send(test_pid, {:fetched, url})

      if url == object_id do
        Tesla.Mock.json(%{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => object_id,
          "type" => "Note",
          "attributedTo" => Object.get_cached!(ap_id: object_id).data["attributedTo"],
          "content" => "<p>to be deleted</p>",
          "to" => [@public]
        })
      else
        %Tesla.Env{status: 404, body: ""}
      end
    end)
  end

  defp deleted?(object_id) do
    case Object.get_cached(ap_id: object_id) do
      {:ok, %Object{data: %{"type" => "Tombstone"}}} -> true
      _ -> false
    end
  end

  describe "a Delete authenticated as the object's owner" do
    for via <- [:http_signature, :integrity_proof, :ld_signature] do
      test "deletes it without asking the origin, #{via}", %{owner_id: owner_id, note_id: note_id} do
        origin_unreachable(self())

        assert {:ok, _} =
                 Transformer.handle_incoming(delete_of(note_id, owner_id),
                   from_inbox: true,
                   authenticated: unquote(via),
                   signed_by: owner_id
                 )

        assert deleted?(note_id)
        refute_received {:fetched, ^note_id}
      end
    end

    test "deletes it though the origin still serves it", %{owner_id: owner_id, note_id: note_id} do
      origin_still_serves(self(), note_id)

      assert {:ok, _} =
               Transformer.handle_incoming(delete_of(note_id, owner_id),
                 from_inbox: true,
                 authenticated: :http_signature,
                 signed_by: owner_id
               )

      assert deleted?(note_id)
    end
  end

  describe "a Delete that is not authenticated as the object's owner" do
    test "still has to be confirmed by the origin, when nobody authenticated it", %{
      owner_id: owner_id,
      note_id: note_id
    } do
      origin_still_serves(self(), note_id)

      assert {:error, _} =
               Transformer.handle_incoming(delete_of(note_id, owner_id), from_inbox: true)

      refute deleted?(note_id)
      assert_received {:fetched, ^note_id}
    end

    test "still has to be confirmed by the origin, when authenticated as somebody else", %{
      n: n,
      owner_id: owner_id,
      note_id: note_id
    } do
      admin_id = "https://owner-#{n}.example/users/admin"
      origin_still_serves(self(), note_id)

      assert {:error, _} =
               Transformer.handle_incoming(delete_of(note_id, owner_id),
                 from_inbox: true,
                 authenticated: :http_signature,
                 signed_by: admin_id
               )

      refute deleted?(note_id)
      assert_received {:fetched, ^note_id}
    end

    test "by somebody else is a removal, not a deletion, whoever vouched for it", %{
      n: n,
      owner_id: owner_id,
      note_id: note_id
    } do
      # the Delete's actor is not the object's owner, so the owner's mark does not make it the owner's deletion; it is handed to the adapter as a removal and the object stays
      admin_id = "https://owner-#{n}.example/users/admin"
      origin_still_serves(self(), note_id)

      assert {:ok, _} =
               Transformer.handle_incoming(delete_of(note_id, admin_id),
                 from_inbox: true,
                 authenticated: :http_signature,
                 signed_by: owner_id
               )

      refute deleted?(note_id)
    end

    test "that a relay passes on, with no mark of its own, still has to be confirmed", %{
      owner_id: owner_id,
      note_id: note_id
    } do
      origin_still_serves(self(), note_id)

      assert {:error, _} =
               Transformer.handle_incoming(delete_of(note_id, owner_id),
                 from_inbox: true,
                 relayed_by: "https://some-group.example/pub/group/1",
                 authenticated: nil
               )

      refute deleted?(note_id)
    end
  end

  # a did:key has no origin of its own, so what it proves is who signed, never whose object it is: a Delete proved with one deletes only the signer's own objects
  describe "a Delete carrying a Tombstone, proved with a did:key" do
    setup %{n: n} do
      key = new_key(:ed25519)
      signer_id = "https://signer-#{n}.example/users/mallory"

      actor(
        ap_id: signer_id,
        data: %{
          "assertionMethod" => [%{multikey(signer_id, key) | "id" => signer_id <> "#key-1"}]
        }
      )

      signers_note_id = "#{signer_id}/notes/#{n}"

      assert {:ok, _} =
               Transformer.handle_incoming(
                 %{
                   "id" => "#{signer_id}/activities/#{n}",
                   "type" => "Create",
                   "actor" => signer_id,
                   "to" => [@public],
                   "object" => %{
                     "id" => signers_note_id,
                     "type" => "Note",
                     "attributedTo" => signer_id,
                     "content" => "<p>mine</p>",
                     "to" => [@public]
                   }
                 },
                 from_inbox: true,
                 authenticated: :http_signature,
                 signed_by: signer_id
               )

      %{key: key, signer_id: signer_id, signers_note_id: signers_note_id}
    end

    defp tombstone_delete(object_id, %{key: key, signer_id: signer_id}) do
      %{"id" => object_id, "type" => "Tombstone"}
      |> delete_of(signer_id)
      |> Map.put("@context", [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/data-integrity/v2"
      ])
      |> sign(key, verification_method: "did:key:" <> key.multibase <> "#" <> key.multibase)
    end

    # with no HTTP signature, so the proof is all that vouches for it
    defp delivered_with_proof_only(document) do
      ActivityPub.Federator.Worker.ReceiverHelpers.perform(
        %Oban.Job{
          args: %{
            "op" => "incoming_unverified_ap_doc",
            "params" => document,
            "headers" => %{},
            "repo" => ActivityPub.Utils.repo()
          }
        },
        :unverified
      )
    end

    test "deletes the signer's own object", %{signers_note_id: signers_note_id} = context do
      origin_unreachable(self())

      delivered_with_proof_only(tombstone_delete(signers_note_id, context))

      assert deleted?(signers_note_id)
    end

    test "does not delete somebody else's", %{note_id: note_id} = context do
      origin_still_serves(self(), note_id)

      delivered_with_proof_only(tombstone_delete(note_id, context))

      refute deleted?(note_id)
    end
  end

  describe "the Delete of an actor" do
    test "still has to be confirmed by the origin, though authenticated as that actor", %{
      owner_id: owner_id
    } do
      Tesla.Mock.mock(fn %{method: :get, url: ^owner_id} ->
        Tesla.Mock.json(%{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => owner_id,
          "type" => "Person",
          "inbox" => owner_id <> "/inbox"
        })
      end)

      assert {:error, :not_deleted} =
               Transformer.handle_incoming(delete_of(owner_id, owner_id),
                 from_inbox: true,
                 authenticated: :http_signature,
                 signed_by: owner_id
               )
    end
  end
end
