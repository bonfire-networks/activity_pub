defmodule ActivityPub.Federator.APPublisherSigningTest do
  @moduledoc """
  What we send carries FEP-8b32 proofs, made last, over exactly the bytes each inbox gets (`APPublisher.prepare_publish_params/2`):

    * a `Create` or `Update` has a proof on its object and on the activity around it; the object's lasts (it is fetched by id, embedded in boosts and relays), and the activity's is the one Mastodon reads
    * any other activity has a proof on the activity
    * documents that come out the same for several inboxes share one proof, and one publish has one `created`
    * with `sign_object_integrity_proofs` off, or a signing that fails, it goes out as before
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Actor
  alias ActivityPub.Object
  alias ActivityPub.Federator.APPublisher
  alias ActivityPub.Safety.IntegrityProofs

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    %{username: username} = local_actor()
    {:ok, actor} = Actor.get_cached(username: username)

    n = System.unique_integer([:positive])

    # on different hosts, so each has an inbox of its own
    first = remote_actor("https://first-#{n}.example", "first")
    second = remote_actor("https://second-#{n}.example", "second")

    %{actor: actor, actor_id: actor.data["id"], first: first, second: second}
  end

  # the factory gives every actor the same shared inbox, and deliveries are grouped by it: one of their own makes each recipient a separate delivery
  defp remote_actor(origin, name),
    do: actor(ap_id: "#{origin}/users/#{name}", shared_inbox: "#{origin}/inbox")

  defp public_create(actor, recipients) do
    {:ok, activity} =
      ActivityPub.create(%{
        to: [@public],
        additional: %{"cc" => Enum.map(recipients, & &1.ap_id)},
        actor: actor,
        context: "signing-test-#{System.unique_integer([:positive])}",
        object: %{
          "type" => "Note",
          "content" => "<p>hello</p>",
          "to" => [@public],
          "attributedTo" => actor.data["id"]
        }
      })

    activity
  end

  # what each inbox is sent, decoded
  defp payloads(actor, activity) do
    actor
    |> APPublisher.prepare_publish_params(activity)
    |> Enum.map(&Jason.decode!(&1.json))
  end

  describe "a Create" do
    test "has a proof on the activity that verifies as the actor", %{
      actor: actor,
      actor_id: actor_id,
      first: first
    } do
      payloads = payloads(actor, public_create(actor, [first]))

      assert payloads != []

      for payload <- payloads do
        assert payload["type"] == "Create"
        assert IntegrityProofs.verify(payload) == {:ok, actor_id}
      end
    end

    test "has a proof on its object too, that verifies as the actor", %{
      actor: actor,
      actor_id: actor_id,
      first: first
    } do
      for payload <- payloads(actor, public_create(actor, [first])) do
        assert %{"type" => "Note", "proof" => _} = payload["object"]
        assert IntegrityProofs.verify(payload["object"]) == {:ok, actor_id}
      end
    end

    test "changed after it was signed no longer verifies", %{actor: actor, first: first} do
      [payload | _] = payloads(actor, public_create(actor, [first]))

      changed = put_in(payload, ["object", "content"], "<p>changed on the way</p>")

      assert IntegrityProofs.verify(changed) == {:error, :bad_signature}
      assert {:error, :bad_signature} = IntegrityProofs.verify(changed["object"])
    end

    test "is signed once for inboxes that get the same document, at the same time", %{
      actor: actor,
      first: first,
      second: second
    } do
      payloads = payloads(actor, public_create(actor, [first, second]))

      assert length(payloads) >= 2
      assert payloads |> Enum.map(& &1["proof"]) |> Enum.uniq() |> length() == 1
      assert payloads |> Enum.map(& &1["object"]["proof"]) |> Enum.uniq() |> length() == 1

      assert payloads |> Enum.map(& &1["proof"]["created"]) |> Enum.uniq() |> length() == 1
    end
  end

  test "a Follow has a proof on the activity", %{actor: actor, actor_id: actor_id, first: first} do
    {:ok, follow} = ActivityPub.follow(%{actor: actor, object: first})

    for payload <- payloads(actor, follow) do
      assert payload["type"] == "Follow"
      assert IntegrityProofs.verify(payload) == {:ok, actor_id}
      assert payload["object"] == first.ap_id, "its object is a reference to somebody else's"
    end
  end

  describe "a group relaying somebody else's Create" do
    # the group signs its own Announce, in both shapes it goes out in (`Transformer.wrapped_relay_data/2`); the Create inside is the remote author's, and is not ours to sign
    setup %{actor: local, first: first} do
      group = %{local | data: Map.put(local.data, "type", "Group")}

      create = insert(:note_activity, actor: first)

      # the stored form of a relay names the post, and the `Create` form is derived from it when publishing (`Transformer.wrapped_relay_data/2`)
      {:ok, announce} =
        ActivityPub.announce(%{
          actor: group,
          object: Object.get_cached!(ap_id: create.data["object"])
        })

      # the author is addressed too, so there is an inbox to deliver to
      announce = %{announce | data: Map.update!(announce.data, "cc", &[first.ap_id | &1])}

      %{group: group, announce: announce, create: create}
    end

    test "the Announce has a proof that verifies as the group, in each shape", %{
      group: group,
      actor_id: actor_id,
      announce: announce
    } do
      payloads = payloads(group, announce)

      assert length(payloads) >= 2, "both shapes go out"

      for payload <- payloads do
        assert payload["type"] == "Announce"
        assert IntegrityProofs.verify(payload) == {:ok, actor_id}
      end
    end

    test "the Create inside stays as its author made it, with no proof of ours", %{
      group: group,
      announce: announce,
      create: create
    } do
      wrapped =
        group
        |> payloads(announce)
        |> Enum.filter(&match?(%{"object" => %{"type" => "Create"}}, &1))

      assert wrapped != [], "the Announce{Create} shape goes out"

      for %{"object" => inner} <- wrapped do
        assert inner["id"] == create.data["id"]
        refute Map.has_key?(inner, "proof"), "the group cannot sign for the author"

        if is_map(inner["object"]),
          do: refute(Map.has_key?(inner["object"], "proof"), "nor for the author's post")
      end
    end
  end

  describe "when it is off, or fails" do
    test "nothing is signed with sign_object_integrity_proofs off", %{actor: actor, first: first} do
      clear_config([:sign_object_integrity_proofs], false)

      for payload <- payloads(actor, public_create(actor, [first])) do
        refute Map.has_key?(payload, "proof")
        refute Map.has_key?(payload["object"], "proof")
      end
    end

    test "it still goes out, unsigned, when signing fails", %{actor: actor, first: first} do
      clear_config([:object_integrity_cryptosuite], "no-such-suite")

      payloads = payloads(actor, public_create(actor, [first]))

      assert payloads != []

      for payload <- payloads do
        refute Map.has_key?(payload, "proof")
        assert payload["type"] == "Create"
      end
    end
  end
end
