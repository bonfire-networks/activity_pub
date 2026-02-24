# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.DigestPlugTest do
  @moduledoc "Tests for DigestPlug: legacy Digest (RFC 3230) and Content-Digest (RFC 9530)"

  use ActivityPub.Web.ConnCase

  alias ActivityPub.Web.Plugs.DigestPlug

  describe "legacy Digest header (draft-cavage)" do
    test "computes SHA-256 digest and assigns it" do
      body = ~s[{"type":"Create"}]

      conn =
        build_conn(:post, "/pub/shared_inbox", body)
        |> Plug.Conn.put_req_header("digest", "SHA-256=placeholder")
        |> Plug.Conn.put_req_header("content-type", "application/activity+json")

      {:ok, _body, conn} = DigestPlug.read_body(conn, [])

      expected = "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, body))
      assert conn.assigns[:digest] == expected
    end

    test "does not assign digest when header is absent" do
      body = ~s[{"type":"Create"}]

      conn =
        build_conn(:post, "/pub/shared_inbox", body)
        |> Plug.Conn.put_req_header("content-type", "application/activity+json")

      {:ok, _body, conn} = DigestPlug.read_body(conn, [])

      refute Map.has_key?(conn.assigns, :digest)
    end
  end

  describe "Content-Digest header (RFC 9530)" do
    test "computes sha-256 content-digest and assigns it in RFC 9530 format" do
      body = ~s[{"type":"Create"}]

      conn =
        build_conn(:post, "/pub/shared_inbox", body)
        |> Plug.Conn.put_req_header("content-digest", "sha-256=:placeholder:")
        |> Plug.Conn.put_req_header("content-type", "application/activity+json")

      {:ok, _body, conn} = DigestPlug.read_body(conn, [])

      expected = "sha-256=:" <> Base.encode64(:crypto.hash(:sha256, body)) <> ":"
      assert conn.assigns[:content_digest] == expected
    end

    test "does not assign content_digest when header is absent" do
      body = ~s[{"type":"Create"}]

      conn =
        build_conn(:post, "/pub/shared_inbox", body)
        |> Plug.Conn.put_req_header("content-type", "application/activity+json")

      {:ok, _body, conn} = DigestPlug.read_body(conn, [])

      refute Map.has_key?(conn.assigns, :content_digest)
    end

    test "both digest and content-digest can be computed simultaneously" do
      body = ~s[{"type":"Create"}]

      conn =
        build_conn(:post, "/pub/shared_inbox", body)
        |> Plug.Conn.put_req_header("digest", "SHA-256=placeholder")
        |> Plug.Conn.put_req_header("content-digest", "sha-256=:placeholder:")
        |> Plug.Conn.put_req_header("content-type", "application/activity+json")

      {:ok, _body, conn} = DigestPlug.read_body(conn, [])

      expected_legacy = "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, body))
      expected_rfc9530 = "sha-256=:" <> Base.encode64(:crypto.hash(:sha256, body)) <> ":"

      assert conn.assigns[:digest] == expected_legacy
      assert conn.assigns[:content_digest] == expected_rfc9530
    end
  end
end
