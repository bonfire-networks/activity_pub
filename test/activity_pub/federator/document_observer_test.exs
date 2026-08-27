defmodule ActivityPub.Web.DocumentObserverTest do
  @moduledoc """
  The `:document_observer` seam: a hook the host app can configure to see every document a remote sends us, exactly as it arrived.

  It exists because nothing downstream can serve as a source of interop fixtures. `ap_object.data` and `actor.data` are post-transformer, so a test built from them only asserts that we produce what we produced, and documents we REJECT are never stored at all, those being the ones worth studying. So the observer runs before any normalisation or verification, on the raw document.
  """
  use ActivityPub.Web.ConnCase, async: false
  import ActivityPub.Factory
  import Tesla.Mock
  import Plug.Conn
  import Phoenix.ConnTest

  alias ActivityPub.Test.HttpRequestMock
  alias ActivityPub.Utils

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  setup do
    on_exit(fn -> Application.delete_env(:activity_pub, :document_observer) end)
    :ok
  end

  defp observe(fun) do
    Application.put_env(:activity_pub, :document_observer, fun)
  end

  defp observe_to_self do
    test_process = self()
    observe(fn document, context -> send(test_process, {:observed, document, context}) end)
  end

  defp incoming_activity do
    file("fixtures/mastodon/mastodon-post-activity.json")
    |> Jason.decode!()
    |> Map.put("actor", actor(local: false).data["id"])
  end

  defp post_inbox(conn, path, data) do
    conn
    |> assign(:valid_signature, true)
    |> put_req_header("signature", "keyId=\"https://mastodon.local/users/admin/main-key\"")
    |> put_req_header("content-type", "application/activity+json")
    |> post(path, data)
  end

  describe "inbox" do
    test "a configured function observes the activity as posted", %{conn: conn} do
      observe_to_self()

      data = incoming_activity()

      conn = post_inbox(conn, "#{Utils.ap_base_url()}/shared_inbox", data)
      assert json_response(conn, 200) in ["ok", "tbd"]

      assert_received {:observed, observed, context}
      assert observed["id"] == data["id"]
      assert observed["type"] == data["type"]
      assert observed["object"] == data["object"]

      assert context.source == :inbox

      assert context.headers["signature"] =~ "main-key",
             "the signature identifies who sent it, which is half of what a capture is for"
    end

    test "a configured {module, function} pair is called", %{conn: conn} do
      Application.put_env(:activity_pub, :document_observer_test_pid, self())
      on_exit(fn -> Application.delete_env(:activity_pub, :document_observer_test_pid) end)

      observe({__MODULE__, :observer_mfa})

      conn = post_inbox(conn, "#{Utils.ap_base_url()}/shared_inbox", incoming_activity())
      assert json_response(conn, 200) in ["ok", "tbd"]

      assert_received {:observed_mfa, type}
      assert type == "Create"
    end

    # The observed document has to be the AP document itself. Phoenix merges router path params into `params`, which is why the controller reads `conn.body_params`, a path `:id` once overwrote every incoming activity's own "id".
    test "observes the AP document, not Phoenix's merged params", %{conn: conn} do
      observe_to_self()

      data = incoming_activity()
      recipient = local_actor()

      conn = post_inbox(conn, "#{Utils.ap_base_url()}/actors/#{recipient.username}/inbox", data)

      assert json_response(conn, 200) in ["ok", "tbd"]

      assert_received {:observed, observed, _context}
      refute Map.has_key?(observed, "username")
      assert observed["id"] == data["id"]
    end

    @tag capture_log: true
    test "an observer that raises does not stop the activity being received", %{conn: conn} do
      observe(fn _document, _context -> raise "boom" end)

      conn = post_inbox(conn, "#{Utils.ap_base_url()}/shared_inbox", incoming_activity())

      assert json_response(conn, 200) in ["ok", "tbd"]
    end

    @tag capture_log: true
    test "a malformed observer config is warned about, not fatal", %{conn: conn} do
      observe("not callable")

      conn = post_inbox(conn, "#{Utils.ap_base_url()}/shared_inbox", incoming_activity())

      assert json_response(conn, 200) in ["ok", "tbd"]
    end

    test "no observer configured is the normal case", %{conn: conn} do
      Application.delete_env(:activity_pub, :document_observer)

      conn = post_inbox(conn, "#{Utils.ap_base_url()}/shared_inbox", incoming_activity())

      assert json_response(conn, 200) in ["ok", "tbd"]
    end
  end

  describe "fetch" do
    # Documents we PULL are wire-format too, and `actor.data` is just as post-transformer as `ap_object.data`, so fetches are observed at the same seam.
    test "observes a fetched document verbatim" do
      observe_to_self()

      id = "https://mocked.local/users/karen"

      assert {:ok, data} = ActivityPub.Federator.Fetcher.fetch_remote_object_from_id(id)

      # the mock answers unknown URLs with a 304 that yields `{:ok, <the id>}`, which would make the assertion above pass while never reaching the fetch path at all
      assert is_map(data), "expected a fetched document, got #{inspect(data)}"

      assert_received {:observed, observed, context}
      assert observed == data
      assert context.source == :fetch
      assert context.url == id
      assert context.status == 200
    end
  end

  def observer_mfa(document, _context) do
    Application.get_env(:activity_pub, :document_observer_test_pid)
    |> send({:observed_mfa, document["type"]})
  end
end
