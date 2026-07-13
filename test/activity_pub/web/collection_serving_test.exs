defmodule ActivityPub.Web.CollectionServingTest do
  @moduledoc """
  Serving collections over HTTP at `GET /pub/collections/:type/:uuid`, covering both ownership modes:

  - **store-backed** (`keyPackages`, MLS-over-ActivityPub): members come from `GenericCollectionStore`,
    rendered as URIs by default or full objects with `?embed=true`;
  - **adapter-owned** (`featured`, Mastodon-compatible pinned posts): members come from the adapter
    (Pins) via a synthesised envelope (no persisted store object).

  Plus a 404 for a non-servable collection type.
  """
  use ActivityPub.Web.ConnCase, async: false
  import ActivityPub.Factory
  import Tesla.Mock
  import Plug.Conn
  import Phoenix.ConnTest

  alias ActivityPub.Object
  alias ActivityPub.GenericCollectionStore, as: Store
  alias ActivityPub.Test.HttpRequestMock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  describe "store-backed (keyPackages)" do
    # build a local actor with one key package already added to their keyPackages collection
    defp with_key_package do
      la = local_actor()
      actor_ap = la.data["id"]
      actor_uuid = la.actor.id
      kp_id = "#{actor_ap}/keyPackage/#{System.unique_integer([:positive])}"

      {:ok, kp} =
        %Object{}
        |> Ecto.Changeset.change(%{
          data: %{
            "id" => kp_id,
            "type" => ["Object", "KeyPackage"],
            "attributedTo" => actor_ap,
            "mediaType" => "message/mls",
            "content" => "ZmFrZQ=="
          },
          local: true,
          public: true,
          is_object: true
        })
        |> repo().insert()

      {:ok, collection} = Store.get_or_create_collection("keyPackages", actor_uuid, actor_ap)
      {:ok, _} = Store.add_member(collection, kp)

      %{
        actor_uuid: actor_uuid,
        kp_id: kp_id,
        target: Utils.collection_ap_id("keyPackages", actor_uuid)
      }
    end

    test "GET serves the OrderedCollection with its members as URIs" do
      %{actor_uuid: actor_uuid, kp_id: kp_id, target: target} = with_key_package()

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/pub/collections/keyPackages/#{actor_uuid}")
        |> json_response(200)

      assert resp["@context"]
      assert resp["id"] == target
      assert resp["type"] == "OrderedCollection"
      assert resp["totalItems"] == 1
      assert kp_id in resp["first"]["orderedItems"]
    end

    test "GET with ?embed=true returns the full member objects" do
      %{actor_uuid: actor_uuid, kp_id: kp_id} = with_key_package()

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/pub/collections/keyPackages/#{actor_uuid}?page=1&embed=true")
        |> json_response(200)

      assert [%{"id" => ^kp_id, "mediaType" => "message/mls"}] = resp["orderedItems"]
    end
  end

  describe "adapter-owned (featured / Pins)" do
    test "GET serves the featured collection (pinned posts) as an OrderedCollection" do
      la = local_actor()
      user = la.user

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "<p>pinned post</p>"}},
          boundary: "public"
        )

      {:ok, _} = Bonfire.Social.Pins.pin(user, post)
      ap = Bonfire.Common.URIs.canonical_url(post, preload_if_needed: true)

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/pub/collections/featured/#{user.id}")
        |> json_response(200)

      assert resp["type"] == "OrderedCollection"
      assert resp["totalItems"] == 1
      assert ap in resp["first"]["orderedItems"]
    end
  end

  test "GET 404s for a non-servable collection type" do
    la = local_actor()

    build_conn()
    |> put_req_header("accept", "application/json")
    |> get("/pub/collections/somethingElse/#{la.actor.id}")
    |> json_response(404)
  end
end
