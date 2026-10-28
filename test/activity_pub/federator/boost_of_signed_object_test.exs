defmodule ActivityPub.Federator.BoostOfSignedObjectTest do
  @moduledoc """
  A boost of someone else's post that we hold signed by its author (its original kept, `data_received`) goes out with the post embedded as the author sent it, so whoever gets the boost has the post and can verify it without asking its origin. A post we hold unsigned goes out as its id, as a boost always did.

  What the boost's receiver does with an embedded post is theirs; `Announce` with an `object` map is the form FEP-1b12 groups already use.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Actor
  alias ActivityPub.Federator.APPublisher
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Object
  alias ActivityPub.Safety.IntegrityProofs

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    n = System.unique_integer([:positive])
    key = new_key(:ed25519)
    author_id = "https://author-#{n}.example/users/author"
    actor(ap_id: author_id, data: %{"assertionMethod" => [multikey(author_id, key)]})

    follower = actor(ap_id: "https://follower-#{n}.example/users/follower", shared_inbox: "https://follower-#{n}.example/inbox")

    %{username: username} = local_actor()
    {:ok, booster} = Actor.get_cached(username: username)

    assert {:ok, _} =
             delivered(
               %{
                 "@context" => "https://www.w3.org/ns/activitystreams",
                 "id" => "#{follower.ap_id}/follows/#{n}",
                 "type" => "Follow",
                 "actor" => follower.ap_id,
                 "object" => booster.data["id"]
               },
               follower.ap_id
             )

    %{key: key, author_id: author_id, booster: booster}
  end

  defp delivered(document, signer),
    do:
      Transformer.handle_incoming(document,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: signer
      )

  # what the boost sends, to each inbox
  defp sent(booster, post_id) do
    {:ok, post} = Object.get_cached(ap_id: post_id)
    {:ok, boost} = ActivityPub.announce(%{actor: booster, object: post}, skip_public_check: true)
    boost = %{boost | data: Map.put(boost.data, "to", [@public, booster.data["followers"]])}

    booster
    |> APPublisher.prepare_publish_params(boost)
    |> Enum.map(&Jason.decode!(&1.json))
    |> Enum.filter(&(&1["type"] == "Announce"))
  end

  test "a post held signed goes out embedded, as its author sent it", %{
    key: key,
    author_id: author_id,
    booster: booster
  } do
    %{"object" => note} = create = author_id |> create_note() |> sign(key)
    signed_note = sign(note, key)
    create = Map.put(create, "object", signed_note) |> Map.delete("proof") |> sign(key)
    assert {:ok, _} = delivered(create, author_id)

    assert [_ | _] = announces = sent(booster, note["id"])

    for announce <- announces do
      assert announce["object"] == signed_note
      assert IntegrityProofs.verify(announce["object"]) == {:ok, author_id}
    end
  end

  test "a post held unsigned goes out as its id", %{author_id: author_id, booster: booster} do
    %{"object" => note} = create = create_note(author_id)
    assert {:ok, _} = delivered(create, author_id)

    assert [_ | _] = announces = sent(booster, note["id"])
    for announce <- announces, do: assert(announce["object"] == note["id"])
  end
end
