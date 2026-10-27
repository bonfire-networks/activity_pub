defmodule ActivityPub.Object.UnalteredStorageTest do
  @moduledoc """
  A received document whose own proof or LD signature held is stored as it arrived, in `data_received`, so it still verifies when it is relayed, forwarded or served from the row; `data` holds only what normalisation changed, and a load gives the normalised document as before. Anything else is stored as before, with no original.

  An object takes its activity's `authenticated` when its activity's actor owns it, but keeps an original only when it carries a proof of its own that held: one covered only by its activity's proof is relayed inside its activity's original.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Object
  alias ActivityPub.Federator.Worker.ReceiverHelpers
  alias ActivityPub.Safety.IntegrityProofs

  @context [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/data-integrity/v2"
  ]

  setup do
    key = new_key(:ed25519)
    actor_id = "https://signer-#{System.unique_integer([:positive])}.example/users/alice"
    actor(ap_id: actor_id, data: %{"assertionMethod" => [multikey(actor_id, key)]})

    %{key: key, actor_id: actor_id}
  end

  # over its actor's verified HTTP signature, as the receiver worker gets it
  defp delivered(document) do
    ReceiverHelpers.perform(
      %Oban.Job{
        args: %{
          "op" => "incoming_ap_doc",
          "params" => document,
          "signed_by" => document["actor"],
          "repo" => ActivityPub.Utils.repo()
        }
      },
      :verified
    )
  end

  defp note_create(actor_id), do: actor_id |> create_note() |> Map.put("@context", @context)

  defp row(id) do
    {:ok, object} = Object.get_uncached(ap_id: id)
    object
  end

  describe "a Create whose proof holds" do
    setup %{key: key, actor_id: actor_id} do
      signed = actor_id |> note_create() |> sign(key)
      assert {:ok, _} = delivered(signed)
      %{signed: signed}
    end

    test "keeps the activity as it arrived, @context and proof included", %{signed: signed} do
      assert %Object{authenticated: :integrity_proof, data_received: ^signed} = row(signed["id"])
    end

    test "and that original still verifies, as stored", %{signed: signed, actor_id: actor_id} do
      assert IntegrityProofs.verify(row(signed["id"]).data_received) == {:ok, actor_id}
    end

    test "loads as the normalised activity, as before", %{signed: signed} do
      assert %Object{data: data} = row(signed["id"])
      assert data["id"] == signed["id"]
      assert data["object"] == signed["object"]["id"]
      refute Map.has_key?(data, "@context")
    end

    test "stores only the patch, with the fields queries read", %{signed: signed} do
      [patch] =
        repo().all(
          from(o in Object, where: o.data_received["id"] == ^signed["id"], select: o.data)
        )

      assert patch["id"] == signed["id"]
      assert patch["type"] == "Create"
      assert patch["actor"] == signed["actor"]
      assert patch["object"] == signed["object"]["id"]

      # not stored twice: the normalised copy has none (what it covers changed: its object became an id), so the patch only removes it
      assert Map.fetch(patch, "proof") == {:ok, nil}
      # likewise the `@context`, kept in the original only
      assert Map.fetch(patch, "@context") == {:ok, nil}
    end

    test "its object, covered only by the activity's proof, keeps no original of its own", %{
      signed: signed
    } do
      assert %Object{data_received: nil, data: %{"content" => _}} = row(signed["object"]["id"])
    end
  end

  test "an object carrying a proof of its own keeps its original too, and it verifies", %{
    key: key,
    actor_id: actor_id
  } do
    %{"object" => note} = create = note_create(actor_id)
    signed_note = note |> Map.put("@context", @context) |> sign(key)
    signed = create |> Map.put("object", signed_note) |> sign(key)

    assert {:ok, _} = delivered(signed)

    assert %Object{data_received: ^signed_note} = stored = row(note["id"])
    assert IntegrityProofs.verify(stored.data_received) == {:ok, actor_id}
  end

  describe "a stored object with an original of its own" do
    setup %{key: key, actor_id: actor_id} do
      %{"object" => note} = create = note_create(actor_id)
      signed_note = note |> Map.put("@context", @context) |> sign(key)
      assert {:ok, _} = create |> Map.put("object", signed_note) |> sign(key) |> delivered()

      %{signed_note: signed_note, stored: row(note["id"])}
    end

    test "keeps it when we write our own counts on it, and loads with them and nothing it lost",
         %{
           signed_note: signed_note,
           stored: stored
         } do
      replies = %{"type" => "Collection", "totalItems" => 1}

      assert {:ok, _} =
               Object.do_update_existing(stored, %{data: Map.put(stored.data, "replies", replies)})

      assert %Object{data_received: ^signed_note, data: data} = row(signed_note["id"])
      assert data == Map.put(stored.data, "replies", replies)
      refute Map.has_key?(data, "@context")
    end

    test "drops it when replaced by a copy without a proof of its own that holds", %{
      signed_note: signed_note,
      stored: stored
    } do
      edited = stored.data |> Map.put("content", "<p>edited</p>") |> Map.delete("summary")

      assert {:ok, _} = Object.replace(stored, edited, :http_signature)

      assert %Object{data_received: nil, data: ^edited} = row(signed_note["id"])
    end

    test "takes the new one when a newer copy whose proof holds is fetched", %{
      key: key,
      signed_note: signed_note
    } do
      newer =
        signed_note
        |> Map.delete("proof")
        |> Map.put("content", "<p>edited</p>")
        |> Map.put("updated", DateTime.utc_now() |> DateTime.to_iso8601())
        |> sign(key)

      id = newer["id"]

      Tesla.Mock.mock(fn
        %{method: :get, url: ^id} ->
          Tesla.Mock.json(newer, headers: [{"content-type", "application/activity+json"}])

        %{method: :get} ->
          %Tesla.Env{status: 404, body: ""}
      end)

      assert {:ok, _} = ActivityPub.Federator.Fetcher.fetch_fresh_object_from_id(id)

      assert %Object{data_received: ^newer, data: %{"content" => "<p>edited</p>"}} = row(id)
    end
  end

  test "a Create with no proof is stored as before, with no original", %{actor_id: actor_id} do
    unsigned = note_create(actor_id)
    assert {:ok, _} = delivered(unsigned)

    assert %Object{authenticated: :http_signature, data_received: nil, data: data} =
             row(unsigned["id"])

    assert data["object"] == unsigned["object"]["id"]
    refute Map.has_key?(data, "@context")
  end
end
