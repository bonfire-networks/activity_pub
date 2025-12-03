defmodule ActivityPub.Web.ActivityPubControllerTest do
  use ActivityPub.Web.ConnCase, async: false
  use Oban.Testing, repo: repo()
  import ActivityPub.Factory
  import Tesla.Mock
  import Plug.Conn
  import Phoenix.ConnTest

  alias ActivityPub.Object
  alias ActivityPub.Test.HttpRequestMock
  alias ActivityPub.Web.ObjectView
  alias ActivityPub.Utils
  alias ActivityPub.Instances
  alias ActivityPub.Tests.ObanHelpers

  def nickname(%{nickname: nickname}), do: nickname
  def nickname(%{character: %{username: nickname}}), do: nickname
  def nickname(%{user: %{character: %{username: nickname}}}), do: nickname
  def nickname(%{username: nickname}), do: nickname

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  describe "object" do
    test "works for activities" do
      activity = insert(:note_activity)

      uuid =
        String.split(activity.data["id"], "/")
        |> List.last()

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/pub/objects/#{uuid}")
        |> json_response(200)

      assert resp["@context"]
      assert resp["type"] == "Create"
    end

    test "works for objects" do
      object = insert(:note)

      uuid =
        String.split(object.data["id"], "/")
        |> List.last()

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/pub/objects/#{uuid}")
        |> json_response(200)

      assert resp["@context"]
      assert resp["type"] == "Note"
    end

    test "works for outboxes" do
      actor = local_actor()
      insert(:note_activity, %{actor: actor})

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/pub/actors/#{actor.username}/outbox")
        |> json_response(200)

      debug(resp)
    end
  end

  describe "actor" do
    test "works for actors with AP ID" do
      actor = local_actor()

      resp =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/pub/actors/#{actor.username}")
        |> json_response(200)

      assert resp["@context"]
      assert resp["preferredUsername"] == actor.username
      assert resp["url"] == resp["id"]
    end
  end

  describe "/objects/:uuid" do
    test "it doesn't return a local-only object", %{conn: conn} do
      user = local_actor()

      case local_note_activity(%{actor: user, status: "test", boundary: "local"}) do
        {:error, :not_found} ->
          :ok

        post ->
          object = Object.normalize(post, fetch: false)
          uuid = String.split(object.data["id"], "/") |> List.last()

          conn =
            conn
            |> put_req_header("accept", "application/json")
            |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

          assert json_response(conn, 401)
      end
    end

    # probably don't want this?
    # test "returns local-only objects when authenticated", %{conn: conn} do
    #   user = local_actor()
    #   post = local_note_activity(%{actor: user, status: "test", boundary: "local"})

    #   object = Object.normalize(post, fetch: false)
    #   uuid = String.split(object.data["id"], "/") |> List.last()

    #   assert response =
    #            conn
    #            |> assign(:current_user, user)
    #            |> put_req_header("accept", "application/activity+json")
    #            |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

    #   assert json_response(response, 200) == ObjectView.render("object.json", %{object: object})
    # end

    test "does not return local-only objects for remote users", %{conn: conn} do
      user = local_actor()
      reader = actor(local: false)

      case local_note_activity(%{
             actor: user,
             status: "test @#{reader |> nickname()}",
             boundary: "local"
           }) do
        #  in case the adapter doesn't even allow federation notes with no mentions
        {:error, :not_found} ->
          :ok

        post ->
          object = Object.normalize(post, fetch: false)
          uuid = String.split(object.data["id"], "/") |> List.last()

          assert response =
                   conn
                   |> assign(:current_user, reader)
                   |> put_req_header("accept", "application/activity+json")
                   |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

          json_response(response, 401)
      end
    end

    test "it returns a json representation of the object with accept application/json", %{
      conn: conn
    } do
      note = local_note()
      uuid = String.split(note.data["id"], "/") |> List.last()

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

      assert json_response(conn, 200) == ObjectView.render("object.json", %{object: note})
    end

    test "it returns a json representation of the object with accept application/activity+json",
         %{conn: conn} do
      note = local_note()
      uuid = String.split(note.data["id"], "/") |> List.last()

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

      assert json_response(conn, 200) == ObjectView.render("object.json", %{object: note})
    end

    test "it returns a json representation of the object with accept application/ld+json", %{
      conn: conn
    } do
      note = local_note()
      uuid = String.split(note.data["id"], "/") |> List.last()

      conn =
        conn
        |> put_req_header(
          "accept",
          "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""
        )
        |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

      assert json_response(conn, 200) == ObjectView.render("object.json", %{object: note})
    end

    # TODO?
    # test "does not cache authenticated response", %{conn: conn} do
    #   user = local_actor()
    #   reader = local_actor()

    #   post =
    #     insert(:note_activity, %{actor: user, status: "test @#{reader|> nickname()}", boundary: "local"})

    #   object = Object.normalize(post, fetch: false)
    #   uuid = String.split(object.data["id"], "/") |> List.last()

    #   assert response =
    #            conn
    #            |> assign(:current_user, reader)
    #            |> put_req_header("accept", "application/activity+json")
    #            |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

    #   json_response(response, 200)

    #   conn
    #   |> put_req_header("accept", "application/activity+json")
    #   |> get("#{Utils.ap_base_url()}/objects/#{uuid}")
    #   |> json_response(404)
    # end

    test "it returns 401 for non-public posts", %{conn: conn} do
      case local_direct_note() do
        #  in case the adapter doesn't even allow federation notes with no mentions
        {:error, :not_found} ->
          :ok

        note ->
          uuid = String.split(note.data["id"], "/") |> List.last()

          conn =
            conn
            |> put_req_header("accept", "application/activity+json")
            |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

          assert json_response(conn, 401)
      end
    end

    @tag :todo
    test "returns visible non-public posts when authenticated", %{conn: conn} do
      note = local_direct_note()
      uuid = String.split(note.data["id"], "/") |> List.last()
      user = user_by_ap_id(note.data["actor"])
      marisa = local_actor()

      assert conn
             |> assign(:current_user, marisa)
             |> put_req_header("accept", "application/activity+json")
             |> get("#{Utils.ap_base_url()}/objects/#{uuid}")
             |> json_response(404)

      assert response =
               conn
               |> assign(:current_user, user)
               |> put_req_header("accept", "application/activity+json")
               |> get("#{Utils.ap_base_url()}/objects/#{uuid}")
               |> json_response(200)

      assert response == ObjectView.render("object.json", %{object: note})
    end

    #  should we send a 404 or a Tombstone object?
    @tag :todo
    test "it returns 404 for tombstone objects", %{conn: conn} do
      tombstone = insert(:tombstone)
      uuid = String.split(tombstone.data["id"], "/") |> List.last()

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

      assert json_response(conn, 404)
    end

    # TODO: caching?
    # test "it caches a response", %{conn: conn} do
    #   note = local_note()
    #   uuid = String.split(note.data["id"], "/") |> List.last()

    #   conn1 =
    #     conn
    #     |> put_req_header("accept", "application/activity+json")
    #     |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

    #   assert json_response(conn1, :ok)
    #   assert Enum.any?(conn1.resp_headers, &(&1 == {"x-cache", "MISS from Pleroma"}))

    #   conn2 =
    #     conn
    #     |> put_req_header("accept", "application/activity+json")
    #     |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

    #   assert json_response(conn1, :ok) == json_response(conn2, :ok)
    #   assert Enum.any?(conn2.resp_headers, &(&1 == {"x-cache", "HIT from Pleroma"}))
    # end

    # test "cached purged after object deletion", %{conn: conn} do
    #   note = local_note()
    #   uuid = String.split(note.data["id"], "/") |> List.last()

    #   conn1 =
    #     conn
    #     |> put_req_header("accept", "application/activity+json")
    #     |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

    #   assert json_response(conn1, :ok)
    #   assert Enum.any?(conn1.resp_headers, &(&1 == {"x-cache", "MISS from Pleroma"}))

    #   Object.delete(note)

    #   conn2 =
    #     conn
    #     |> put_req_header("accept", "application/activity+json")
    #     |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

    #   assert "Not found" == json_response(conn2, :not_found)
    # end
  end

  describe "activities at /objects/:uuid" do
    test "it doesn't return a local-only activity", %{conn: conn} do
      user = local_actor()

      case local_note_activity(%{actor: user, status: "test", boundary: "local"}) do
        #  in case the adapter doesn't even allow federation notes with no mentions
        {:error, :not_found} ->
          :ok

        post ->
          uuid = String.split(post.data["id"], "/") |> List.last()

          conn =
            conn
            |> put_req_header("accept", "application/json")
            |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

          assert json_response(conn, 404)
      end
    end

    # do we want this?
    # test "returns local-only activities when authenticated", %{conn: conn} do
    #   user = local_actor()
    #   post = local_note_activity(%{actor: user, status: "test", boundary: "local"})

    #   uuid = String.split(post.data["id"], "/") |> List.last()

    #   assert response =
    #            conn
    #            |> assign(:current_user, user)
    #            |> put_req_header("accept", "application/activity+json")
    #            |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

    #   assert json_response(response, 200) == ObjectView.render("object.json", %{object: post})
    # end

    test "it returns a json representation of the activity", %{conn: conn} do
      activity = insert(:note_activity)
      uuid = String.split(activity.data["id"], "/") |> List.last()

      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

      assert json_response(conn, 200) == ObjectView.render("object.json", %{object: activity})
    end

    test "it returns 404 for non-public activities", %{conn: conn} do
      case local_direct_note() do
        #  in case the adapter doesn't even allow federation notes with no mentions
        {:error, :not_found} ->
          :ok

        note ->
          activity = insert(:direct_note_activity, note: note)
          uuid = String.split(activity.data["id"], "/") |> List.last()

          conn =
            conn
            |> put_req_header("accept", "application/activity+json")
            |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

          assert json_response(conn, 404)
      end
    end

    @tag :todo
    test "returns visible non-public posts or messages when correctly authenticated", %{
      conn: conn
    } do
      author = local_actor()
      to = local_actor()
      third_party = local_actor()
      note = local_direct_note(actor: author, to: to)
      uuid = String.split(note.data["id"], "/") |> List.last()

      assert conn
             |> assign(:current_user, user_by_ap_id(third_party))
             |> put_req_header("accept", "application/activity+json")
             |> get("#{Utils.ap_base_url()}/objects/#{uuid}")
             |> json_response(404)

      assert response =
               conn
               |> assign(:current_user, user_by_ap_id(author))
               |> put_req_header("accept", "application/activity+json")
               |> get("#{Utils.ap_base_url()}/objects/#{uuid}")
               |> json_response(200)

      assert response =
               conn
               |> assign(:current_user, user_by_ap_id(to))
               |> put_req_header("accept", "application/activity+json")
               |> get("#{Utils.ap_base_url()}/objects/#{uuid}")
               |> json_response(200)

      assert response == ObjectView.render("object.json", %{object: note})
    end

    # TODO: caching?
    # test "it caches a response", %{conn: conn} do
    #   activity = insert(:note_activity)
    #   uuid = String.split(activity.data["id"], "/") |> List.last()

    #   conn1 =
    #     conn
    #     |> put_req_header("accept", "application/activity+json")
    #     |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

    #   assert json_response(conn1, :ok)
    #   assert Enum.any?(conn1.resp_headers, &(&1 == {"x-cache", "MISS from Pleroma"}))

    #   conn2 =
    #     conn
    #     |> put_req_header("accept", "application/activity+json")
    #     |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

    #   assert json_response(conn1, :ok) == json_response(conn2, :ok)
    #   assert Enum.any?(conn2.resp_headers, &(&1 == {"x-cache", "HIT from Pleroma"}))
    # end

    # test "cached purged after activity deletion", %{conn: conn} do
    #   user = local_actor()
    #   activity = insert(:note_activity, %{actor: user, status: "cofe"})

    #   uuid = String.split(activity.data["id"], "/") |> List.last()

    #   conn1 =
    #     conn
    #     |> put_req_header("accept", "application/activity+json")
    #     |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

    #   assert json_response(conn1, :ok)
    #   assert Enum.any?(conn1.resp_headers, &(&1 == {"x-cache", "MISS from Pleroma"}))

    #   Object.delete_all_by_object_ap_id(activity.object.data["id"])

    #   conn2 =
    #     conn
    #     |> put_req_header("accept", "application/activity+json")
    #     |> get("#{Utils.ap_base_url()}/objects/#{uuid}")

    #   assert "Not found" == json_response(conn2, :not_found)
    # end
  end

  describe "/shared_inbox" do
    test "it inserts an incoming activity into the database", %{conn: conn} do
      data = file("fixtures/mastodon/mastodon-post-activity.json") |> Jason.decode!()

      subject = actor(local: false)

      data =
        data
        |> Map.put("actor", subject.data["id"])

      conn =
        conn
        |> assign(:valid_signature, true)
        |> put_req_header(
          "signature",
          "keyId=\"https://mastodon.local/users/admin/main-key\""
        )
        |> put_req_header("content-type", "application/activity+json")
        |> post("#{Utils.ap_base_url()}/shared_inbox", data)

      assert json_response(conn, 200) in ["ok", "tbd"]

      #  worker = ActivityPub.Federator.Worker.ReceiverRouter.route_worker(data, true)
      #  |> debug("worker routed")

      ObanHelpers.perform(all_enqueued())
      assert Object.get_cached!(ap_id: data["id"])
    end

    @tag capture_log: true
    test "it inserts an incoming activity into the database" <>
           "even if we can't fetch the user but have it in our db",
         %{conn: conn} do
      user =
        insert(:actor,
          ap_id: "https://mastodon.local/users/raymoo",
          ap_enabled: true,
          local: false,
          last_refreshed_at: nil
        )

      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Jason.decode!()
        |> Map.put("actor", ap_id(user))
        |> put_in(["object", "attributedTo"], ap_id(user))

      subject = actor(local: false)

      data =
        data
        |> Map.put("actor", subject.data["id"])

      conn =
        conn
        |> assign(:valid_signature, true)
        |> put_req_header("signature", "keyId=\"#{ap_id(user)}/main-key\"")
        |> put_req_header("content-type", "application/activity+json")
        |> post("#{Utils.ap_base_url()}/shared_inbox", data)

      assert json_response(conn, 200) in ["ok", "tbd"]

      ObanHelpers.perform(all_enqueued())
      assert Object.get_cached!(ap_id: data["id"])
    end

    # can't do this because adapter needs to handle pruned objects
    @tag :todo
    test "it discards Delete activities for unknown objects without enqueueing", %{conn: conn} do
      subject = actor(local: false)

      data =
        file("fixtures/mastodon/mastodon-delete.json")
        |> Jason.decode!()
        |> Map.put("actor", subject.data["id"])
        |> put_in(["object", "id"], "https://remote.example/objects/unknown-123")

      conn =
        conn
        |> assign(:valid_signature, true)
        |> put_req_header("signature", "keyId=\"#{subject.data["id"]}/main-key\"")
        |> put_req_header("content-type", "application/activity+json")
        |> post("#{Utils.ap_base_url()}/shared_inbox", data)

      assert json_response(conn, 200) == "ok"

      # Verify no Oban job was enqueued
      assert all_enqueued() == []

      # Verify object was not (fetched or) cached
      assert {:error, :not_found} =
               Object.get_cached(ap_id: "https://remote.example/objects/unknown-123")
    end
  end

  test "it clears `unreachable` federation status of the sender instance when receiving an activity",
       %{conn: conn} do
    data = file("fixtures/mastodon/mastodon-post-activity.json") |> Jason.decode!()

    subject = actor(local: false)

    data =
      data
      |> Map.put("actor", subject.data["id"])

    sender_url = data["actor"]
    sender = local_actor(ap_id: data["actor"])

    Instances.set_consistently_unreachable(sender_url)
    refute Instances.reachable?(sender_url)

    conn =
      conn
      |> assign(:valid_signature, true)
      |> put_req_header("signature", "keyId=\"#{ap_id(sender)}/main-key\"")
      |> put_req_header("content-type", "application/activity+json")
      |> post("#{Utils.ap_base_url()}/shared_inbox", data)

    assert json_response(conn, 200) in ["ok", "tbd"]
    assert Instances.reachable?(sender_url)
  end

  describe "/users/:nickname/inbox" do
    setup do
      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Jason.decode!()

      [data: data]
    end

    test "it inserts an incoming activity into the database", %{conn: conn, data: data} do
      user = local_actor()
      subject = actor(local: false)

      data =
        data
        |> Map.put("actor", subject.data["id"])
        |> Map.put("bcc", [ap_id(user)])
        |> Kernel.put_in(["object", "bcc"], [ap_id(user)])

      conn =
        conn
        |> assign(:valid_signature, true)
        |> put_req_header("signature", "keyId=\"#{data["actor"]}/main-key\"")
        |> put_req_header("content-type", "application/activity+json")
        |> post("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/inbox", data)

      assert "ok" == json_response(conn, 200)
      ObanHelpers.perform(all_enqueued())
      assert Object.get_cached!(ap_id: data["id"])
    end

    test "it accepts messages with to as string instead of array", %{conn: conn, data: data} do
      user = local_actor()
      subject = actor(local: false)

      data =
        data
        |> Map.put("actor", subject.data["id"])
        |> Map.put("to", ap_id(user))
        |> Map.put("cc", [])
        |> Kernel.put_in(["object", "to"], ap_id(user))
        |> Kernel.put_in(["object", "cc"], [])

      conn =
        conn
        |> assign(:valid_signature, true)
        |> put_req_header("signature", "keyId=\"#{data["actor"]}/main-key\"")
        |> put_req_header("content-type", "application/activity+json")
        |> post("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/inbox", data)

      assert "ok" == json_response(conn, 200)
      ObanHelpers.perform(all_enqueued())
      assert Object.get_cached!(ap_id: data["id"])
    end

    test "it accepts messages with cc as string instead of array", %{conn: conn, data: data} do
      user = local_actor()
      subject = actor(local: false)

      data =
        data
        |> Map.put("actor", subject.data["id"])
        |> Map.put("to", [])
        |> Map.put("cc", ap_id(user))
        |> Kernel.put_in(["object", "to"], [])
        |> Kernel.put_in(["object", "cc"], ap_id(user))

      conn =
        conn
        |> assign(:valid_signature, true)
        |> put_req_header("signature", "keyId=\"#{data["actor"]}/main-key\"")
        |> put_req_header("content-type", "application/activity+json")
        |> post("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/inbox", data)

      assert "ok" == json_response(conn, 200)
      ObanHelpers.perform(all_enqueued())
      %Object{} = activity = Object.get_cached!(ap_id: data["id"])
      assert ap_id(user) in activity.data["to"] || ap_id(user) in activity.data["cc"]
    end

    test "it accepts messages with bcc as string instead of array", %{conn: conn, data: data} do
      subject = actor(local: false)
      user = local_actor()

      data =
        data
        |> Map.put("actor", subject.data["id"])
        |> Map.put("to", [])
        |> Map.put("cc", [])
        |> Map.put("bcc", ap_id(user))
        |> Kernel.put_in(["object", "to"], [])
        |> Kernel.put_in(["object", "cc"], [])
        |> Kernel.put_in(["object", "bcc"], ap_id(user))

      assert "ok" ==
               conn
               |> assign(:valid_signature, true)
               |> put_req_header("signature", "keyId=\"#{subject.data["id"]}/main-key\"")
               |> put_req_header("content-type", "application/activity+json")
               |> post("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/inbox", data)
               |> json_response(200)

      ObanHelpers.perform(all_enqueued())
      assert Object.get_cached!(ap_id: data["id"])
    end
  end

  describe "GET /users/:nickname/outbox" do
    test "it paginates correctly", %{conn: conn} do
      user = local_actor()
      conn = assign(conn, :user, user)
      outbox_endpoint = ap_id(user) <> "/outbox"

      _posts =
        for i <- 0..15 do
          insert(:note_activity, %{actor: user, status: "post #{i}"})
          |> debug
        end

      result =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get(outbox_endpoint <> "?page=true")
        |> json_response(200)

      result_ids = Enum.map(result["orderedItems"], fn x -> x["id"] end)
      assert length(result["orderedItems"]) == 10
      assert length(result_ids) == 10
      assert result["next"]
      debug(result["next"], "nexxxt")
      assert String.starts_with?(result["next"], outbox_endpoint)

      result_next =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get(result["next"])
        |> json_response(200)

      result_next_ids = Enum.map(result_next["orderedItems"], fn x -> x["id"] end)
      assert length(result_next["orderedItems"]) == 6
      assert length(result_next_ids) == 6
      refute Enum.find(result_next_ids, fn x -> x in result_ids end)
      refute Enum.find(result_ids, fn x -> x in result_next_ids end)
      assert String.starts_with?(result["id"], outbox_endpoint)

      result_next_again =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get(result_next["id"])
        |> json_response(200)

      assert result_next == result_next_again
    end

    test "it returns 200 even if there're no activities", %{conn: conn} do
      user = local_actor()
      outbox_endpoint = ap_id(user) <> "/outbox"

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("accept", "application/activity+json")
        |> get(outbox_endpoint)

      result = json_response(conn, 200)
      assert outbox_endpoint == result["id"]
    end

    # do we want this?
    # test "it returns a local note activity when authenticated as local user", %{conn: conn} do
    #   user = local_actor()
    #   reader = local_actor()
    #   note_activity = insert(:note_activity, %{actor: user, status: "mew mew", boundary: "local"})
    #   ap_id = note_activity.data["id"]

    #   resp =
    #     conn
    #     |> assign(:current_user, reader)
    #     |> put_req_header("accept", "application/activity+json")
    #     |> get("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/outbox?page=true")
    #     |> json_response(200)

    #   assert %{"orderedItems" => [%{"id" => ^ap_id}]} = resp
    # end

    test "it does not return a local-only note activity when unauthenticated", %{conn: conn} do
      user = local_actor()
      _note_activity = local_note_activity(%{actor: user, status: "mew mew", boundary: "local"})

      resp =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/outbox?page=true")
        |> json_response(200)

      assert %{"orderedItems" => []} = resp
    end

    test "it returns a note activity in a collection", %{conn: conn} do
      actor = local_actor()
      status = "note activity in a collection"
      note_activity = local_note_activity(actor: actor, status: status)
      note_object = Object.normalize(note_activity, fetch: false)
      # |> debug("objjj")
      user = user_by_ap_id(actor)

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("accept", "application/activity+json")
        |> get("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/outbox?page=true")

      list = response(conn, 200)
      # |> debug("lissst")

      assert list =~ status
    end

    test "it returns an announce activity in a collection", %{conn: conn} do
      actor = local_actor()
      status = "announce activity about note in a collection"
      note = insert(:note, status: status)
      announce_activity = insert(:announce_activity, actor: actor, note_activity: note)
      user = user_by_ap_id(actor)

      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("accept", "application/activity+json")
        |> get("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/outbox?page=true")

      assert response(conn, 200) =~ status
    end

    @tag :todo
    test "It returns poll Answers when authenticated", %{conn: conn} do
      poller = local_actor()
      voter = local_actor()

      {:ok, activity} =
        insert(:note_activity, %{
          actor: poller,
          status: "suya...",
          poll: %{options: ["suya", "suya.", "suya.."], expires_in: 10}
        })

      assert question = Object.normalize(activity, fetch: false)

      {:ok, [activity], _object} = CommonAPI.vote(voter, question, [1])

      assert outbox_get =
               conn
               |> assign(:current_user, voter)
               |> put_req_header("accept", "application/activity+json")
               |> get(ap_id(voter) <> "/outbox?page=true")
               |> json_response(200)

      assert [answer_outbox] = outbox_get["orderedItems"]
      assert answer_outbox["id"] == activity.data["id"]
    end
  end

  describe "/users/:nickname/followers" do
    test "it returns the followers in a collection", %{conn: conn} do
      user = local_actor()
      user_two = local_actor()
      follow(user, user_two)

      result =
        conn
        |> assign(:current_user, user_two)
        |> get("#{Utils.ap_base_url()}/actors/#{user_two |> nickname()}/followers")
        |> json_response(200)

      assert result["first"]["orderedItems"] == [ap_id(user)]
    end

    @tag :todo
    test "it returns a uri if the user has 'hide_followers' set", %{conn: conn} do
      user = local_actor()
      user_two = local_actor(hide_followers: true)
      follow(user, user_two)

      result =
        conn
        |> assign(:current_user, user)
        |> get("#{Utils.ap_base_url()}/actors/#{user_two |> nickname()}/followers")
        |> json_response(200)

      assert is_binary(result["first"])
    end

    @tag :todo
    test "it returns a 403 error on pages, if the user has 'hide_followers' set and the request is from another user",
         %{conn: conn} do
      user = local_actor()
      other_user = local_actor(hide_followers: true)

      result =
        conn
        |> assign(:current_user, user)
        |> get("#{Utils.ap_base_url()}/actors/#{other_user |> nickname()}/followers?page=1")

      assert result.status == 403
      assert result.resp_body == ""
    end

    @tag :todo
    test "it renders the page, if the user has 'hide_followers' set and the request is authenticated with the same user",
         %{conn: conn} do
      user = local_actor(hide_followers: true)
      other_user = local_actor()
      {:ok, _activity} = follow(other_user, user)

      result =
        conn
        |> assign(:current_user, user)
        |> get("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/followers?page=1")
        |> json_response(200)

      assert result["totalItems"] == 1
      assert result["orderedItems"] == [ap_id(other_user)]
    end

    test "it works for more than 10 users", %{conn: conn} do
      user = local_actor()

      Enum.each(1..15, fn _ ->
        other_user = local_actor()
        follow(other_user, user)
      end)

      result =
        conn
        |> assign(:current_user, user)
        |> get("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/followers")
        |> json_response(200)

      assert length(result["first"]["orderedItems"]) == 10
      assert result["first"]["totalItems"] == 15
      assert result["totalItems"] == 15

      result =
        conn
        |> assign(:current_user, user)
        |> get("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/followers?page=2")
        |> json_response(200)

      assert length(result["orderedItems"]) == 5
      assert result["totalItems"] == 15
    end

    test "does not require authentication", %{conn: conn} do
      user = local_actor()

      conn
      |> get("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/followers")
      |> json_response(200)
    end
  end

  describe "/users/:nickname/following" do
    test "it returns the following in a collection", %{conn: conn} do
      user = local_actor()
      user_two = local_actor()
      follow(user, user_two)

      result =
        conn
        |> assign(:current_user, user)
        |> get("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/following")
        |> json_response(200)

      assert result["first"]["orderedItems"] == [ap_id(user_two)]
    end

    @tag :todo
    test "it returns a uri if the user has 'hide_follows' set", %{conn: conn} do
      user = local_actor()
      user_two = local_actor(hide_follows: true)
      follow(user, user_two)

      result =
        conn
        |> assign(:current_user, user)
        |> get("#{Utils.ap_base_url()}/actors/#{user_two |> nickname()}/following")
        |> json_response(200)

      assert is_binary(result["first"])
    end

    @tag :todo
    test "it returns a 403 error on pages, if the user has 'hide_follows' set and the request is from another user",
         %{conn: conn} do
      user = local_actor()
      user_two = local_actor(hide_follows: true)

      result =
        conn
        |> assign(:current_user, user)
        |> get("#{Utils.ap_base_url()}/actors/#{user_two |> nickname()}/following?page=1")

      assert result.status == 403
      assert result.resp_body == ""
    end

    @tag :todo
    test "it renders the page, if the user has 'hide_follows' set and the request is authenticated with the same user",
         %{conn: conn} do
      user = local_actor(hide_follows: true)
      other_user = local_actor()
      {:ok, _activity} = follow(user, other_user)

      result =
        conn
        |> assign(:current_user, user)
        |> get("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/following?page=1")
        |> json_response(200)

      assert result["totalItems"] == 1
      assert result["orderedItems"] == [ap_id(other_user)]
    end

    test "it works for more than 10 users", %{conn: conn} do
      user = local_actor()
      local_user = user_by_ap_id(user)

      Enum.each(1..15, fn _ ->
        other_user = local_actor()
        follow(local_user, other_user)
      end)

      result =
        conn
        |> assign(:current_user, user)
        |> get("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/following")
        |> json_response(200)
        |> debug("jsonresp")

      assert result["first"]["totalItems"] == 15
      assert length(result["first"]["orderedItems"]) == 10
      assert result["totalItems"] == 15

      result =
        conn
        |> assign(:current_user, user)
        |> get("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/following?page=2")
        |> json_response(200)

      assert length(result["orderedItems"]) == 5
      assert result["totalItems"] == 15
    end

    test "does not require authentication", %{conn: conn} do
      user = local_actor()

      conn
      |> get("#{Utils.ap_base_url()}/actors/#{user |> nickname()}/following")
      |> json_response(200)
    end
  end
end
