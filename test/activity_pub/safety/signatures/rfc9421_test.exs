# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Safety.Signatures.RFC9421Test do
  @moduledoc "Tests for RFC 9421 signature signing, verification, and plug behavior"

  use ActivityPub.Web.ConnCase

  import ActivityPub.Factory

  alias ActivityPub.Safety.Keys
  alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter
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

  describe "Keys.sign/3 with RFC 9421" do
    test "produces a {sig_input, sig} tuple for POST" do
      actor = local_actor()
      {:ok, ap_actor} = ActivityPub.Actor.get_cached(username: actor.username)

      {:ok, {sig_input, sig}} =
        Keys.sign(
          ap_actor,
          %{
            "@method" => "POST",
            "@target-uri" => "https://example.com/inbox",
            "content-digest" => "sha-256=:dGVzdA==:"
          },
          format: :rfc9421,
          components: ["@method", "@target-uri", "content-digest"]
        )

      assert is_binary(sig_input)
      assert is_binary(sig)
      assert String.starts_with?(sig_input, "sig1=")
      assert String.starts_with?(sig, "sig1=:")
      assert sig_input =~ "\"@method\""
      assert sig_input =~ "\"@target-uri\""
      assert sig_input =~ "\"content-digest\""
    end

    test "produces a {sig_input, sig} tuple for GET" do
      actor = local_actor()
      {:ok, ap_actor} = ActivityPub.Actor.get_cached(username: actor.username)

      {:ok, {sig_input, sig}} =
        Keys.sign(
          ap_actor,
          %{
            "@method" => "GET",
            "@target-uri" => "https://example.com/users/alice"
          },
          format: :rfc9421,
          components: ["@method", "@target-uri"]
        )

      assert sig_input =~ "\"@method\""
      assert sig_input =~ "\"@target-uri\""
      assert String.starts_with?(sig, "sig1=:")
    end

    test "includes created parameter" do
      actor = local_actor()
      {:ok, ap_actor} = ActivityPub.Actor.get_cached(username: actor.username)

      {:ok, {sig_input, _sig}} =
        Keys.sign(
          ap_actor,
          %{"@method" => "POST", "@target-uri" => "https://example.com/inbox"},
          format: :rfc9421,
          components: ["@method", "@target-uri"]
        )

      assert sig_input =~ ";created="
    end

    test "includes keyid from actor" do
      actor = local_actor()
      {:ok, ap_actor} = ActivityPub.Actor.get_cached(username: actor.username)

      {:ok, {sig_input, _sig}} =
        Keys.sign(
          ap_actor,
          %{"@method" => "GET", "@target-uri" => "https://example.com/users/alice"},
          format: :rfc9421,
          components: ["@method", "@target-uri"]
        )

      assert sig_input =~ "keyid=\"#{ap_actor.data["id"]}#main-key\""
    end
  end

  describe "supports_rfc9421? (FEP-844e)" do
    test "detects implements list with rfc9421 id" do
      actor_data = %{
        "generator" => %{
          "implements" => [
            %{"id" => "https://datatracker.ietf.org/doc/html/rfc9421"}
          ]
        }
      }

      assert SignaturesAdapter.supports_rfc9421?(actor_data)
    end

    test "detects single implements map with rfc9421 href" do
      actor_data = %{
        "generator" => %{
          "implements" => %{"href" => "https://datatracker.ietf.org/doc/html/rfc9421"}
        }
      }

      assert SignaturesAdapter.supports_rfc9421?(actor_data)
    end

    test "detects implements as string URI list" do
      actor_data = %{
        "generator" => %{
          "implements" => ["https://datatracker.ietf.org/doc/html/rfc9421"]
        }
      }

      assert SignaturesAdapter.supports_rfc9421?(actor_data)
    end

    test "returns false for missing implements" do
      refute SignaturesAdapter.supports_rfc9421?(%{"generator" => %{}})
    end

    test "returns false for non-rfc9421 implements" do
      actor_data = %{
        "generator" => %{
          "implements" => [%{"id" => "https://example.com/other-spec"}]
        }
      }

      refute SignaturesAdapter.supports_rfc9421?(actor_data)
    end

    test "returns false for nil" do
      refute SignaturesAdapter.supports_rfc9421?(nil)
    end
  end

  describe "HTTPSignaturePlug with RFC 9421 headers" do
    test "it detects signature-input header and sets derived components" do
      params = %{"actor" => "https://mastodon.local/users/admin"}

      with_mock HTTPSignatures,
        validate: fn conn, _opts ->
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
        assert called(HTTPSignatures.validate(:_, :_))
      end
    end

    test "it sets valid_signature to false when RFC 9421 validation fails" do
      params = %{"actor" => "https://mastodon.local/users/admin"}

      with_mock HTTPSignatures,
        validate: fn _conn, _opts -> false end do
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
        validate: fn conn, _opts ->
          headers = Enum.into(conn.req_headers, %{})
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
  end
end
