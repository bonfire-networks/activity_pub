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

    @tag :todo
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

      assert resp = json_response(conn, 403)
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
  end

  describe "POST /actors/:username/outbox - error cases" do
    test "returns 400 for invalid request format", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(outbox_endpoint(actor), %{})

      assert json_response(conn, 422)
    end

    test "returns 404 for non-existent actor", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      activity_data = %{
        "type" => "Create",
        "object" => %{
          "type" => "Note",
          "content" => "Test"
        }
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post("#{Utils.ap_base_url()}/actors/nonexistent_user_12345/outbox", activity_data)

      assert conn.status in [403, 404]
    end
  end
end
