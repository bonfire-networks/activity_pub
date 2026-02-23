# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Safety.Signatures.RFC9421Test do
  @moduledoc "Tests for RFC 9421 signature handling in ActivityPub plugs"

  use ActivityPub.Web.ConnCase

  alias ActivityPub.Web.Plugs.HTTPSignaturePlug
  alias ActivityPub.Web.Plugs.EnsureHTTPSignaturePlug

  import Plug.Conn
  import Phoenix.Controller, only: [put_format: 2]
  import Mock
  import Tesla.Mock

  setup do
    mock(fn env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env]) end)
    :ok
  end

  describe "HTTPSignaturePlug with RFC 9421 headers" do
    test "it detects signature-input header and sets derived components" do
      params = %{"actor" => "https://mastodon.local/users/admin"}

      with_mock HTTPSignatures,
        validate_cached: fn conn ->
          # Verify derived components were set on the conn
          headers = Enum.into(conn.req_headers, %{})

          assert headers["@method"] == "POST"
          assert headers["@path"]
          assert headers["@authority"]
          assert headers["@scheme"]

          true
        end do
        conn =
          build_conn(:post, "/pub/shared_inbox", params)
          |> put_req_header(
            "signature-input",
            ~s[sig1=("@method" "@authority" "content-type");created=1618884475;keyid="https://mastodon.local/users/admin#main-key"]
          )
          |> put_req_header(
            "signature",
            "sig1=:dGVzdA==:"
          )
          |> put_format("activity+json")
          |> HTTPSignaturePlug.call(%{})

        assert conn.assigns.valid_signature == true
        assert called(HTTPSignatures.validate_cached(:_))
      end
    end

    test "it falls back to draft-cavage when only signature header is present" do
      params = %{"actor" => "https://mastodon.local/users/admin"}

      with_mock HTTPSignatures,
        validate_cached: fn conn ->
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

    test "it sets valid_signature to false when RFC 9421 validation fails" do
      params = %{"actor" => "https://mastodon.local/users/admin"}

      with_mock HTTPSignatures,
        validate_cached: fn _conn -> false end do
        conn =
          build_conn(:post, "/pub/shared_inbox", params)
          |> put_req_header(
            "signature-input",
            ~s[sig1=("@method");created=123;keyid="https://mastodon.local/users/admin#main-key"]
          )
          |> put_req_header("signature", "sig1=:dGVzdA==:")
          |> put_format("activity+json")
          |> HTTPSignaturePlug.call(%{})

        assert conn.assigns.valid_signature == false
      end
    end

    test "EnsureHTTPSignaturePlug halts on invalid RFC 9421 signature when reject_unsigned is enabled" do
      clear_config([:activity_pub, :reject_unsigned], true)

      conn =
        build_conn(:get, "/pub/shared_inbox")
        |> put_format("activity+json")
        |> assign(:valid_signature, false)
        |> put_req_header(
          "signature-input",
          ~s[sig1=("@method");created=123;keyid="test"]
        )
        |> EnsureHTTPSignaturePlug.call(%{})

      assert conn.halted == true
      assert conn.status == 401
    end
  end

  describe "HTTPSignaturePlug with Content-Digest" do
    test "it passes content-digest to validation headers for RFC 9421" do
      params = %{"actor" => "https://mastodon.local/users/admin"}

      with_mock HTTPSignatures,
        validate_cached: fn conn ->
          headers = Enum.into(conn.req_headers, %{})
          # Content-Digest should be set from the conn assign
          assert headers["content-digest"] =~ "sha-256="
          true
        end do
        conn =
          build_conn(:post, "/pub/shared_inbox", params)
          |> assign(:content_digest, "sha-256=:abc123=:")
          |> put_req_header(
            "signature-input",
            ~s[sig1=("@method" "content-digest");created=123;keyid="https://mastodon.local/users/admin#main-key"]
          )
          |> put_req_header("signature", "sig1=:dGVzdA==:")
          |> put_format("activity+json")
          |> HTTPSignaturePlug.call(%{})

        assert conn.assigns.valid_signature == true
      end
    end

    test "it passes legacy digest for draft-cavage" do
      params = %{"actor" => "https://mastodon.local/users/admin"}

      with_mock HTTPSignatures,
        validate_cached: fn conn ->
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

  describe "format detection via HTTPSignatures.extract_signature" do
    test "it detects RFC 9421 format from conn req_headers" do
      raw_params =
        ~s[("@method" "@authority");created=123;keyid="https://example.com/actor#main-key"]

      dummy_sig = :crypto.strong_rand_bytes(32) |> Base.encode64()

      conn = %{
        req_headers: [
          {"signature-input", "sig1=" <> raw_params},
          {"signature", "sig1=:#{dummy_sig}:"},
          {"host", "example.com"}
        ]
      }

      result = HTTPSignatures.extract_signature(conn)
      assert result["format"] == :rfc9421
      assert result["keyId"] == "https://example.com/actor#main-key"
      assert result["headers"] == ["@method", "@authority"]
    end

    test "it detects draft-cavage format from conn req_headers" do
      conn = %{
        req_headers: [
          {"signature",
           ~s[keyId="https://example.com/actor#main-key",algorithm="rsa-sha256",headers="(request-target) host date",signature="abc123=="]},
          {"host", "example.com"}
        ]
      }

      result = HTTPSignatures.extract_signature(conn)
      assert result["keyId"] == "https://example.com/actor#main-key"
      assert result["algorithm"] == "rsa-sha256"
      refute Map.has_key?(result, "format")
    end
  end
end
