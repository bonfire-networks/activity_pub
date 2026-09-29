defmodule ActivityPub.CollectionOwnerFanOutTest do
  @moduledoc """
  An `Add` or `Remove` by one actor to a collection another local actor owns, such as a moderator changing a group's moderators collection, is relayed by the owner to its followers as an `Announce`, as Lemmy does for its communities (FEP-1b12, and the fan-out FEP-400e describes).

  One to the actor's own collection, such as pinning to their own `featured`, has no one else to relay it, so it goes out as before.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Object

  setup do
    owner = local_actor()
    acting = local_actor()
    person = local_actor()

    %{
      owner: owner.actor,
      acting: acting.actor,
      person: person.actor,
      target: Utils.collection_ap_id("moderators", owner.actor.id)
    }
  end

  defp announces_by(actor) do
    Object
    |> repo().all()
    |> Enum.filter(&(&1.data["type"] == "Announce" and &1.data["actor"] == actor.ap_id))
  end

  describe "a collection owned by another local actor" do
    test "an Add is addressed to the owner and the person, not the actor's followers", %{
      owner: owner,
      acting: acting,
      person: person,
      target: target
    } do
      assert {:ok, add} =
               ActivityPub.add(%{actor: acting, object: person.ap_id, target: target})

      assert add.data["audience"] == owner.ap_id
      assert owner.ap_id in List.wrap(add.data["cc"])
      assert person.ap_id in List.wrap(add.data["cc"])
      refute acting.data["followers"] in List.wrap(add.data["to"])
    end

    test "the owner announces the Add, embedding it", %{
      owner: owner,
      acting: acting,
      person: person,
      target: target
    } do
      assert {:ok, add} =
               ActivityPub.add(%{actor: acting, object: person.ap_id, target: target})

      assert [announce] = announces_by(owner)
      assert %{"type" => "Add", "id" => add_id} = announce.data["object"]
      assert add_id == add.data["id"]
    end

    test "the owner announces a Remove the same way", %{
      owner: owner,
      acting: acting,
      person: person,
      target: target
    } do
      assert {:ok, remove} =
               ActivityPub.remove(%{actor: acting, object: person.ap_id, target: target})

      assert remove.data["audience"] == owner.ap_id
      assert [announce] = announces_by(owner)
      assert %{"type" => "Remove", "id" => remove_id} = announce.data["object"]
      assert remove_id == remove.data["id"]
    end
  end

  describe "the actor's own collection" do
    test "an Add goes to the actor's followers and nobody announces it", %{
      acting: acting,
      person: person
    } do
      own = Utils.collection_ap_id("featured", acting.id)

      assert {:ok, add} = ActivityPub.add(%{actor: acting, object: person.ap_id, target: own})

      assert acting.data["followers"] in List.wrap(add.data["to"])
      refute add.data["audience"]
      assert [] = announces_by(acting)
    end
  end
end
