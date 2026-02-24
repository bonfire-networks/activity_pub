# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.LiveFederation.SignatureDiscoveryTest do
  @moduledoc """
  Live federation tests for signature format discovery against real instances.

  Tests WebFinger host-level discovery (FEP-d556), FEP-2677 nodeinfo,
  FEP-844e generator detection, and Accept-Signature header caching.

  Run with: just test-federation-live-DRAGONS forks/activity_pub/test/activity_pub/live_federation/signature_discovery_live_test.exs
  """

  use ActivityPub.Web.ConnCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Actor
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.WebFinger
  alias ActivityPub.Instances
  alias ActivityPub.Instances.Instance
  alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter

  # WARNING: these are integration tests which run against real remote instances!
  @moduletag :live_federation
  # They only run when you specifically instruct ex_unit to run this tag.

  # Known instances for testing different implementations:
  # - Mastodon: mastodon.social (RFC 9421 validation since 4.4.0, enabled by default in 4.5.0;
  #             outgoing still draft-cavage but validates both; uses Accept-Signature)
  # - Fedify:   hollo.social (RFC 9421 + FEP-844e generator advertisement)
  # - Mitra:    mitra.social (RFC 9421)
  # - Akkoma:   seafoam.space (draft-cavage only, no RFC 9421)

  describe "Fedify instance (hollo.social)" do
    setup do
      host = "hollo.social"

      # Clear caches so discovery runs fresh
      Cachex.del(:ap_sig_format_cache, host)
      Cachex.del(:ap_sig_format_cache, "discovery:#{host}")

      # Run discovery once for all tests in this block
      Instances.get_or_discover_signature_format(host)

      # Fetch the well-known Fedify actor once
      actor_result = Actor.get_cached_or_fetch(ap_id: "https://hollo.social/@fedify")

      fetch_result =
        Fetcher.fetch_remote_object_from_id("https://hollo.social/@fedify",
          force_instance_reachable: true
        )

      webfinger_result = WebFinger.finger_host(host)

      {:ok,
       host: host,
       actor_result: actor_result,
       fetch_result: fetch_result,
       webfinger_result: webfinger_result}
    end

    test "finger_host discovers service actor", %{webfinger_result: result, host: host} do
      case result do
        {:ok, service_actor_uri} ->
          assert is_binary(service_actor_uri)
          assert String.starts_with?(service_actor_uri, "https://#{host}")

        _ ->
          # Hollo may not expose a service actor via host-level WebFinger
          :ok
      end
    end

    test "actor does not yet advertise FEP-844e generator/implements", %{
      actor_result: actor_result
    } do
      # Hollo/Fedify does not currently include generator or implements on actor profiles.
      # RFC 9421 support is detected via nodeinfo software name instead.
      assert {:ok, actor} = actor_result

      refute SignaturesAdapter.supports_rfc9421?(actor.data),
             "Hollo unexpectedly has FEP-844e support — check if Fedify added generator/implements"
    end

    test "discovery detects RFC 9421 via nodeinfo or FEP-844e", %{host: host} do
      assert {:ok, true} == Cachex.get(:ap_sig_format_cache, "discovery:#{host}")

      assert SignaturesAdapter.get_signature_format(host) == :rfc9421,
             "Expected :rfc9421 for Fedify instance #{host}"

      service_actor = Instance.get_service_actor_uri(host)
      IO.puts("#{host} — service_actor: #{inspect(service_actor)}")
    end

    test "determine_signature_format returns rfc9421", %{host: host} do
      assert SignaturesAdapter.determine_signature_format(host) == :rfc9421
    end
  end

  describe "Mastodon instance (mastodon.social)" do
    setup do
      host = "mastodon.social"

      Cachex.del(:ap_sig_format_cache, host)
      Cachex.del(:ap_sig_format_cache, "discovery:#{host}")

      # Discovery + fetch will likely see Accept-Signature from Mastodon 4.5.0+
      Instances.get_or_discover_signature_format(host)

      actor_result = Actor.get_cached_or_fetch(ap_id: "https://mastodon.social/@Mastodon")
      webfinger_result = WebFinger.finger_host(host)
      nodeinfo = Instances.scrape_nodeinfo(%URI{host: host, scheme: "https"})

      {:ok,
       host: host,
       actor_result: actor_result,
       webfinger_result: webfinger_result,
       nodeinfo: nodeinfo}
    end

    test "finger_host discovers service actor", %{webfinger_result: result, host: host} do
      case result do
        {:ok, service_actor_uri} ->
          assert is_binary(service_actor_uri)
          assert String.starts_with?(service_actor_uri, "https://#{host}")

        {:error, :not_found} ->
          # Mastodon may not expose a service actor via host-level WebFinger
          :ok
      end
    end

    test "actor generator field and RFC 9421 support", %{actor_result: actor_result} do
      # Mastodon 4.5.0+ validates RFC 9421 by default (outgoing still draft-cavage).
      # It does NOT advertise via FEP-844e generator — it signals via Accept-Signature instead.
      case actor_result do
        {:ok, actor} ->
          has_generator = is_map(actor.data["generator"])
          has_rfc9421 = SignaturesAdapter.supports_rfc9421?(actor.data)

          IO.puts(
            "Mastodon generator present: #{has_generator}, RFC 9421 via FEP-844e: #{has_rfc9421}"
          )

          # Mastodon doesn't use FEP-844e, so we expect no generator
          refute has_generator,
                 "Mastodon unexpectedly has a generator field — check if they added FEP-844e support"

        {:error, reason} ->
          IO.puts("Could not fetch Mastodon actor: #{inspect(reason)}")
      end
    end

    test "discovery detects RFC 9421 via nodeinfo version", %{host: host} do
      assert {:ok, true} == Cachex.get(:ap_sig_format_cache, "discovery:#{host}")

      # Mastodon 4.5.0+ is in our known RFC 9421 software list
      assert SignaturesAdapter.get_signature_format(host) == :rfc9421

      service_actor = Instance.get_service_actor_uri(host)
      IO.puts("#{host} — service_actor: #{inspect(service_actor)}")
    end

    test "determine_signature_format returns rfc9421", %{host: host} do
      assert SignaturesAdapter.determine_signature_format(host) == :rfc9421
    end

    test "nodeinfo FEP-2677 extracts software info", %{host: host, nodeinfo: nodeinfo} do
      service_actor = Instance.get_service_actor_uri(host)

      IO.puts(
        "#{host} nodeinfo — software: #{inspect(nodeinfo && nodeinfo["software"])}, service_actor: #{inspect(service_actor)}"
      )

      if nodeinfo do
        assert is_map(nodeinfo["software"])
      end
    end
  end

  describe "Mitra instance (mitra.social)" do
    setup do
      host = "mitra.social"

      Cachex.del(:ap_sig_format_cache, host)
      Cachex.del(:ap_sig_format_cache, "discovery:#{host}")

      # Mitra supports RFC 9421 natively
      Instances.get_or_discover_signature_format(host)

      webfinger_result = WebFinger.finger_host(host)
      nodeinfo = Instances.scrape_nodeinfo(%URI{host: host, scheme: "https"})

      {:ok, host: host, webfinger_result: webfinger_result, nodeinfo: nodeinfo}
    end

    test "finger_host discovers service actor", %{webfinger_result: result, host: host} do
      case result do
        {:ok, service_actor_uri} ->
          assert is_binary(service_actor_uri)
          assert String.starts_with?(service_actor_uri, "https://#{host}")

        {:error, :not_found} ->
          :ok
      end
    end

    test "discovery detects RFC 9421 via nodeinfo", %{host: host} do
      assert {:ok, true} == Cachex.get(:ap_sig_format_cache, "discovery:#{host}")

      # Mitra is in our known RFC 9421 software list
      assert SignaturesAdapter.get_signature_format(host) == :rfc9421

      service_actor = Instance.get_service_actor_uri(host)
      IO.puts("#{host} — service_actor: #{inspect(service_actor)}")
    end

    test "determine_signature_format returns rfc9421", %{host: host} do
      assert SignaturesAdapter.determine_signature_format(host) == :rfc9421
    end

    test "nodeinfo extracts software info", %{host: host, nodeinfo: nodeinfo} do
      service_actor = Instance.get_service_actor_uri(host)

      IO.puts(
        "#{host} nodeinfo — software: #{inspect(nodeinfo && nodeinfo["software"])}, service_actor: #{inspect(service_actor)}"
      )

      if nodeinfo do
        assert is_map(nodeinfo["software"])
      end
    end
  end

  describe "Akkoma instance (seafoam.space) — draft-cavage only" do
    setup do
      host = "seafoam.space"

      Cachex.del(:ap_sig_format_cache, host)
      Cachex.del(:ap_sig_format_cache, "discovery:#{host}")

      Instances.get_or_discover_signature_format(host)

      webfinger_result = WebFinger.finger_host(host)
      nodeinfo = Instances.scrape_nodeinfo(%URI{host: host, scheme: "https"})

      {:ok, host: host, webfinger_result: webfinger_result, nodeinfo: nodeinfo}
    end

    test "discovery does not detect RFC 9421", %{host: host} do
      # Akkoma only supports draft-cavage, so no RFC 9421 signal should be found
      format = SignaturesAdapter.get_signature_format(host)

      IO.puts("#{host} — cached format after discovery: #{inspect(format)}")

      # Should be nil (unknown) or :cavage, never :rfc9421
      refute format == :rfc9421,
             "Akkoma instance should not advertise RFC 9421, got: #{inspect(format)}"
    end

    test "determine_signature_format defaults to cavage", %{host: host} do
      format = SignaturesAdapter.determine_signature_format(host)
      assert format == :cavage, "Expected :cavage for Akkoma instance, got: #{inspect(format)}"
    end

    test "nodeinfo extracts software info", %{host: host, nodeinfo: nodeinfo} do
      assert nodeinfo, "Expected nodeinfo to be present for #{host}"

      IO.puts("#{host} nodeinfo — software: #{inspect(nodeinfo && nodeinfo["software"])}")

      if nodeinfo do
        assert is_map(nodeinfo["software"])
      end
    end
  end
end
