defmodule ActivityPub.Web.Plugs.SignedFetchGateTest do
  @moduledoc """
  Who may fetch our objects without a signature, and what a refused fetch answers.

  An adapter can require signed fetches even when `reject_unsigned` is off (Bonfire does so in archipelago mode). The service actor stays fetchable unsigned, because other servers read its public key to verify the fetches we sign as it. A fetch signed by a blocked or non-allowlisted server gets a real error status rather than a 200.
  """
  use ActivityPub.Web.ConnCase, async: false

  alias ActivityPub.Web.Plugs.EnsureHTTPSignaturePlug
  alias ActivityPub.Web.Plugs.HTTPSignaturePlug

  import Plug.Conn
  import Phoenix.Controller, only: [put_format: 2]

  defp through_signature_plugs(conn) do
    conn
    |> put_format("activity+json")
    |> HTTPSignaturePlug.call(%{})
    |> EnsureHTTPSignaturePlug.call(%{})
  end

  describe "when the adapter requires signed fetches" do
    setup do
      clear_config([:reject_unsigned], false)
      clear_config([:test_require_signed_fetch], true)
      :ok
    end

    test "an unsigned GET is refused even though `reject_unsigned` is off" do
      conn = build_conn(:get, "#{ActivityPub.Utils.ap_base_url()}/objects/abc") |> through_signature_plugs()

      assert conn.halted
      assert conn.status == 401
    end

    test "the service actor can still be fetched unsigned" do
      path = URI.parse(ActivityPub.Utils.service_actor!().ap_id).path
      conn = build_conn(:get, path) |> through_signature_plugs()

      refute conn.halted
    end

    test "another actor cannot be fetched unsigned (the service actor exception is that narrow)" do
      conn = build_conn(:get, "#{ActivityPub.Utils.ap_base_url()}/actors/somebody_else") |> through_signature_plugs()

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "when neither `reject_unsigned` nor the adapter requires signed fetches" do
    setup do
      clear_config([:reject_unsigned], false)
      clear_config([:test_require_signed_fetch], false)
      :ok
    end

    test "control: an unsigned GET goes through" do
      conn = build_conn(:get, "#{ActivityPub.Utils.ap_base_url()}/objects/abc") |> through_signature_plugs()

      refute conn.halted
    end
  end

  describe "a signature that maps to a blocked or non-allowlisted server" do
    test "answers 403 to a GET" do
      conn =
        build_conn(:get, "#{ActivityPub.Utils.ap_base_url()}/objects/abc")
        |> assign(:valid_signature, nil)
        |> through_signature_plugs()

      assert conn.halted
      assert conn.status == 403
    end

    test "still answers a POST with a quiet 200, so a blocked sender cannot tell" do
      conn =
        build_conn(:post, "#{ActivityPub.Utils.ap_base_url()}/shared_inbox", %{})
        |> assign(:valid_signature, nil)
        |> through_signature_plugs()

      assert conn.halted
      assert conn.status == 200
      assert conn.resp_body == "OK"
    end
  end
end
