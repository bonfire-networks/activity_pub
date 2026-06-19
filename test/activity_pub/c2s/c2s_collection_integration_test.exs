defmodule ActivityPub.Web.C2SCollectionIntegrationTest do
  @moduledoc """
  End-to-end: C2S POST to outbox actually populates GenericCollectionStore AND is reflected
  in the served collection at GET /pub/collections/keyPackages/:uuid.
  Covers: controller → C2S module → adapter → apply_to_collection_store → HTTP serving.
  """
  use ActivityPub.Web.ConnCase, async: false
  import ActivityPub.Factory
  alias ActivityPub.GenericCollectionStore, as: Store
  alias ActivityPub.Utils

  @content_type "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""

  defp outbox_endpoint(actor), do: "#{Utils.ap_base_url()}/actors/#{actor.username}/outbox"

  defp collection_endpoint(actor),
    do: "/pub/collections/keyPackages/#{actor.actor.id}?page=1"

  # POST Create{KeyPackage} and return the server-assigned object id (mirrors publishKeyPackage step 1)
  defp create_key_package(conn, actor, user) do
    resp =
      conn
      |> assign(:current_user, user)
      |> put_req_header("content-type", @content_type)
      |> post(outbox_endpoint(actor), %{
        "type" => "Create",
        "object" => %{
          "type" => "KeyPackage",
          "mediaType" => "message/mls",
          "encoding" => "base64",
          "content" => "ZmFrZS1rZXktcGFja2FnZQ==",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      })
      |> json_response(201)

    # The server assigns a new id to the embedded object; extract it
    # object may be an inline map {"id" => ...} or a URL string directly
    case resp["object"] do
      %{"id" => id} -> id
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  describe "C2S Add/Remove → store membership and HTTP serving" do
    test "Create KeyPackage then Add via outbox: appears in store and served collection", %{
      conn: conn
    } do
      actor = local_actor()
      user = user_by_ap_id(actor)
      target = Utils.collection_ap_id("keyPackages", actor.actor.id)

      kp_id = create_key_package(conn, actor, user)
      assert is_binary(kp_id)

      build_conn()
      |> assign(:current_user, user)
      |> put_req_header("content-type", @content_type)
      |> post(outbox_endpoint(actor), %{"type" => "Add", "object" => kp_id, "target" => target})
      |> json_response(201)

      # Verify store membership
      {:ok, collection} =
        Store.get_or_create_collection("keyPackages", actor.actor.id, ap_id(actor))

      assert kp_id in Store.member_ap_ids(collection)

      # Verify the GET endpoint reflects the addition
      served =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get(collection_endpoint(actor))
        |> json_response(200)

      assert served["totalItems"] == 1
      assert kp_id in served["orderedItems"]
    end

    test "Remove via outbox: disappears from store and served collection", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)
      target = Utils.collection_ap_id("keyPackages", actor.actor.id)

      kp_id = create_key_package(conn, actor, user)

      # Add
      build_conn()
      |> assign(:current_user, user)
      |> put_req_header("content-type", @content_type)
      |> post(outbox_endpoint(actor), %{"type" => "Add", "object" => kp_id, "target" => target})
      |> json_response(201)

      {:ok, collection} =
        Store.get_or_create_collection("keyPackages", actor.actor.id, ap_id(actor))

      assert kp_id in Store.member_ap_ids(collection)

      # Remove
      build_conn()
      |> assign(:current_user, user)
      |> put_req_header("content-type", @content_type)
      |> post(outbox_endpoint(actor), %{"type" => "Remove", "object" => kp_id, "target" => target})
      |> json_response(201)

      refute kp_id in Store.member_ap_ids(collection)

      # Verify the GET endpoint reflects the removal
      served =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get(collection_endpoint(actor))
        |> json_response(200)

      assert served["totalItems"] == 0
      refute kp_id in (served["orderedItems"] || [])
    end
  end
end
