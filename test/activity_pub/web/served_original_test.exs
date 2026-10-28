defmodule ActivityPub.Web.ServedOriginalTest do
  @moduledoc """
  The route serves any public object we hold, someone else's included (`object_json` finds it by pointer id). One we hold with its original (`data_received`, kept when its proof or LD signature held) is served as the author sent it, so its proof still verifies for whoever fetches it. It is not rebuilt, and not put through the privacy step, which edits a copy (`bto`/`bcc`, URLs) and would break the author's proof. One without an original is served as before.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Federator.Worker.ReceiverHelpers
  alias ActivityPub.Object
  alias ActivityPub.Safety.IntegrityProofs
  alias ActivityPub.Web.ObjectView

  setup do
    n = System.unique_integer([:positive])
    key = new_key(:ed25519)
    author_id = "https://author-#{n}.example/users/author"
    actor(ap_id: author_id, data: %{"assertionMethod" => [multikey(author_id, key)]})
    %{key: key, author_id: author_id}
  end

  # over its author's verified HTTP signature, as the receiver worker gets it
  defp received(document, signer) do
    ReceiverHelpers.perform(
      %Oban.Job{
        args: %{
          "op" => "incoming_ap_doc",
          "params" => document,
          "signed_by" => signer,
          "repo" => ActivityPub.Utils.repo()
        }
      },
      :verified
    )
  end

  defp served(ap_id) do
    {:ok, row} = Object.get_cached(ap_id: ap_id)
    ObjectView.render("object.json", %{object: row})
  end

  test "a Create we hold signed is served as its author sent it", %{
    key: key,
    author_id: author_id
  } do
    %{"object" => note} = create = author_id |> create_note() |> sign(key)
    create = Map.put(create, "object", sign(note, key)) |> Map.delete("proof") |> sign(key)
    assert {:ok, _} = received(create, author_id)

    served = served(create["id"])

    assert served == create
    assert IntegrityProofs.verify(served) == {:ok, author_id}
  end

  test "a post we hold signed is served as its author sent it", %{key: key, author_id: author_id} do
    %{"object" => note} = create = author_id |> create_note() |> sign(key)
    signed_note = sign(note, key)
    create = Map.put(create, "object", signed_note) |> Map.delete("proof") |> sign(key)
    assert {:ok, _} = received(create, author_id)

    served = served(note["id"])

    assert served == signed_note
    assert IntegrityProofs.verify(served) == {:ok, author_id}
  end

  test "an inbox lists a signed activity addressed to its owner as its author sent it", %{
    key: key,
    author_id: author_id
  } do
    %{username: username} = local_actor()
    {:ok, owner} = ActivityPub.Actor.get_cached(username: username)

    %{"object" => note} = create = create_note(author_id)
    note = Map.put(note, "to", [owner.ap_id])

    create =
      create |> Map.put("to", [owner.ap_id]) |> Map.put("object", sign(note, key)) |> sign(key)

    assert {:ok, _} = received(create, author_id)

    %{"orderedItems" => items} = ObjectView.render("inbox.json", %{actor: owner, page: 1})

    assert create in items

    assert IntegrityProofs.verify(Enum.find(items, &(&1["id"] == create["id"]))) ==
             {:ok, author_id}
  end

  test "one we hold unsigned is served rebuilt, with no proof", %{author_id: author_id} do
    create = create_note(author_id)
    assert {:ok, _} = received(create, author_id)

    served = served(create["id"])

    assert served["id"] == create["id"]
    refute Map.has_key?(served, "proof")
  end
end
