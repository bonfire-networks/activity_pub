defmodule ActivityPub.GenericCollectionStoreTest do
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.GenericCollectionStore, as: Store
  alias ActivityPub.Object

  defp owner_ap_id,
    do: "https://mastodon.local/users/store_test_#{System.unique_integer([:positive])}"

  defp uid, do: "uid-#{System.unique_integer([:positive])}"

  describe "get_or_create_collection/4" do
    test "mints a stable, dereferenceable id and is idempotent" do
      owner = owner_ap_id()
      uuid = uid()

      assert {:ok, c1} = Store.get_or_create_collection("keyPackages", uuid, owner)
      assert c1.data["id"] == Utils.collection_ap_id("keyPackages", uuid)
      # keyPackages is ordered (order is significant in MLS)
      assert c1.data["type"] == "OrderedCollection"
      assert c1.data["attributedTo"] == owner

      assert {:ok, c2} = Store.get_or_create_collection("keyPackages", uuid, owner)
      assert c2.id == c1.id
    end

    test "ordered: true produces an OrderedCollection" do
      assert {:ok, c} =
               Store.get_or_create_collection("outbox", uid(), owner_ap_id(), ordered: true)

      assert c.data["type"] == "OrderedCollection"
    end
  end

  describe "membership" do
    setup do
      {:ok, collection} = Store.get_or_create_collection("keyPackages", uid(), owner_ap_id())
      %{collection: collection}
    end

    test "add_member is idempotent and counts; member_ap_ids reflects inserts", %{
      collection: collection
    } do
      a = insert(:note)
      b = insert(:note)

      assert {:ok, _} = Store.add_member(collection, a)
      assert {:ok, _} = Store.add_member(collection, b)
      # re-add: no duplicate
      assert {:ok, _} = Store.add_member(collection, a)

      assert Store.member_count(collection) == 2

      ap_ids = Store.member_ap_ids(collection)
      assert a.data["id"] in ap_ids
      assert b.data["id"] in ap_ids
    end

    test "member_objects returns the embedded objects", %{collection: collection} do
      a = insert(:note)
      assert {:ok, _} = Store.add_member(collection, a)

      assert [%Object{} = obj] = Store.member_objects(collection)
      assert obj.data["id"] == a.data["id"]
    end

    test "remove_member drops the row and is idempotent", %{collection: collection} do
      a = insert(:note)
      assert {:ok, _} = Store.add_member(collection, a)
      assert Store.member_count(collection) == 1

      assert {:ok, 1} = Store.remove_member(collection, a.data["id"])
      assert Store.member_count(collection) == 0
      # double remove: no error
      assert {:ok, 0} = Store.remove_member(collection, a.data["id"])
    end

    test "ON DELETE CASCADE removes membership when the member object is deleted", %{
      collection: collection
    } do
      a = insert(:note)
      assert {:ok, _} = Store.add_member(collection, a)
      assert Store.member_count(collection) == 1

      assert {:ok, _} = repo().delete(a)
      assert Store.member_count(collection) == 0
    end
  end
end
