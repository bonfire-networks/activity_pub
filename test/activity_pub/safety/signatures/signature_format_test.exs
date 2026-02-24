# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Safety.Signatures.SignatureFormatTest do
  @moduledoc "Tests for signature format cache, detection, and determination"

  use ActivityPub.Web.ConnCase

  alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter
  alias ActivityPub.Web.Plugs.HTTPSignaturePlug

  import Plug.Conn
  import Phoenix.Controller, only: [put_format: 2]
  import Mock
  import Tesla.Mock

  setup do
    mock(fn env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env]) end)
    :ok
  end

  describe "signature format cache" do
    test "get/put round-trip for :rfc9421" do
      SignaturesAdapter.put_signature_format("rfc.example.com", :rfc9421)
      assert SignaturesAdapter.get_signature_format("rfc.example.com") == :rfc9421
    end

    test "get/put round-trip for :cavage" do
      SignaturesAdapter.put_signature_format("cavage.example.com", :cavage)
      assert SignaturesAdapter.get_signature_format("cavage.example.com") == :cavage
    end

    test "returns nil for unknown host" do
      host = "unknown-#{System.unique_integer([:positive])}.example.com"
      assert SignaturesAdapter.get_signature_format(host) == nil
    end

    test "returns nil for non-binary host" do
      assert SignaturesAdapter.get_signature_format(nil) == nil
    end
  end

  describe "determine_signature_format" do
    test "returns cached format when available" do
      host = "cached-#{System.unique_integer([:positive])}.example.com"
      SignaturesAdapter.put_signature_format(host, :rfc9421)
      assert SignaturesAdapter.determine_signature_format(host) == :rfc9421
    end

    test "checks FEP-844e when cache is empty and caches result" do
      host = "fep844e-#{System.unique_integer([:positive])}.example.com"

      actor_data = %{
        "generator" => %{
          "implements" => [%{"id" => "https://datatracker.ietf.org/doc/html/rfc9421"}]
        }
      }

      assert SignaturesAdapter.determine_signature_format(host, actor_data) == :rfc9421
      # should have been cached
      assert SignaturesAdapter.get_signature_format(host) == :rfc9421
    end

    test "defaults to :cavage when nothing found" do
      host = "unknown-#{System.unique_integer([:positive])}.example.com"
      assert SignaturesAdapter.determine_signature_format(host) == :cavage
    end

    test "cache takes priority over FEP-844e" do
      host = "priority-#{System.unique_integer([:positive])}.example.com"
      SignaturesAdapter.put_signature_format(host, :cavage)

      actor_data = %{
        "generator" => %{
          "implements" => [%{"id" => "https://datatracker.ietf.org/doc/html/rfc9421"}]
        }
      }

      assert SignaturesAdapter.determine_signature_format(host, actor_data) == :cavage
    end
  end

  describe "HTTPSignaturePlug passive format caching" do
    test "caches :rfc9421 when validation succeeds with signature-input header" do
      host = "passive-rfc-#{System.unique_integer([:positive])}.example.com"
      params = %{"actor" => "https://#{host}/users/admin"}

      with_mock HTTPSignatures,
        validate: fn _conn, _opts -> host end do
        build_conn(:post, "/pub/shared_inbox", params)
        |> put_req_header(
          "signature-input",
          ~s[sig1=("@method");created=123;keyid="https://#{host}/users/admin#main-key"]
        )
        |> put_req_header("signature", "sig1=:dGVzdA==:")
        |> put_format("activity+json")
        |> HTTPSignaturePlug.call(%{})
      end

      assert SignaturesAdapter.get_signature_format(host) == :rfc9421
    end

    test "caches :cavage when validation succeeds with only signature header" do
      host = "passive-cavage-#{System.unique_integer([:positive])}.example.com"
      params = %{"actor" => "https://#{host}/users/admin"}

      with_mock HTTPSignatures,
        validate: fn _conn, _opts -> host end do
        build_conn(:post, "/pub/shared_inbox", params)
        |> put_req_header(
          "signature",
          ~s[keyId="https://#{host}/users/admin#main-key",algorithm="rsa-sha256",headers="(request-target) host date",signature="abc123=="]
        )
        |> put_format("activity+json")
        |> HTTPSignaturePlug.call(%{})
      end

      assert SignaturesAdapter.get_signature_format(host) == :cavage
    end

    test "does not cache when validation fails" do
      host = "passive-fail-#{System.unique_integer([:positive])}.example.com"
      params = %{"actor" => "https://#{host}/users/admin"}

      with_mock HTTPSignatures,
        validate: fn _conn, _opts -> false end do
        build_conn(:post, "/pub/shared_inbox", params)
        |> put_req_header(
          "signature-input",
          ~s[sig1=("@method");created=123;keyid="https://#{host}/users/admin#main-key"]
        )
        |> put_req_header("signature", "sig1=:dGVzdA==:")
        |> put_format("activity+json")
        |> HTTPSignaturePlug.call(%{})
      end

      assert SignaturesAdapter.get_signature_format(host) == nil
    end
  end

  describe "maybe_cache_accept_signature" do
    test "caches :rfc9421 when Accept-Signature header is present in response struct" do
      host = "accept-sig-#{System.unique_integer([:positive])}.example.com"

      response = %{headers: [{"Accept-Signature", "sig1=()"}]}
      SignaturesAdapter.maybe_cache_accept_signature(host, response)

      assert SignaturesAdapter.get_signature_format(host) == :rfc9421
    end

    test "caches :rfc9421 from plain headers list" do
      host = "accept-sig-list-#{System.unique_integer([:positive])}.example.com"

      headers = [{"accept-signature", "sig1=()"}, {"content-type", "application/json"}]
      SignaturesAdapter.maybe_cache_accept_signature(host, headers)

      assert SignaturesAdapter.get_signature_format(host) == :rfc9421
    end

    test "caches :rfc9421 with URI struct as host" do
      host = "accept-sig-uri-#{System.unique_integer([:positive])}.example.com"
      uri = %URI{host: host, scheme: "https"}

      headers = [{"Accept-Signature", "sig1=()"}]
      SignaturesAdapter.maybe_cache_accept_signature(uri, headers)

      assert SignaturesAdapter.get_signature_format(host) == :rfc9421
    end

    test "caches :rfc9421 with URL string as host" do
      host = "accept-sig-url-#{System.unique_integer([:positive])}.example.com"

      headers = [{"Accept-Signature", "sig1=()"}]
      SignaturesAdapter.maybe_cache_accept_signature("https://#{host}/inbox", headers)

      assert SignaturesAdapter.get_signature_format(host) == :rfc9421
    end

    test "is case-insensitive for header name" do
      host = "accept-sig-case-#{System.unique_integer([:positive])}.example.com"

      headers = [{"ACCEPT-SIGNATURE", "sig1=()"}]
      SignaturesAdapter.maybe_cache_accept_signature(host, headers)

      assert SignaturesAdapter.get_signature_format(host) == :rfc9421
    end

    test "does not cache when Accept-Signature header is absent" do
      host = "no-accept-sig-#{System.unique_integer([:positive])}.example.com"

      headers = [{"content-type", "application/json"}]
      SignaturesAdapter.maybe_cache_accept_signature(host, headers)

      assert SignaturesAdapter.get_signature_format(host) == nil
    end

    test "handles nil response gracefully" do
      assert SignaturesAdapter.maybe_cache_accept_signature("example.com", nil) == :ok
    end
  end

  describe "full determination chain" do
    test "cache miss → FEP-844e miss → stored service actor hit" do
      host = "chain-#{System.unique_integer([:positive])}.example.com"
      service_actor_uri = "https://#{host}/actor"

      # No cache, no FEP-844e data passed — but store service actor in DB
      ActivityPub.Instances.Instance.set_service_actor_uri(host, service_actor_uri)

      actor_data = %{
        "id" => service_actor_uri,
        "generator" => %{
          "implements" => [%{"id" => "https://datatracker.ietf.org/doc/html/rfc9421"}]
        }
      }

      with_mock ActivityPub.Actor, [:passthrough],
        get_cached: fn
          [ap_id: ^service_actor_uri] ->
            {:ok, %ActivityPub.Actor{data: actor_data}}

          args ->
            :meck.passthrough([args])
        end do
        # Call without actor_data (simulates unknown recipient)
        assert SignaturesAdapter.determine_signature_format(host) == :rfc9421
        # Verify it was cached for future calls
        assert SignaturesAdapter.get_signature_format(host) == :rfc9421
      end
    end

    test "cache miss → FEP-844e miss → service actor miss → cavage fallback" do
      host = "chain-cavage-#{System.unique_integer([:positive])}.example.com"

      # No cache, no actor data, no stored service actor
      assert SignaturesAdapter.determine_signature_format(host) == :cavage
      # Cavage is NOT cached (it's the default)
      assert SignaturesAdapter.get_signature_format(host) == nil
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
