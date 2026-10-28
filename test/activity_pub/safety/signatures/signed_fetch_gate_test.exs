defmodule ActivityPub.Web.Plugs.SignedFetchGateTest do
  @moduledoc """
  Who may fetch our objects without a signature, and what a refused fetch answers.

  An adapter can require signed fetches even when `reject_unsigned` is off (Bonfire does so in archipelago mode). The service actor stays fetchable unsigned, because other servers read its public key to verify the fetches we sign as it. A fetch signed by a blocked or non-allowlisted server gets a real error status rather than a 200.

  The adapter is swapped for a stub that answers only what these plugs ask, so the tests do not depend on which host adapter is running.
  """
  use ActivityPub.Web.ConnCase, async: false

  alias ActivityPub.Web.Plugs.EnsureHTTPSignaturePlug
  alias ActivityPub.Web.Plugs.HTTPSignaturePlug

  import Plug.Conn
  import Phoenix.Controller, only: [put_format: 2]

  defmodule ServiceActor do
    # the little of an adapter these plugs need: where we are (for `ap_base_url`), and the service actor. The base URL is the one the real adapter gave before it was swapped out, since the lib's own endpoint is not running when this runs inside a host app
    def base_url, do: Process.get(:signed_fetch_gate_test_base_url)

    def get_or_create_service_actor do
      id = ActivityPub.Utils.ap_base_url() <> "/actors/service_actor"
      {:ok, %ActivityPub.Actor{id: "service_actor", local: true, ap_id: id, username: "service_actor", data: %{"id" => id}}}
    end
  end

  defmodule RequiresSignedFetch do
    defdelegate base_url, to: ServiceActor
    defdelegate get_or_create_service_actor, to: ServiceActor
    def require_signed_fetch?, do: true
  end

  defmodule DoesNotRequireSignedFetch do
    defdelegate base_url, to: ServiceActor
    defdelegate get_or_create_service_actor, to: ServiceActor
    def require_signed_fetch?, do: false
  end

  defp with_adapter(adapter) do
    Process.put(:signed_fetch_gate_test_base_url, ActivityPub.Federator.Adapter.base_url())
    previous = Application.get_env(:activity_pub, :adapter)
    Application.put_env(:activity_pub, :adapter, adapter)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:activity_pub, :adapter),
        else: Application.put_env(:activity_pub, :adapter, previous)
    end)
  end

  defp through_signature_plugs(conn) do
    conn
    |> put_format("activity+json")
    |> HTTPSignaturePlug.call(%{})
    |> EnsureHTTPSignaturePlug.call(%{})
  end

  defp ap_path(path), do: ActivityPub.Utils.ap_base_url() <> path

  describe "when the adapter requires signed fetches" do
    setup do
      clear_config([:reject_unsigned], false)
      with_adapter(RequiresSignedFetch)
      :ok
    end

    test "an unsigned GET is refused even though `reject_unsigned` is off" do
      conn = build_conn(:get, ap_path("/objects/abc")) |> through_signature_plugs()

      assert conn.halted
      assert conn.status == 401
    end

    test "the service actor can still be fetched unsigned" do
      path = URI.parse(ActivityPub.Utils.service_actor!().ap_id) |> Map.fetch!(:path)
      conn = build_conn(:get, path) |> through_signature_plugs()

      refute conn.halted
    end

    test "another actor cannot be fetched unsigned (the service actor exception is that narrow)" do
      conn = build_conn(:get, ap_path("/actors/somebody_else")) |> through_signature_plugs()

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "when neither `reject_unsigned` nor the adapter requires signed fetches" do
    setup do
      clear_config([:reject_unsigned], false)
      with_adapter(DoesNotRequireSignedFetch)
      :ok
    end

    test "control: an unsigned GET goes through" do
      conn = build_conn(:get, ap_path("/objects/abc")) |> through_signature_plugs()

      refute conn.halted
    end
  end

  describe "a signature that maps to a blocked or non-allowlisted server" do
    test "answers 403 to a GET" do
      conn =
        build_conn(:get, ap_path("/objects/abc"))
        |> assign(:valid_signature, nil)
        |> through_signature_plugs()

      assert conn.halted
      assert conn.status == 403
    end

    test "still answers a POST with a quiet 200, so a blocked sender cannot tell" do
      conn =
        build_conn(:post, ap_path("/shared_inbox"), %{})
        |> assign(:valid_signature, nil)
        |> through_signature_plugs()

      assert conn.halted
      assert conn.status == 200
      assert conn.resp_body == "OK"
    end
  end
end
