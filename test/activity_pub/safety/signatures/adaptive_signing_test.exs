# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.AdaptiveSigningTest do
  @moduledoc "Tests for AP Publisher adaptive signing (RFC 9421 vs draft-cavage format selection)"

  use ActivityPub.DataCase, async: false

  alias ActivityPub.Federator.APPublisher
  alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter

  import ActivityPub.Factory
  import Mock
  import Tesla.Mock

  setup do
    mock(fn env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env]) end)
    :ok
  end

  describe "publish_one format selection" do
    test "uses RFC 9421 signing when host format is :rfc9421" do
      actor = local_actor()
      {:ok, ap_actor} = ActivityPub.Actor.get_cached(username: actor.username)

      host = "rfc-pub-#{System.unique_integer([:positive])}.example.com"
      inbox = "https://#{host}/inbox"

      # Pre-cache the format so discovery is skipped
      SignaturesAdapter.put_signature_format(host, :rfc9421)

      with_mock ActivityPub.Federator.HTTP,
        post: fn ^inbox, _body, headers ->
          header_names = Enum.map(headers, fn {k, _v} -> String.downcase(k) end)

          # RFC 9421 should include signature-input and content-digest headers
          assert "signature-input" in header_names
          assert "content-digest" in header_names

          {:ok, %{status: 202, headers: []}}
        end do
        result =
          APPublisher.publish_one(%{
            json: ~s[{"type":"Create"}],
            actor: ap_actor,
            inbox: inbox,
            id: "https://localhost/activities/test-rfc"
          })

        assert {:ok, _} = result
      end
    end

    # NodeBB compares a `digest` header, whenever one is present, with the RFC 3230 form of the body's hash (`SHA-256=<base64>`), and refuses the request with a 400 when it differs. An RFC 9421 request signs `content-digest` (`sha-256=:<base64>:`, RFC 9530) and has no need of `digest`, but must not send one in the wrong form. Found against activitypub.space on 20 October: the first request to it (a `Follow`) went out draft-cavage and was accepted, its `Accept-Signature` answer then moved the host to RFC 9421, and every later request was refused.
    test "an RFC 9421 delivery sends no digest header that disagrees with the body" do
      actor = local_actor()
      {:ok, ap_actor} = ActivityPub.Actor.get_cached(username: actor.username)

      host = "rfc-digest-#{System.unique_integer([:positive])}.example.com"
      inbox = "https://#{host}/inbox"
      json = ~s[{"type":"Create"}]

      SignaturesAdapter.put_signature_format(host, :rfc9421)

      with_mock ActivityPub.Federator.HTTP,
        post: fn ^inbox, body, headers ->
          headers = Map.new(headers, fn {k, v} -> {String.downcase(k), v} end)
          hash = Base.encode64(:crypto.hash(:sha256, body))

          assert headers["content-digest"] == "sha-256=:#{hash}:",
                 "control: the RFC 9530 digest that the signature covers is right"

          case headers["digest"] do
            nil ->
              :ok

            digest ->
              assert digest == "SHA-256=#{hash}",
                     "a `digest` header is RFC 3230, `SHA-256=<base64>`, and not the RFC 9530 value, got #{inspect(digest)}"
          end

          {:ok, %{status: 202, headers: []}}
        end do
        assert {:ok, _} =
                 APPublisher.publish_one(%{
                   json: json,
                   actor: ap_actor,
                   inbox: inbox,
                   id: "https://localhost/activities/test-rfc-digest"
                 })
      end
    end

    test "uses draft-cavage signing when host format is :cavage" do
      actor = local_actor()
      {:ok, ap_actor} = ActivityPub.Actor.get_cached(username: actor.username)

      host = "cavage-pub-#{System.unique_integer([:positive])}.example.com"
      inbox = "https://#{host}/inbox"

      # Pre-cache as cavage
      SignaturesAdapter.put_signature_format(host, :cavage)

      with_mock ActivityPub.Federator.HTTP,
        post: fn ^inbox, _body, headers ->
          header_names = Enum.map(headers, fn {k, _v} -> String.downcase(k) end)

          # Cavage should include signature but NOT signature-input
          assert "signature" in header_names
          refute "signature-input" in header_names

          {:ok, %{status: 202, headers: []}}
        end do
        result =
          APPublisher.publish_one(%{
            json: ~s[{"type":"Create"}],
            actor: ap_actor,
            inbox: inbox,
            id: "https://localhost/activities/test-cavage"
          })

        assert {:ok, _} = result
      end
    end

    test "defaults to cavage for unknown hosts" do
      actor = local_actor()
      {:ok, ap_actor} = ActivityPub.Actor.get_cached(username: actor.username)

      host = "unknown-pub-#{System.unique_integer([:positive])}.example.com"
      inbox = "https://#{host}/inbox"

      # Mark discovery as attempted so it doesn't try HTTP.get for WebFinger
      Cachex.put(:ap_sig_format_cache, "discovery:#{host}", true)

      with_mock ActivityPub.Federator.HTTP,
        post: fn ^inbox, _body, headers ->
          header_names = Enum.map(headers, fn {k, _v} -> String.downcase(k) end)

          # Should default to cavage (no signature-input)
          refute "signature-input" in header_names

          {:ok, %{status: 202, headers: []}}
        end do
        result =
          APPublisher.publish_one(%{
            json: ~s[{"type":"Create"}],
            actor: ap_actor,
            inbox: inbox,
            id: "https://localhost/activities/test-default"
          })

        assert {:ok, _} = result
      end
    end

    test "falls back to cavage when RFC 9421 signing fails" do
      actor = local_actor()
      {:ok, ap_actor} = ActivityPub.Actor.get_cached(username: actor.username)

      host = "fallback-#{System.unique_integer([:positive])}.example.com"
      inbox = "https://#{host}/inbox"

      SignaturesAdapter.put_signature_format(host, :rfc9421)

      # Mock Keys.sign/3 to fail for rfc9421; Keys.sign/2 (cavage) passes through
      with_mocks [
        {ActivityPub.Safety.Keys, [:passthrough],
         sign: fn _actor, _headers, _opts ->
           {:error, "test rfc9421 failure"}
         end},
        {ActivityPub.Federator.HTTP, [],
         post: fn ^inbox, _body, _headers ->
           {:ok, %{status: 202, headers: []}}
         end}
      ] do
        result =
          APPublisher.publish_one(%{
            json: ~s[{"type":"Create"}],
            actor: ap_actor,
            inbox: inbox,
            id: "https://localhost/activities/test-fallback"
          })

        # Should still succeed via cavage fallback
        assert {:ok, _} = result
      end
    end

    test "caches Accept-Signature from successful response" do
      actor = local_actor()
      {:ok, ap_actor} = ActivityPub.Actor.get_cached(username: actor.username)

      host = "accept-cache-#{System.unique_integer([:positive])}.example.com"
      inbox = "https://#{host}/inbox"

      # Mark discovery as attempted so it doesn't try HTTP.get for WebFinger
      Cachex.put(:ap_sig_format_cache, "discovery:#{host}", true)

      with_mock ActivityPub.Federator.HTTP,
        post: fn ^inbox, _body, _headers ->
          {:ok, %{status: 200, headers: [{"Accept-Signature", "sig1=()"}]}}
        end do
        APPublisher.publish_one(%{
          json: ~s[{"type":"Create"}],
          actor: ap_actor,
          inbox: inbox,
          id: "https://localhost/activities/test-accept-cache"
        })
      end

      assert SignaturesAdapter.get_signature_format(host) == :rfc9421
    end
  end
end
