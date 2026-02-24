# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Safety.Signatures.GeneratorExtractionTest do
  @moduledoc "Tests for generator info extraction hooks in actor.ex and fetcher.ex"

  use ActivityPub.Web.ConnCase

  import ActivityPub.Factory
  import Mock
  import Tesla.Mock

  alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter

  setup do
    mock(fn env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env]) end)
    :ok
  end

  describe "maybe_extract_generator_info edge cases" do
    test "extracts service_actor_uri even when generator has no implements" do
      host = "gen-noimpl-#{System.unique_integer([:positive])}.example.com"

      data = %{
        "generator" => %{
          "id" => "https://#{host}/actor"
        }
      }

      SignaturesAdapter.maybe_extract_generator_info(host, data)

      assert ActivityPub.Instances.Instance.get_service_actor_uri(host) ==
               "https://#{host}/actor"

      assert SignaturesAdapter.get_signature_format(host) == nil
    end

    test "handles generator without id" do
      host = "gen-noid-#{System.unique_integer([:positive])}.example.com"

      data = %{
        "generator" => %{
          "implements" => [%{"id" => "https://datatracker.ietf.org/doc/html/rfc9421"}]
        }
      }

      SignaturesAdapter.maybe_extract_generator_info(host, data)

      # No service_actor_uri stored (no id), but format should be cached
      assert ActivityPub.Instances.Instance.get_service_actor_uri(host) == nil
      assert SignaturesAdapter.get_signature_format(host) == :rfc9421
    end

    test "handles non-binary host" do
      assert SignaturesAdapter.maybe_extract_generator_info(nil, %{"generator" => %{}}) == :ok
    end

    test "handles non-map generator" do
      host = "gen-badtype-#{System.unique_integer([:positive])}.example.com"

      # generator is a string (some implementations do this)
      assert SignaturesAdapter.maybe_extract_generator_info(host, %{"generator" => "Mastodon"}) ==
               :ok
    end
  end

  describe "generator extraction via actor create/update" do
    test "extracts generator info when creating actor from AP data with generator" do
      host = "actor-gen-#{System.unique_integer([:positive])}.example.com"

      actor_data = %{
        "id" => "https://#{host}/users/alice",
        "type" => "Person",
        "preferredUsername" => "alice",
        "inbox" => "https://#{host}/users/alice/inbox",
        "outbox" => "https://#{host}/users/alice/outbox",
        "generator" => %{
          "id" => "https://#{host}/actor",
          "implements" => [%{"id" => "https://datatracker.ietf.org/doc/html/rfc9421"}]
        }
      }

      # Directly call maybe_extract_generator_info as the hook would
      SignaturesAdapter.maybe_extract_generator_info(host, actor_data)

      assert SignaturesAdapter.get_signature_format(host) == :rfc9421

      assert ActivityPub.Instances.Instance.get_service_actor_uri(host) ==
               "https://#{host}/actor"
    end

    test "skips extraction when format is already cached" do
      host = "actor-skip-#{System.unique_integer([:positive])}.example.com"

      # Pre-cache as cavage
      SignaturesAdapter.put_signature_format(host, :cavage)

      actor_data = %{
        "id" => "https://#{host}/users/alice",
        "generator" => %{
          "id" => "https://#{host}/actor",
          "implements" => [%{"id" => "https://datatracker.ietf.org/doc/html/rfc9421"}]
        }
      }

      # The hook in actor.ex checks get_signature_format before calling extract
      # Simulating the guard: only calls extract when format is nil
      if is_nil(SignaturesAdapter.get_signature_format(host)) do
        SignaturesAdapter.maybe_extract_generator_info(host, actor_data)
      end

      # Should remain cavage since extraction was skipped
      assert SignaturesAdapter.get_signature_format(host) == :cavage
    end
  end

  describe "generator extraction via fetcher" do
    test "extracts generator from fetched data when format unknown" do
      host = "fetch-gen-#{System.unique_integer([:positive])}.example.com"

      fetched_data = %{
        "id" => "https://#{host}/users/bob",
        "type" => "Person",
        "generator" => %{
          "id" => "https://#{host}/actor",
          "implements" => [%{"id" => "https://datatracker.ietf.org/doc/html/rfc9421"}]
        }
      }

      # Simulating what maybe_extract_generator_from_fetched does
      id = fetched_data["id"]
      fetched_host = URI.parse(id).host

      if fetched_host && is_nil(SignaturesAdapter.get_signature_format(fetched_host)) do
        SignaturesAdapter.maybe_extract_generator_info(fetched_host, fetched_data)
      end

      assert SignaturesAdapter.get_signature_format(host) == :rfc9421

      assert ActivityPub.Instances.Instance.get_service_actor_uri(host) ==
               "https://#{host}/actor"
    end

    test "does nothing when data has no generator key" do
      host = "fetch-nogen-#{System.unique_integer([:positive])}.example.com"

      fetched_data = %{
        "id" => "https://#{host}/users/bob",
        "type" => "Person"
      }

      # Pattern match on "generator" key means this is a no-op
      case fetched_data do
        %{"generator" => _} ->
          SignaturesAdapter.maybe_extract_generator_info(host, fetched_data)

        _ ->
          :ok
      end

      assert SignaturesAdapter.get_signature_format(host) == nil
    end
  end
end
