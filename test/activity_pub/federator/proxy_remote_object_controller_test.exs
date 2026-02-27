defmodule ActivityPub.Web.ProxyRemoteObjectControllerTest do
  use ActivityPub.Web.ConnCase, async: false
  import ActivityPub.Factory
  import Tesla.Mock
  import Plug.Conn
  import Phoenix.ConnTest

  alias ActivityPub.Test.HttpRequestMock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  defp proxy_endpoint, do: "#{Utils.ap_base_url()}/proxy_remote_object"

  describe "authentication" do
    test "returns 401 when not authenticated", %{conn: conn} do
      note = insert(:note)

      conn =
        conn
        |> post(proxy_endpoint(), %{"id" => note.data["id"]})

      assert json_response(conn, 401)["error"] =~ "Authentication"
    end
  end

  describe "missing params" do
    test "returns 400 when id param is missing", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      conn =
        conn
        |> assign(:current_user, user)
        |> post(proxy_endpoint(), %{})

      assert json_response(conn, 400)["error"] =~ "Missing"
    end
  end

  describe "proxying a post" do
    test "returns a cached note object", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      note = insert(:note)
      note_id = note.data["id"]

      resp =
        conn
        |> assign(:current_user, user)
        |> post(proxy_endpoint(), %{"id" => note_id})
        |> json_response(200)

      assert resp["id"] == note_id
      assert resp["type"] == "Note"
    end

    test "fetches a remote note via mocked HTTP", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      remote_note_id = "https://mastodon.local/users/admin/statuses/99512778738411822"

      resp =
        conn
        |> assign(:current_user, user)
        |> post(proxy_endpoint(), %{"id" => remote_note_id})
        |> json_response(200)

      assert resp["id"] == remote_note_id
      assert resp["type"] == "Note"
      assert resp["content"]
    end

    test "returns 404 for non-existent object", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      conn =
        conn
        |> assign(:current_user, user)
        |> post(proxy_endpoint(), %{"id" => "https://404"})

      assert json_response(conn, 404)["error"] =~ "not found"
    end
  end

  describe "proxying an actor" do
    test "returns a cached actor", %{conn: conn} do
      requester = local_actor()
      user = user_by_ap_id(requester)

      remote_actor = actor(local: false)
      actor_id = remote_actor.data["id"]

      resp =
        conn
        |> assign(:current_user, user)
        |> post(proxy_endpoint(), %{"id" => actor_id})
        |> json_response(200)

      assert resp["id"] == actor_id
      assert resp["type"] == "Person"
      assert resp["preferredUsername"]
    end

    test "fetches a remote actor via mocked HTTP", %{conn: conn} do
      requester = local_actor()
      user = user_by_ap_id(requester)

      remote_actor_id = "https://mocked.local/users/karen"

      resp =
        conn
        |> assign(:current_user, user)
        |> post(proxy_endpoint(), %{"id" => remote_actor_id})
        |> json_response(200)

      assert resp["id"] == remote_actor_id
      assert resp["type"] == "Person"
      assert resp["preferredUsername"] == "karen"
    end
  end

  describe "GET /proxy_remote_object" do
    test "also works via GET with id param", %{conn: conn} do
      actor = local_actor()
      user = user_by_ap_id(actor)

      note = insert(:note)
      note_id = note.data["id"]

      resp =
        conn
        |> assign(:current_user, user)
        |> get(proxy_endpoint(), %{"id" => note_id})
        |> json_response(200)

      assert resp["id"] == note_id
      assert resp["type"] == "Note"
    end
  end
end
