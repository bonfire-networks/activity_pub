defmodule ActivityPub.Federator.HTTP.SignFetchTest do
  @moduledoc """
  A signed fetch is signed again for each redirect hop: a signature covers the URL it was made for, so the one made for the first URL does not hold for the URL the redirect points to.

  The Tesla adapter is a mock that records the headers of each request it receives, after the whole middleware stack.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import Tesla.Mock

  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.HTTP
  alias ActivityPub.Safety.Keys

  @friendly "https://mastodon.local/post/x"
  @canonical "https://mastodon.local/pub/objects/x"

  # the same, but the redirect points to another host
  @cross_friendly "https://mastodon.local/post/y"
  @cross_canonical "https://other.local/pub/objects/y"

  setup do
    # what the host cache holds about these hosts must come from the test only
    for host <- ["mastodon.local", "other.local"] do
      ActivityPub.Instances.delete_host_cache(host, :signature_format)
    end

    on_exit(fn ->
      for host <- ["mastodon.local", "other.local"] do
        ActivityPub.Instances.delete_host_cache(host, :signature_format)
      end
    end)

    test = self()

    object = %{
      "id" => @canonical,
      "type" => "Note",
      "content" => "hello",
      "attributedTo" => "https://mastodon.local/users/admin"
    }

    mock(fn env ->
      send(test, {:request, env.url, env.headers})

      case env.url do
        @friendly ->
          # the response keeps the request's options, as a real adapter's does, since the redirect middleware sends them on to the next hop
          {:ok, %{env | status: 302, headers: [{"location", @canonical}], body: ""}}

        @canonical ->
          {:ok, %{env | status: 200, body: Jason.encode!(object)}}

        @cross_friendly ->
          {:ok, %{env | status: 302, headers: [{"location", @cross_canonical}], body: ""}}

        @cross_canonical ->
          {:ok, %{env | status: 200, body: Jason.encode!(%{object | "id" => @cross_canonical})}}
      end
    end)

    {:ok, signer} = ActivityPub.Actor.get_cached(username: local_actor().username)
    {:ok, signer} = Keys.ensure_keys_present(signer)
    {:ok, _private_key, public_key} = Keys.keypair_from_pem(signer.keys)

    {:ok, signer: signer, public_key: public_key}
  end

  defp requests(acc \\ []) do
    receive do
      {:request, url, headers} -> requests([{url, headers} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # the headers as the receiving plug sees them: lowercase names, and the derived values it sets. A request with no signature at all fails here, with a message that names the URL
  defp as_received(url, headers, format) do
    assert Enum.any?(headers, fn {k, _} -> String.downcase(k) == "signature" end),
           "the request to #{url} is not signed"

    do_as_received(url, headers, format)
  end

  defp do_as_received(url, headers, :cavage) do
    uri = URI.parse(url)

    headers
    |> Map.new(fn {k, v} -> {String.downcase(k), v} end)
    |> Map.merge(%{"(request-target)" => "get #{uri.path}", "host" => uri.host})
  end

  defp do_as_received(url, headers, :rfc9421) do
    uri = URI.parse(url)

    headers
    |> Map.new(fn {k, v} -> {String.downcase(k), v} end)
    |> Map.merge(%{
      "@method" => "GET",
      "@scheme" => uri.scheme,
      "@authority" => uri.host,
      "@path" => uri.path,
      "(request-target)" => "get #{uri.path}"
    })
  end

  for format <- [:cavage, :rfc9421] do
    describe "with #{format} signatures" do
      test "the request to a redirect target is signed for that URL", %{
        signer: signer,
        public_key: public_key
      } do
        assert {:ok, %{"id" => @canonical}} =
                 Fetcher.fetch_remote_object_from_id(@friendly,
                   current_actor: {:ok, signer},
                   signature_format: unquote(format),
                   force_instance_reachable: true
                 )

        assert [{@friendly, first}, {@canonical, second}] = requests()

        assert HTTPSignatures.validate_headers(
                 as_received(@friendly, first, unquote(format)),
                 public_key
               ),
               "the first request has to be signed for the URL it asks for"

        assert HTTPSignatures.validate_headers(
                 as_received(@canonical, second, unquote(format)),
                 public_key
               ),
               "the request after the redirect has to be signed for the URL it asks for"
      end

      test "control: a fetch with no redirect sends one signed request", %{
        signer: signer,
        public_key: public_key
      } do
        assert {:ok, %{"id" => @canonical}} =
                 Fetcher.fetch_remote_object_from_id(@canonical,
                   current_actor: {:ok, signer},
                   signature_format: unquote(format),
                   force_instance_reachable: true
                 )

        assert [{@canonical, headers}] = requests()

        assert HTTPSignatures.validate_headers(
                 as_received(@canonical, headers, unquote(format)),
                 public_key
               )
      end
    end
  end

  describe "a redirect to another host" do
    alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter

    defp get_signed(url, signer, format) do
      HTTP.get(url, [{"accept", "application/activity+json"}],
        sign_fetch: [current_actor: {:ok, signer}, signature_format: format]
      )
    end

    for {first, second} <- [{:cavage, :rfc9421}, {:rfc9421, :cavage}] do
      test "is signed in the format cached for that host (#{first} then #{second})", %{
        signer: signer,
        public_key: public_key
      } do
        SignaturesAdapter.maybe_put_signature_format("other.local", unquote(second))

        assert {:ok, %{status: 200}} = get_signed(@cross_friendly, signer, unquote(first))

        assert [{@cross_friendly, first_req}, {@cross_canonical, second_req}] = requests()

        assert HTTPSignatures.validate_headers(
                 as_received(@cross_friendly, first_req, unquote(first)),
                 public_key
               ),
               "the first request has to be signed in the format asked for"

        assert HTTPSignatures.validate_headers(
                 as_received(@cross_canonical, second_req, unquote(second)),
                 public_key
               ),
               "the request to the other host has to be signed in the format cached for that host"
      end
    end

    test "keeps the format the request used when none is cached for the new host", %{
      signer: signer,
      public_key: public_key
    } do
      assert SignaturesAdapter.get_signature_format("other.local") == nil

      assert {:ok, %{status: 200}} = get_signed(@cross_friendly, signer, :rfc9421)

      assert [{@cross_friendly, _}, {@cross_canonical, second_req}] = requests()

      assert HTTPSignatures.validate_headers(
               as_received(@cross_canonical, second_req, :rfc9421),
               public_key
             )

      assert SignaturesAdapter.get_signature_format("other.local") == nil,
             "signing must not discover or cache a format"
    end

    test "control: a redirect within the same host does not look the format up again", %{
      signer: signer,
      public_key: public_key
    } do
      # if the host were looked up again after the redirect, the second request would be signed as RFC 9421
      SignaturesAdapter.maybe_put_signature_format("mastodon.local", :rfc9421)

      assert {:ok, %{status: 200}} = get_signed(@friendly, signer, :cavage)

      assert [{@friendly, first_req}, {@canonical, second_req}] = requests()

      for {url, headers} <- [{@friendly, first_req}, {@canonical, second_req}] do
        assert HTTPSignatures.validate_headers(as_received(url, headers, :cavage), public_key)
        refute List.keymember?(headers, "signature-input", 0)
      end
    end
  end

  test "a request that is not signed stays unsigned after a redirect" do
    assert {:ok, %{status: 200}} = HTTP.get(@friendly, [{"accept", "application/activity+json"}])

    assert [{@friendly, first}, {@canonical, second}] = requests()

    for headers <- [first, second], {name, _} <- headers do
      refute String.downcase(name) in ["signature", "signature-input"]
    end
  end
end
