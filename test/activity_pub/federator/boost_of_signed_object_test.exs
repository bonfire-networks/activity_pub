defmodule ActivityPub.Federator.BoostOfSignedObjectTest do
  @moduledoc """
  A boost is stored with the post's id, and goes out with the post embedded (`prepare_outgoing`, for any activity with an `object` id). Of a post we hold signed by its author (its original kept, `data_received`) what goes out is the post as the author sent it, so whoever gets the boost has the post and can verify it without asking its origin. Of a post we hold unsigned, it is our normalised copy.

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

    follower =
      actor(
        ap_id: "https://follower-#{n}.example/users/follower",
        shared_inbox: "https://follower-#{n}.example/inbox"
      )

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

  # over its author's verified HTTP signature, as the receiver worker gets it
  defp received(document, signer) do
    ActivityPub.Federator.Worker.ReceiverHelpers.perform(
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

    # as the receiver does: the proofs are checked first, which stores the post as vouched for by its own, with its original
    assert {:ok, _} = received(create, author_id)

    assert [_ | _] = announces = sent(booster, note["id"])

    for announce <- announces do
      assert announce["object"] == signed_note
      assert IntegrityProofs.verify(announce["object"]) == {:ok, author_id}
    end
  end

  # a boost fetched by its id is the same boost as the one delivered: a server that gets the id and fetches it must not get our normalised copy where the delivery carried the author's original
  test "a boost served at its own URL carries the post as its author sent it, as the delivered one does",
       %{key: key, author_id: author_id, booster: booster} do
    %{"object" => note} = create = author_id |> create_note() |> sign(key)
    signed_note = sign(note, key)
    create = Map.put(create, "object", signed_note) |> Map.delete("proof") |> sign(key)
    assert {:ok, _} = received(create, author_id)

    {:ok, post} = Object.get_cached(ap_id: note["id"])
    {:ok, boost} = ActivityPub.announce(%{actor: booster, object: post}, skip_public_check: true)

    served = ActivityPub.Web.ObjectView.render("object.json", %{object: boost.data})

    assert served["object"] == signed_note
    assert IntegrityProofs.verify(served["object"]) == {:ok, author_id}
  end

  # The same for a like. Not built yet: today a like goes only to the post's author, whose server has the post, but who it goes to will be configurable, and to anyone else the author's original is what lets them verify the post. Fails as it is: a like of a signed post goes out with our normalised copy, as a boost did. A `QuoteRequest` always goes to the quoted post's own server, so it needs none.
  @tag :todo
  test "a like of a post held signed goes out with the post as its author sent it", %{
    key: key,
    author_id: author_id,
    booster: booster
  } do
    %{"object" => note} = create = author_id |> create_note() |> sign(key)
    signed_note = sign(note, key)
    create = Map.put(create, "object", signed_note) |> Map.delete("proof") |> sign(key)
    assert {:ok, _} = received(create, author_id)

    {:ok, post} = Object.get_cached(ap_id: note["id"])
    {:ok, like} = ActivityPub.like(%{actor: booster, object: post, local: true})

    assert [_ | _] =
             payloads =
             booster
             |> APPublisher.prepare_publish_params(like)
             |> Enum.map(&Jason.decode!(&1.json))
             |> Enum.filter(&(&1["type"] == "Like"))

    for payload <- payloads do
      assert payload["object"] == signed_note
      assert IntegrityProofs.verify(payload["object"]) == {:ok, author_id}
    end
  end

  # Our own post is stored with our proof too (plan step 10.2, `local_signed_original_test.exs`), so a boost of it, by us or another local actor, carries that document, as one of someone else's does. A guard: the stored original is taken for the post's original here as it is for a received one.
  test "a post of ours goes out embedded as stored, with our proof", %{booster: booster} do
    %{username: username} = local_actor()
    {:ok, author} = Actor.get_cached(username: username)
    {:ok, author} = ActivityPub.Safety.Keys.ensure_keys_present(author)
    n = System.unique_integer([:positive])

    assert {:ok, activity} =
             ActivityPub.create(%{
               actor: author,
               context: "#{author.ap_id}/contexts/#{n}",
               to: [@public],
               object: %{
                 "id" => "#{author.ap_id}/objects/#{n}",
                 "type" => "Note",
                 "attributedTo" => author.ap_id,
                 "content" => "a post of ours",
                 "to" => [@public]
               }
             })

    {:ok, row} = Object.get_uncached(ap_id: activity.data["object"])
    assert %{"proof" => _} = row.data_received

    assert [_ | _] = announces = sent(booster, row.data["id"])

    for announce <- announces do
      assert announce["object"] == row.data_received
      assert IntegrityProofs.verify(announce["object"]) == {:ok, author.ap_id}
    end
  end

  test "a post held unsigned goes out as our normalised copy", %{
    author_id: author_id,
    booster: booster
  } do
    %{"object" => note} = create = create_note(author_id)
    assert {:ok, _} = received(create, author_id)

    assert [_ | _] = announces = sent(booster, note["id"])

    for announce <- announces do
      assert %{"id" => id, "content" => "<p>hello</p>"} = announce["object"]
      assert id == note["id"]
    end
  end
end
