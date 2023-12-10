defmodule ActivityPub.Web.Plugs.HTTPSignaturePlugTest do
  use ActivityPub.Web.ConnCase

  alias ActivityPub.Config
  alias ActivityPub.Web.Plugs.HTTPSignaturePlug
  alias ActivityPub.Web.Plugs.EnsureHTTPSignaturePlug
  alias ActivityPub.Federator.Fetcher

  import Plug.Conn
  import Phoenix.Controller, only: [put_format: 2]
  import Mock
  import Tesla.Mock

  # setup do
  #   mock(fn env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env]) end)
  #   :ok
  # end

  setup_with_mocks([
    {HTTPSignatures, [],
     [
       signature_for_conn: fn _ ->
         %{"keyId" => "https://mastodon.local/users/admin#main-key"}
       end,
       validate_conn: fn conn ->
         Map.get(conn.assigns, :valid_signature, true)
       end
     ]}
  ]) do
    mock(fn env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env]) end)
    :ok
  end

  test "it call HTTPSignatures to check validity if the actor signed it" do
    params = %{"actor" => "https://mastodon.local/users/admin"}
    conn = build_conn(:post, "/doesntmattter", params)

    with_mock HTTPSignatures, validate_conn: fn _ -> true end do
      conn =
        conn
        |> put_req_header(
          "signature",
          "keyId=\"https://mastodon.local/users/admin#main-key"
        )
        |> put_format("activity+json")
        |> HTTPSignaturePlug.call(%{})
        |> EnsureHTTPSignaturePlug.call(%{})

      assert conn.assigns.valid_signature == true
      assert conn.halted == false
      assert called(HTTPSignatures.validate_conn(:_))
    end
  end

  describe "requires a signature when `reject_unsigned` is enabled" do
    setup do
      clear_config([:activity_pub, :reject_unsigned], true)

      params = %{"actor" => "https://mastodon.local/users/admin"}

      conn = build_conn(:get, "/doesntmattter", params) |> put_format("activity+json")

      [conn: conn]
    end

    test_with_mock "and signature is present and incorrect", %{conn: conn}, HTTPSignatures, [],
      validate_conn: fn conn ->
        Map.get(conn.assigns, :valid_signature, false)
      end do
      conn =
        conn
        # |> assign(:valid_signature, false)
        |> put_req_header(
          "signature",
          "keyId=\"https://mastodon.local/users/admin#main-key"
        )
        |> HTTPSignaturePlug.call(%{})

      assert conn.assigns.valid_signature == false
      assert called(HTTPSignatures.validate_conn(:_))
    end

    test "and signature is correct", %{conn: conn} do
      conn =
        conn
        |> put_req_header(
          "signature",
          "keyId=\"https://mastodon.local/users/admin#main-key"
        )
        |> HTTPSignaturePlug.call(%{})

      assert conn.assigns.valid_signature == true
      assert called(HTTPSignatures.validate_conn(:_))
    end

    test "and halts the connection when `signature` header is not present", %{conn: conn} do
      conn = HTTPSignaturePlug.call(conn, %{})
      assert conn.assigns[:valid_signature] == nil
    end

    test "and signature has been set as invalid", %{conn: conn} do
      conn =
        conn
        |> assign(:valid_signature, false)
        |> put_req_header(
          "signature",
          "keyId=\"https://mastodon.local/users/admin#main-key"
        )
        |> HTTPSignaturePlug.call(%{})
        |> EnsureHTTPSignaturePlug.call(%{})

      assert conn.halted == true
      assert conn.status == 401
      assert conn.state == :sent
      assert conn.resp_body =~ "Please include an HTTP Signature"
    end

    test "does nothing for non-ActivityPub content types", %{conn: conn} do
      conn =
        conn
        |> put_format("html")
        |> HTTPSignaturePlug.call(%{})
        |> EnsureHTTPSignaturePlug.call(%{})

      assert conn.halted == false
    end
  end

  test "does nothing on invalid signature when `reject_unsigned` is disabled" do
    clear_config([:activity_pub, :reject_unsigned], false)

    conn =
      build_conn(:get, "/doesntmatter")
      |> put_format("activity+json")
      |> assign(:valid_signature, false)
      |> HTTPSignaturePlug.call(%{})
      |> EnsureHTTPSignaturePlug.call(%{})

    assert conn.halted == false
  end
end
