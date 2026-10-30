defmodule ActivityPub.Object.LocalSignedOriginalTest do
  @moduledoc """
  A local object is stored with its signed public form (FEP-8b32, plan step 10.2): `data_received` holds the document as it is served, with its proof, and `data` only what differs from it, so the data is not kept twice. A load gives the whole document, hidden recipients (`bto`, `bcc`) included, which the signed public form never has.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import Ecto.Query

  alias ActivityPub.Object
  alias ActivityPub.Safety.IntegrityProofs

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    author = local_actor()
    {:ok, actor} = ActivityPub.Actor.get_cached(username: author.username)
    # storing an object never makes the actor's keys (that saves the actor), so it has them already
    {:ok, actor} = ActivityPub.Safety.Keys.ensure_keys_present(actor)
    %{actor: actor}
  end

  test "an actor with no key yet has its object stored without an original, and no key is made" do
    keyless = local_actor()
    {:ok, actor} = ActivityPub.Actor.get_cached(username: keyless.username)
    refute is_binary(actor.keys)

    row = stored_note(actor)

    assert is_nil(row.data_received)
    assert {:ok, still} = ActivityPub.Actor.get_cached(username: keyless.username)
    refute is_binary(still.keys)
  end

  defp stored_note(actor, object \\ %{}) do
    # a local Create with this object; the object's row is returned
    n = System.unique_integer([:positive])

    assert {:ok, activity} =
             ActivityPub.create(%{
               actor: actor,
               context: "#{actor.ap_id}/contexts/#{n}",
               to: [@public],
               object:
                 Map.merge(
                   %{
                     "id" => "#{actor.ap_id}/objects/#{n}",
                     "type" => "Note",
                     "attributedTo" => actor.ap_id,
                     "content" => String.duplicate("a long enough post to be worth not copying ", 30),
                     "to" => [@public]
                   },
                   object
                 )
             })

    {:ok, row} = Object.get_uncached(ap_id: activity.data["object"])
    row
  end

  test "keeps the object's signed public form, which verifies", %{actor: actor} do
    row = stored_note(actor)

    assert %{} = row.data_received
    assert row.authenticated == :integrity_proof
    assert IntegrityProofs.verify(row.data_received) == {:ok, actor.ap_id}
  end

  test "keeps data as a small patch over it, so the data is not stored twice", %{actor: actor} do
    row = stored_note(actor)

    # the column as stored: a load (`get_uncached`) gives the patch merged back over the original
    stored =
      ActivityPub.Utils.repo().one(from(o in Object, where: o.id == ^row.id, select: o.data))

    size = &(&1 |> Jason.encode!() |> byte_size())

    assert size.(stored) < size.(row.data_received) / 2,
           "data holds #{inspect(Map.new(stored, fn {k, v} -> {k, size.(v)} end))} bytes per key"
  end

  test "a load gives the whole document", %{actor: actor} do
    row = stored_note(actor)

    assert {:ok, loaded} = Object.get_cached(ap_id: row.data["id"])
    assert loaded.data["content"] =~ "a long enough post"
    assert loaded.data["attributedTo"] == actor.ap_id
  end

  describe "when a local object's data changes, its signed original is renewed in the same write" do
    # `do_update_existing/2` is how a reply count (`Transformer.maybe_invalidate_reply_to_cache/1`) and a poll vote are written
    test "an edit: the original holds the new content, with a proof that verifies", %{actor: actor} do
      row = stored_note(actor)

      assert {:ok, _} =
               Object.do_update_existing(row, %{data: Map.put(row.data, "content", "edited text")})

      {:ok, after_edit} = Object.get_uncached(ap_id: row.data["id"])

      assert after_edit.data_received["content"] == "edited text"
      refute after_edit.data_received == row.data_received
      assert IntegrityProofs.verify(after_edit.data_received) == {:ok, actor.ap_id}
    end

    test "a count that changes (a poll vote): the original holds it, and verifies", %{actor: actor} do
      row = stored_note(actor)

      assert {:ok, _} =
               Object.do_update_existing(row, %{data: Map.put(row.data, "votersCount", 2)})

      {:ok, after_vote} = Object.get_uncached(ap_id: row.data["id"])

      assert after_vote.data_received["votersCount"] == 2
      assert IntegrityProofs.verify(after_vote.data_received) == {:ok, actor.ap_id}
    end

    test "served after the change, it is the new document", %{actor: actor} do
      row = stored_note(actor)

      assert {:ok, _} =
               Object.do_update_existing(row, %{data: Map.put(row.data, "content", "edited text")})

      {:ok, after_edit} = Object.get_uncached(ap_id: row.data["id"])
      served = ActivityPub.Web.ObjectView.render("object.json", %{object: after_edit})

      assert served["content"] == "edited text"
      assert IntegrityProofs.verify(served) == {:ok, actor.ap_id}
    end

    test "an object stored before it had an original gets one when it is next changed" do
      keyless = local_actor()
      {:ok, no_key} = ActivityPub.Actor.get_cached(username: keyless.username)
      row = stored_note(no_key)
      assert is_nil(row.data_received)

      {:ok, with_key} = ActivityPub.Safety.Keys.ensure_keys_present(no_key)

      assert {:ok, _} =
               Object.do_update_existing(row, %{data: Map.put(row.data, "votersCount", 1)})

      {:ok, changed} = Object.get_uncached(ap_id: row.data["id"])
      assert IntegrityProofs.verify(changed.data_received) == {:ok, with_key.ap_id}
    end
  end

  describe "at delivery, an inbox's copy that is the stored public form gets the stored signed object" do
    alias ActivityPub.Safety.IntegrityProofs.Outgoing
    alias ActivityPub.Federator.Transformer

    # the Create as a publish builds it for an inbox: the object from its data, the privacy step applied, signed last
    defp create_for_inbox(actor, row, change \\ & &1) do
      {:ok, create} =
        Transformer.prepare_outgoing(%{
          "type" => "Create",
          "id" => row.data["id"] <> "/activity",
          "actor" => actor.ap_id,
          "to" => [@public],
          "object" => row.data
        })

      create = Transformer.preserve_privacy_of_outgoing(create, nil, :public)
      Map.update!(create, "object", change)
    end

    test "unchanged: the object goes out as stored, proof included", %{actor: actor} do
      row = stored_note(actor)
      signer = Outgoing.signer(actor)

      {signed, _} =
        Outgoing.sign(create_for_inbox(actor, row), signer, "2020-01-01T00:00:00Z", %{})

      assert signed["object"] == row.data_received
      assert IntegrityProofs.verify(signed["object"]) == {:ok, actor.ap_id}
    end

    test "changed for that inbox: signed anew over its own copy, which verifies", %{actor: actor} do
      row = stored_note(actor)
      signer = Outgoing.signer(actor)

      changed = create_for_inbox(actor, row, &Map.put(&1, "cc", ["https://elsewhere.example/u"]))
      {signed, _} = Outgoing.sign(changed, signer, "2020-01-01T00:00:00Z", %{})

      refute signed["object"]["proof"] == row.data_received["proof"]
      assert signed["object"]["cc"] == ["https://elsewhere.example/u"]
      assert IntegrityProofs.verify(signed["object"]) == {:ok, actor.ap_id}
    end
  end

  test "hidden recipients are in data and not in the signed form, which still verifies", %{
    actor: actor
  } do
    hidden = "https://hidden.example/users/someone"
    row = stored_note(actor, %{"bcc" => [hidden]})

    assert row.data["bcc"] == [hidden]
    refute Map.has_key?(row.data_received, "bcc")
    refute Map.has_key?(row.data_received, "bto")
    assert IntegrityProofs.verify(row.data_received) == {:ok, actor.ap_id}

    assert {:ok, loaded} = Object.get_cached(ap_id: row.data["id"])
    assert loaded.data["bcc"] == [hidden]
  end
end
