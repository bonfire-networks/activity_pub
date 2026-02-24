# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Safety.Signatures.CavageTest do
  @moduledoc "Tests for draft-cavage HTTP signature handling"

  use ActivityPub.Web.ConnCase

  alias ActivityPub.Web.Plugs.HTTPSignaturePlug

  import Plug.Conn
  import Phoenix.Controller, only: [put_format: 2]
  import Mock
  import Tesla.Mock

  setup do
    mock(fn env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env]) end)
    :ok
  end

  describe "HTTPSignaturePlug with draft-cavage headers" do
    test "it falls back to draft-cavage when only signature header is present" do
      params = %{"actor" => "https://mastodon.local/users/admin"}

      with_mock HTTPSignatures,
        validate: fn conn, _opts ->
          # Should NOT have derived components set (draft-cavage path)
          headers = Enum.into(conn.req_headers, %{})
          refute headers["@method"]
          refute headers["@authority"]

          # Should have (request-target) set
          assert headers["(request-target)"]

          true
        end do
        conn =
          build_conn(:post, "/pub/shared_inbox", params)
          |> put_req_header(
            "signature",
            ~s[keyId="https://mastodon.local/users/admin#main-key",algorithm="rsa-sha256",headers="(request-target) host date",signature="abc123=="]
          )
          |> put_format("activity+json")
          |> HTTPSignaturePlug.call(%{})

        assert conn.assigns.valid_signature == true
      end
    end
  end

  describe "HTTPSignaturePlug with legacy Digest" do
    test "it passes legacy digest for draft-cavage" do
      params = %{"actor" => "https://mastodon.local/users/admin"}

      with_mock HTTPSignatures,
        validate: fn conn, _opts ->
          headers = Enum.into(conn.req_headers, %{})
          # Legacy digest should be set
          assert headers["digest"] =~ "SHA-256="
          true
        end do
        conn =
          build_conn(:post, "/pub/shared_inbox", params)
          |> assign(:digest, "SHA-256=abc123==")
          |> put_req_header(
            "signature",
            ~s[keyId="https://mastodon.local/users/admin#main-key",algorithm="rsa-sha256",headers="(request-target) host date digest",signature="abc=="]
          )
          |> put_format("activity+json")
          |> HTTPSignaturePlug.call(%{})

        assert conn.assigns.valid_signature == true
      end
    end
  end
end
