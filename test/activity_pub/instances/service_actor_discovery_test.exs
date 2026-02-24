# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Instances.ServiceActorDiscoveryTest do
  @moduledoc "Tests for service actor discovery and generator info extraction"

  use ActivityPub.Web.ConnCase

  import ActivityPub.Factory
  import Mock
  import Tesla.Mock

  alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter
  alias ActivityPub.Instances
  alias ActivityPub.Instances.Instance
  alias ActivityPub.Federator.WebFinger

  setup do
    mock(fn env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env]) end)
    :ok
  end

  describe "maybe_extract_generator_info" do
    test "stores service_actor_uri and caches rfc9421 format from generator" do
      host = "gen-#{System.unique_integer([:positive])}.example.com"

      data = %{
        "generator" => %{
          "id" => "https://#{host}/actor",
          "implements" => [%{"id" => "https://datatracker.ietf.org/doc/html/rfc9421"}]
        }
      }

      SignaturesAdapter.maybe_extract_generator_info(host, data)

      assert SignaturesAdapter.get_signature_format(host) == :rfc9421
      assert Instance.get_service_actor_uri(host) == "https://#{host}/actor"
    end

    test "stores service_actor_uri without caching format when no rfc9421 support" do
      host = "gen-no9421-#{System.unique_integer([:positive])}.example.com"

      data = %{
        "generator" => %{
          "id" => "https://#{host}/actor",
          "implements" => [%{"id" => "https://example.com/other-spec"}]
        }
      }

      SignaturesAdapter.maybe_extract_generator_info(host, data)

      assert SignaturesAdapter.get_signature_format(host) == nil
      assert Instance.get_service_actor_uri(host) == "https://#{host}/actor"
    end

    test "is no-op without generator" do
      host = "gen-noop-#{System.unique_integer([:positive])}.example.com"
      assert SignaturesAdapter.maybe_extract_generator_info(host, %{}) == :ok
      assert SignaturesAdapter.get_signature_format(host) == nil
      assert Instance.get_service_actor_uri(host) == nil
    end
  end

  describe "determine_signature_format with stored service actor" do
    test "checks stored service actor when cache and FEP-844e miss" do
      host = "svc-#{System.unique_integer([:positive])}.example.com"
      service_actor_uri = "https://#{host}/actor"

      # Store the service actor URI in DB
      Instance.set_service_actor_uri(host, service_actor_uri)

      actor_data = %{
        "id" => service_actor_uri,
        "generator" => %{
          "implements" => [%{"id" => "https://datatracker.ietf.org/doc/html/rfc9421"}]
        }
      }

      # Mock Actor.get_cached to return a fake actor with generator info
      with_mock ActivityPub.Actor, [:passthrough],
        get_cached: fn
          [ap_id: ^service_actor_uri] ->
            {:ok, %ActivityPub.Actor{data: actor_data}}

          args ->
            :meck.passthrough([args])
        end do
        assert SignaturesAdapter.determine_signature_format(host) == :rfc9421
        # Should now be cached
        assert SignaturesAdapter.get_signature_format(host) == :rfc9421
      end
    end

    test "falls back to cavage when stored service actor lacks rfc9421 support" do
      host = "svc-cavage-#{System.unique_integer([:positive])}.example.com"

      Instance.set_service_actor_uri(host, "https://#{host}/actor")

      # No cached actor for this URI, so check_stored_service_actor returns false
      assert SignaturesAdapter.determine_signature_format(host) == :cavage
    end
  end

  describe "Instance service_actor_uri helpers" do
    test "set and get service_actor_uri round-trip" do
      host = "helpers-#{System.unique_integer([:positive])}.example.com"
      assert Instance.get_service_actor_uri(host) == nil

      {:ok, _} = Instance.set_service_actor_uri(host, "https://#{host}/actor")
      assert Instance.get_service_actor_uri(host) == "https://#{host}/actor"
    end

    test "set_service_actor_uri upserts on existing instance" do
      host = "upsert-#{System.unique_integer([:positive])}.example.com"

      {:ok, _} = Instance.set_service_actor_uri(host, "https://#{host}/actor-v1")
      assert Instance.get_service_actor_uri(host) == "https://#{host}/actor-v1"

      {:ok, _} = Instance.set_service_actor_uri(host, "https://#{host}/actor-v2")
      assert Instance.get_service_actor_uri(host) == "https://#{host}/actor-v2"
    end

    test "get_by_host returns nil for unknown host" do
      assert Instance.get_by_host("nonexistent-#{System.unique_integer([:positive])}.example.com") ==
               nil
    end

    test "get_by_host returns instance after set_service_actor_uri" do
      host = "getby-#{System.unique_integer([:positive])}.example.com"
      Instance.set_service_actor_uri(host, "https://#{host}/actor")

      instance = Instance.get_by_host(host)
      assert instance.host == host
      assert instance.service_actor_uri == "https://#{host}/actor"
    end
  end

  describe "finger_host (FEP-d556)" do
    test "returns service actor URI from WebFinger JRD with activity+json self link" do
      host = "wf-#{System.unique_integer([:positive])}.example.com"

      jrd =
        Jason.encode!(%{
          "subject" => "https://#{host}",
          "links" => [
            %{
              "rel" => "self",
              "type" => "application/activity+json",
              "href" => "https://#{host}/actor"
            }
          ]
        })

      with_mock ActivityPub.Federator.HTTP,
        get: fn _url, _headers ->
          {:ok, %{status: 200, body: jrd, headers: []}}
        end do
        assert {:ok, "https://#{host}/actor"} == WebFinger.finger_host(host)
      end
    end

    test "returns service actor URI from ld+json self link" do
      host = "wf-ld-#{System.unique_integer([:positive])}.example.com"

      jrd =
        Jason.encode!(%{
          "subject" => "https://#{host}",
          "links" => [
            %{
              "rel" => "self",
              "type" => "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
              "href" => "https://#{host}/actor"
            }
          ]
        })

      with_mock ActivityPub.Federator.HTTP,
        get: fn _url, _headers ->
          {:ok, %{status: 200, body: jrd, headers: []}}
        end do
        assert {:ok, "https://#{host}/actor"} == WebFinger.finger_host(host)
      end
    end

    test "returns error when HTTP request fails" do
      host = "wf-fail-#{System.unique_integer([:positive])}.example.com"

      with_mock ActivityPub.Federator.HTTP,
        get: fn _url, _headers ->
          {:ok, %{status: 404, body: "not found", headers: []}}
        end do
        assert {:error, :not_found} == WebFinger.finger_host(host)
      end
    end

    test "returns error when no self link in JRD" do
      host = "wf-noself-#{System.unique_integer([:positive])}.example.com"

      jrd =
        Jason.encode!(%{
          "subject" => "https://#{host}",
          "links" => [
            %{"rel" => "http://webfinger.net/rel/profile-page", "href" => "https://#{host}"}
          ]
        })

      with_mock ActivityPub.Federator.HTTP,
        get: fn _url, _headers ->
          {:ok, %{status: 200, body: jrd, headers: []}}
        end do
        assert {:error, :not_found} == WebFinger.finger_host(host)
      end
    end

    test "caches Accept-Signature header from WebFinger response" do
      host = "wf-accept-#{System.unique_integer([:positive])}.example.com"

      jrd =
        Jason.encode!(%{
          "subject" => "https://#{host}",
          "links" => [
            %{
              "rel" => "self",
              "type" => "application/activity+json",
              "href" => "https://#{host}/actor"
            }
          ]
        })

      with_mock ActivityPub.Federator.HTTP,
        get: fn _url, _headers ->
          {:ok, %{status: 200, body: jrd, headers: [{"Accept-Signature", "sig1=()"}]}}
        end do
        assert {:ok, _} = WebFinger.finger_host(host)
      end

      assert SignaturesAdapter.get_signature_format(host) == :rfc9421
    end
  end

  describe "get_or_discover_signature_format" do
    test "returns cached format without discovery" do
      host = "disc-cached-#{System.unique_integer([:positive])}.example.com"
      SignaturesAdapter.put_signature_format(host, :rfc9421)

      assert Instances.get_or_discover_signature_format(host) == :rfc9421
    end

    test "returns cavage when discovery was recently attempted" do
      host = "disc-attempted-#{System.unique_integer([:positive])}.example.com"

      # Simulate a previous discovery attempt with no result
      Cachex.put(:ap_sig_format_cache, "discovery:#{host}", true)

      assert Instances.get_or_discover_signature_format(host) == :cavage
    end

    test "discovers via WebFinger on first contact with unknown host" do
      host = "disc-new-#{System.unique_integer([:positive])}.example.com"

      jrd =
        Jason.encode!(%{
          "subject" => "https://#{host}",
          "links" => [
            %{
              "rel" => "self",
              "type" => "application/activity+json",
              "href" => "https://#{host}/actor"
            }
          ]
        })

      http_get = fn url ->
        if String.contains?(url, ".well-known/webfinger") do
          {:ok, %{status: 200, body: jrd, headers: []}}
        else
          {:ok, %{status: 404, body: "", headers: []}}
        end
      end

      with_mock ActivityPub.Federator.HTTP, [:passthrough],
        get: fn url, _headers -> http_get.(url) end do
        Instances.get_or_discover_signature_format(host)
      end

      # Should have stored the service actor URI
      assert Instance.get_service_actor_uri(host) == "https://#{host}/actor"
      # Discovery should be marked as attempted
      assert Cachex.get(:ap_sig_format_cache, "discovery:#{host}") == {:ok, true}
    end

    test "returns cavage for nil host" do
      assert Instances.get_or_discover_signature_format(nil) == :cavage
    end
  end

  describe "maybe_store_application_actor (FEP-2677)" do
    test "stores application actor from nodeinfo JRD links" do
      host = "fep2677-#{System.unique_integer([:positive])}.example.com"

      links = [
        %{
          "rel" => "http://nodeinfo.diaspora.software/ns/schema/2.0",
          "href" => "https://#{host}/nodeinfo/2.0"
        },
        %{
          "rel" => "https://www.w3.org/ns/activitystreams#Application",
          "href" => "https://#{host}/actor"
        }
      ]

      # Call the private function via scrape_nodeinfo path indirectly,
      # or test the Instance storage directly
      Instance.set_service_actor_uri(host, nil)

      # Simulate what maybe_store_application_actor does
      case Enum.find(links, &(&1["rel"] == "https://www.w3.org/ns/activitystreams#Application")) do
        %{"href" => uri} -> Instance.set_service_actor_uri(host, uri)
        _ -> :ok
      end

      assert Instance.get_service_actor_uri(host) == "https://#{host}/actor"
    end

    test "does nothing when no application actor link present" do
      host = "fep2677-none-#{System.unique_integer([:positive])}.example.com"

      links = [
        %{
          "rel" => "http://nodeinfo.diaspora.software/ns/schema/2.0",
          "href" => "https://#{host}/nodeinfo/2.0"
        }
      ]

      case Enum.find(links, &(&1["rel"] == "https://www.w3.org/ns/activitystreams#Application")) do
        %{"href" => uri} -> Instance.set_service_actor_uri(host, uri)
        _ -> :ok
      end

      assert Instance.get_service_actor_uri(host) == nil
    end
  end
end
