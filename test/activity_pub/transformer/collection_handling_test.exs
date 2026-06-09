defmodule ActivityPub.Federator.Transformer.CollectionHandlingTest do
  @moduledoc """
  Generic incoming collection handling via `Transformer.handle_incoming/2`, using the MLS-over-
  ActivityPub keyPackages lifecycle (Create → Add → Remove → Delete) as the concrete lib-owned
  example, plus the routing classification that decides lib-store-owned vs adapter-owned.

  - **Lifecycle:** `Add` appends a member (the collection actually contains it), `Remove` drops it,
    `Delete` tombstones the object and prunes its membership, and an `Add` by an actor who does not
    own the target is rejected (FEP-400e authority). All run **without** the
    `handle_unknown_activities` flag — the explicit `Add`/`Remove` clause is what makes that so.
  - **Routing:** `resolve_collection/1` owns a local actor's singleton (→ `{:store, …}`) but treats
    a remote actor's `featured`/wall as adapter-owned (→ `{:adapter, …}`), so the lib never tries to
    own or snapshot a foreign collection. (Consuming a remote featured is a Bonfire concern — see
    `Bonfire.Social.PinsFederationTest`; full remote-collection snapshotting is a deferred follow-up.)
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Federator.Transformer
  alias ActivityPub.GenericCollectionStore, as: Store
  alias ActivityPub.Object

  defp insert_key_package(actor_ap) do
    id = "#{actor_ap}/keyPackage/#{System.unique_integer([:positive])}"

    {:ok, kp} =
      %Object{}
      |> Ecto.Changeset.change(%{
        data: %{
          "id" => id,
          "type" => ["Object", "KeyPackage"],
          "attributedTo" => actor_ap,
          "mediaType" => "message/mls",
          "encoding" => "base64",
          "content" => "ZmFrZS1rZXktcGFja2FnZQ=="
        },
        local: true,
        public: true,
        is_object: true
      })
      |> repo().insert()

    {id, kp}
  end

  describe "lifecycle (lib-owned keyPackages collection)" do
    setup do
      la = local_actor()
      actor_ap = la.data["id"]
      actor_uuid = la.actor.id
      target = Utils.collection_ap_id("keyPackages", actor_uuid)
      %{actor_ap: actor_ap, actor_uuid: actor_uuid, target: target}
    end

    test "Add appends the member (collection contains it); Remove drops it", %{
      actor_ap: actor_ap,
      actor_uuid: actor_uuid,
      target: target
    } do
      {kp_id, _kp} = insert_key_package(actor_ap)

      assert {:ok, _activity} =
               Transformer.handle_incoming(
                 %{"type" => "Add", "actor" => actor_ap, "object" => kp_id, "target" => target},
                 local: true
               )

      {:ok, collection} = Store.get_or_create_collection("keyPackages", actor_uuid, actor_ap)
      assert kp_id in Store.member_ap_ids(collection)
      assert Store.member_count(collection) == 1

      assert {:ok, _activity} =
               Transformer.handle_incoming(
                 %{
                   "type" => "Remove",
                   "actor" => actor_ap,
                   "object" => kp_id,
                   "target" => target
                 },
                 local: true
               )

      refute kp_id in Store.member_ap_ids(collection)
      assert Store.member_count(collection) == 0
    end

    test "Delete tombstones the object and prunes its membership", %{
      actor_ap: actor_ap,
      actor_uuid: actor_uuid,
      target: target
    } do
      {kp_id, kp} = insert_key_package(actor_ap)

      {:ok, _} =
        Transformer.handle_incoming(
          %{"type" => "Add", "actor" => actor_ap, "object" => kp_id, "target" => target},
          local: true
        )

      {:ok, collection} = Store.get_or_create_collection("keyPackages", actor_uuid, actor_ap)
      assert Store.member_count(collection) == 1

      assert {:ok, _} = ActivityPub.delete(kp, true)
      assert Store.member_count(collection) == 0
    end

    test "Add by an actor who does not own the target is rejected", %{target: target} do
      other = local_actor()
      other_ap = other.data["id"]
      {kp_id, _kp} = insert_key_package(other_ap)

      assert {:error, :forbidden} =
               Transformer.handle_incoming(
                 %{"type" => "Add", "actor" => other_ap, "object" => kp_id, "target" => target},
                 local: true
               )
    end

    # serving (URI + embedded rendering over HTTP) is covered by ActivityPub.Web.CollectionServingTest
  end

  describe "routing classification (resolve_collection/1)" do
    test "a local actor's singleton collection is lib-store-owned" do
      la = local_actor()
      target = Utils.collection_ap_id("keyPackages", la.actor.id)

      assert {:store, %Object{}} = ActivityPub.resolve_collection(target)
    end

    test "a remote actor's featured is adapter-owned, not snapshotted by the lib store" do
      # Mastodon's owner-namespaced shape, which our parser intentionally does not own
      remote_featured = "https://mastodon.local/users/lain/collections/featured"

      assert {:adapter, ^remote_featured} = ActivityPub.resolve_collection(remote_featured)
    end
  end
end
