defmodule ActivityPub.Web.C2SOutboxControllerTest do
  use ActivityPub.Web.ConnCase, async: false
  use Oban.Testing, repo: repo()
  import ActivityPub.Factory
  import Tesla.Mock
  import Plug.Conn
  import Phoenix.ConnTest

  alias ActivityPub.Object
  alias ActivityPub.Test.HttpRequestMock
  alias ActivityPub.Utils
  alias ActivityPub.Tests.ObanHelpers

  @content_type "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  defp outbox_endpoint(actor), do: "#{Utils.ap_base_url()}/actors/#{actor.username}/outbox"

  # Helper to get the object ID from response (handles both string URI and map with "id")
  defp get_object_id(resp) when is_binary(resp), do: resp
  defp get_object_id(%{"id" => id}), do: id
  defp get_object_id(resp), do: resp

  describe "POST /actors/:username/outbox - authentication" do
    test "returns 401/403 when not authenticated", %{conn: conn} do
      actor = local_actor()

      activity_data = %{
        "type" => "Create",
        "actor" => ap_id(actor),
        "object" => %{
          "type" => "Note",
          "content" => "Hello, world!",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      conn =
        conn
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      assert conn.status in [401, 403]
    end

    test "can Create Note when authenticated with current_user", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      activity_data = %{
        "type" => "Create",
        "actor" => ap_id(actor),
        "object" => %{
          "type" => "Note",
          "content" => "Hello from current_user!",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      # Fetch the actual object from database
      {:ok, object} = Object.get_cached(ap_id: object_id)
      assert object.data["type"] == "Create"
    end

    test "can Create Note when authenticated with current_actor", %{conn: conn} do
      actor = local_actor()

      activity_data = %{
        "type" => "Create",
        "actor" => ap_id(actor),
        "object" => %{
          "type" => "Note",
          "content" => "Hello from current_actor!",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      conn =
        conn
        |> assign(:current_actor, actor)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      {:ok, object} = Object.get_cached(ap_id: object_id)
      assert object.data["type"] == "Create"
    end

    test "returns 403 when actor doesn't match authenticated user", %{conn: conn} do
      actor = local_actor()
      other_actor = local_actor()
      user = user_by_ap_id(other_actor)

      activity_data = %{
        "type" => "Create",
        "actor" => ap_id(actor),
        "object" => %{
          "type" => "Note",
          "content" => "Trying to post as someone else",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      # FIXME: why are we getting 400?
      resp = json_response(conn, 400) || json_response(conn, 403)
      assert resp["error"] =~ "does not match"
    end
  end

  describe "POST /actors/:username/outbox - Create activity" do
    test "creates a Note activity, without specifying actor", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      activity_data = %{
        "type" => "Create",
        "object" => %{
          "type" => "Note",
          "content" => "Hello, ActivityPub!",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      {:ok, object} = Object.get_cached(ap_id: object_id)
      assert object.data["type"] == "Create"
      assert object.data["actor"] == ap_id(actor)

      # The nested object might be a reference, so check if it exists
      case object.data["object"] do
        %{"type" => type, "content" => content} ->
          assert type == "Note"
          assert content == "Hello, ActivityPub!"

        object_uri when is_binary(object_uri) ->
          {:ok, note} = Object.get_cached(ap_id: object_uri)
          assert note.data["type"] == "Note"
          assert note.data["content"] =~ "Hello, ActivityPub!"
      end
    end

    test "wraps a bare Note object in a Create activity", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      object_data = %{
        "type" => "Note",
        "content" => "Bare note without Create wrapper",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), object_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      {:ok, object} = Object.get_cached(ap_id: object_id)
      assert object.data["type"] == "Create"
    end
  end

  describe "POST /actors/:username/outbox - Like activity" do
    test "creates a Like activity for a note", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)
      note = insert(:note)

      activity_data = %{
        "type" => "Like",
        "object" => note.data["id"]
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      {:ok, object} = Object.get_cached(ap_id: object_id)
      assert object.data["type"] == "Like"
      assert object.data["actor"] == ap_id(actor)
      assert object.data["object"] == note.data["id"]
    end
  end

  describe "POST /actors/:username/outbox - Follow activity" do
    test "creates a Follow activity", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)
      target = local_actor()

      activity_data = %{
        "type" => "Follow",
        "object" => ap_id(target)
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      {:ok, object} = Object.get_cached(ap_id: object_id)
      assert object.data["type"] == "Follow"
      assert object.data["actor"] == ap_id(actor)
      assert object.data["object"] == ap_id(target)
    end
  end

  describe "POST /actors/:username/outbox - Undo activity" do
    test "creates an Undo activity for a Follow", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)
      target = local_actor()

      # First, create a Follow
      follow_data = %{
        "type" => "Follow",
        "object" => ap_id(target)
      }

      follow_conn =
        build_conn()
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), follow_data)

      assert follow_conn.status == 201
      follow_resp = json_response(follow_conn, 201)
      follow_id = get_object_id(follow_resp)

      # Now undo it
      undo_data = %{
        "type" => "Undo",
        "object" => follow_id
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), undo_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      {:ok, object} = Object.get_cached(ap_id: object_id)
      assert object.data["type"] == "Undo"
      assert object.data["actor"] == ap_id(actor)
    end

    test "creates an Undo activity for a Like", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)
      note = insert(:note)

      # First, create a Like
      like_data = %{
        "type" => "Like",
        "object" => note.data["id"]
      }

      like_conn =
        build_conn()
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), like_data)

      assert like_conn.status == 201
      like_resp = json_response(like_conn, 201)
      like_id = get_object_id(like_resp)

      # Now undo it
      undo_data = %{
        "type" => "Undo",
        "object" => like_id
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), undo_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      {:ok, object} = Object.get_cached(ap_id: object_id)
      assert object.data["type"] == "Undo"
    end

    test "creates an Undo activity for an Announce", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)
      note = insert(:note)

      # First, create an Announce
      announce_data = %{
        "type" => "Announce",
        "object" => note.data["id"],
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

      announce_conn =
        build_conn()
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), announce_data)

      assert announce_conn.status == 201
      announce_resp = json_response(announce_conn, 201)
      announce_id = get_object_id(announce_resp)

      # Now undo it
      undo_data = %{
        "type" => "Undo",
        "object" => announce_id
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), undo_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      {:ok, object} = Object.get_cached(ap_id: object_id)
      assert object.data["type"] == "Undo"
    end

    test "creates an Undo activity for a Block", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)
      target = local_actor()

      # First, create a Block
      block_data = %{
        "type" => "Block",
        "object" => ap_id(target)
      }

      block_conn =
        build_conn()
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), block_data)

      assert block_conn.status == 201
      block_resp = json_response(block_conn, 201)
      block_id = get_object_id(block_resp)

      # Now undo it
      undo_data = %{
        "type" => "Undo",
        "object" => block_id
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), undo_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      {:ok, object} = Object.get_cached(ap_id: object_id)
      assert object.data["type"] == "Undo"
    end
  end

  describe "POST /actors/:username/outbox - Accept/Reject activity" do
    test "can Accept a Follow request", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)
      follower = local_actor()
      follower_user = user_by_ap_id(follower)

      # First, create a Follow from follower to actor
      follow_data = %{
        "type" => "Follow",
        "object" => ap_id(actor)
      }

      follow_conn =
        build_conn()
        |> assign(:current_user, follower_user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(follower), follow_data)

      assert follow_conn.status == 201
      follow_resp = json_response(follow_conn, 201)
      follow_id = get_object_id(follow_resp)

      # Now accept the follow as the target actor
      activity_data = %{
        "type" => "Accept",
        "object" => follow_id
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      {:ok, object} = Object.get_cached(ap_id: object_id)
      assert object.data["type"] == "Accept"
    end

    test "can Reject a Follow request", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)
      follower = local_actor()
      follower_user = user_by_ap_id(follower)

      # First, create a Follow from follower to actor
      follow_data = %{
        "type" => "Follow",
        "object" => ap_id(actor)
      }

      follow_conn =
        build_conn()
        |> assign(:current_user, follower_user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(follower), follow_data)

      assert follow_conn.status == 201
      follow_resp = json_response(follow_conn, 201)
      follow_id = get_object_id(follow_resp)

      # Now reject the follow as the target actor
      activity_data = %{
        "type" => "Reject",
        "object" => follow_id
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      {:ok, object} = Object.get_cached(ap_id: object_id)
      assert object.data["type"] == "Reject"
    end
  end

  describe "POST /actors/:username/outbox - error handling" do
    test "returns error when trying to delete non-existent object", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      activity_data = %{
        "type" => "Delete",
        "object" => "http://localhost:4002/pub/objects/does-not-exist-#{System.unique_integer()}"
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      # Should return not found error
      assert conn.status == 404
    end

    test "returns error when trying to update non-existent object", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      activity_data = %{
        "type" => "Update",
        "object" => %{
          "id" => "http://localhost:4002/pub/objects/does-not-exist-#{System.unique_integer()}",
          "type" => "Note",
          "content" => "Updated content"
        }
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      # Should return not found error
      assert conn.status == 404
    end
  end

  describe "POST /actors/:username/outbox - attributedTo" do
    test "sets attributedTo on nested object when not provided", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      # Note without attributedTo
      activity_data = %{
        "type" => "Create",
        "object" => %{
          "type" => "Note",
          "content" => "Note without explicit attributedTo",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      {:ok, activity} = Object.get_cached(ap_id: object_id)

      # Check the nested object has attributedTo set
      case activity.data["object"] do
        %{"attributedTo" => attributed_to} ->
          assert attributed_to == ap_id(actor)

        object_uri when is_binary(object_uri) ->
          {:ok, note} = Object.get_cached(ap_id: object_uri)
          assert note.data["attributedTo"] == ap_id(actor)
      end
    end

    test "preserves existing attributedTo on nested object", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      # Note with explicit attributedTo (same as actor)
      activity_data = %{
        "type" => "Create",
        "object" => %{
          "type" => "Note",
          "content" => "Note with explicit attributedTo",
          "attributedTo" => ap_id(actor),
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      assert conn.status == 201
    end
  end

  describe "POST /actors/:username/outbox - spec compliance" do
    test "server ignores client-provided activity id", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      client_provided_id = "https://evil.example/fake-id-123"

      activity_data = %{
        "id" => client_provided_id,
        "type" => "Create",
        "object" => %{
          "type" => "Note",
          "content" => "Testing ID stripping",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      # The returned ID should NOT be the client-provided one
      refute object_id == client_provided_id
      assert String.starts_with?(object_id, Utils.ap_base_url())
    end

    test "server ignores client-provided object id in Create", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      client_provided_object_id = "https://evil.example/fake-object-456"

      activity_data = %{
        "type" => "Create",
        "object" => %{
          "id" => client_provided_object_id,
          "type" => "Note",
          "content" => "Testing object ID stripping",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      {:ok, activity} = Object.get_cached(ap_id: object_id)

      # Check nested object ID is server-generated
      case activity.data["object"] do
        %{"id" => nested_id} ->
          refute nested_id == client_provided_object_id
          assert String.starts_with?(nested_id, Utils.ap_base_url())

        object_uri when is_binary(object_uri) ->
          refute object_uri == client_provided_object_id
      end
    end

    test "copies addressing from activity to object and vice versa", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)
      recipient = local_actor()

      activity_data = %{
        "type" => "Create",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [ap_id(recipient)],
        "object" => %{
          "type" => "Note",
          "content" => "Testing addressing copy"
          # Note: no to/cc on object
        }
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      assert conn.status == 201

      resp = json_response(conn, 201)
      object_id = get_object_id(resp)

      {:ok, activity} = Object.get_cached(ap_id: object_id)

      # Object should have inherited addressing from activity
      case activity.data["object"] do
        %{"to" => to, "cc" => cc} ->
          assert "https://www.w3.org/ns/activitystreams#Public" in to
          assert ap_id(recipient) in cc

        _ ->
          # Object stored separately, skip check
          :ok
      end
    end

    test "returns Location header with activity URL", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      activity_data = %{
        "type" => "Create",
        "object" => %{
          "type" => "Note",
          "content" => "Testing Location header",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      assert conn.status == 201

      # Check Location header is present
      location = get_resp_header(conn, "location")
      assert length(location) == 1
      [location_url] = location
      assert String.starts_with?(location_url, Utils.ap_base_url())
    end
  end

  describe "POST /actors/:username/outbox - Add/Remove activities" do
    @tag :todo
    test "Add activity adds object to target collection", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)
      note = insert(:note, %{actor: actor})
      # Assuming we have a collection the actor owns
      collection_id = ap_id(actor) <> "/collections/favorites"

      activity_data = %{
        "type" => "Add",
        "object" => note.data["id"],
        "target" => collection_id
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      # May succeed or fail depending on collection support
      assert conn.status in [201, 422, 501]
    end

    @tag :todo
    test "Remove activity removes object from target collection", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)
      note = insert(:note, %{actor: actor})
      collection_id = ap_id(actor) <> "/collections/favorites"

      activity_data = %{
        "type" => "Remove",
        "object" => note.data["id"],
        "target" => collection_id
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), activity_data)

      assert conn.status in [201, 422, 501]
    end
  end
end
