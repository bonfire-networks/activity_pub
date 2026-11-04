# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Instances.NodeinfoSoftwareTest do
  @moduledoc "What software a server runs, learned from its nodeinfo whenever that is fetched, and remembered per server so it is asked once."

  use ActivityPub.Web.ConnCase

  import Tesla.Mock

  alias ActivityPub.Instances
  alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter

  # the cache is shared by every test, so each one asks about a host of its own
  defp unique_host(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}.example.com"

  # serves `software` as the host's nodeinfo, or a 404 for `nil`, and tells the test about every request, so it can see whether a second one was made
  defp mock_nodeinfo(host, software) do
    test_pid = self()

    mock(fn %{url: url} = env ->
      send(test_pid, {:requested, url})

      cond do
        is_nil(software) ->
          %Tesla.Env{env | status: 404, body: ""}

        url == "https://#{host}/.well-known/nodeinfo" ->
          json(%{
            "links" => [
              %{
                "rel" => "http://nodeinfo.diaspora.software/ns/schema/2.0",
                "href" => "https://#{host}/nodeinfo/2.0"
              }
            ]
          })

        url == "https://#{host}/nodeinfo/2.0" ->
          %Tesla.Env{
            env
            | status: 200,
              body: Jason.encode!(%{"version" => "2.0", "software" => software})
          }

        true ->
          %Tesla.Env{env | status: 404, body: ""}
      end
    end)
  end

  defp flush_requests do
    receive do
      {:requested, _} -> flush_requests()
    after
      0 -> :ok
    end
  end

  test "a nodeinfo fetch for any reason remembers the server's software" do
    host = unique_host("nodeinfo-any")
    mock_nodeinfo(host, %{"name" => "Mbin", "version" => "1.8.0"})

    # the positive first: the document was fetched and read
    assert %{"software" => %{"name" => "Mbin"}} = Instances.scrape_nodeinfo("https://#{host}")
    assert_received {:requested, _}
    flush_requests()

    assert Instances.software(host) == %{name: "mbin", version: "1.8.0"}
    refute_received {:requested, _}, "what an earlier fetch learned should be answered from the cache"
  end

  test "the software of a server nothing has asked about yet is fetched once" do
    host = unique_host("nodeinfo-first")
    mock_nodeinfo(host, %{"name" => "lemmy", "version" => "0.19.9"})

    assert Instances.software(host) == %{name: "lemmy", version: "0.19.9"}
    assert_received {:requested, _}
    flush_requests()

    assert Instances.software("https://#{host}/c/somewhere") == %{
             name: "lemmy",
             version: "0.19.9"
           }

    refute_received {:requested, _}, "a second ask should be answered from the cache"
  end

  test "a server with no nodeinfo answers nil, and isn't asked again" do
    host = unique_host("nodeinfo-none")
    mock_nodeinfo(host, nil)

    assert Instances.software(host) == nil
    assert_received {:requested, _}
    flush_requests()

    assert Instances.software(host) == nil
    refute_received {:requested, _}, "a server without nodeinfo shouldn't be asked on every post"
  end

  test "the signature format is still learned from the same document" do
    host = unique_host("nodeinfo-signature")

    # a software that `config :activity_pub, :rfc9421_software` says signs with RFC 9421 from this version on
    {name, min_version} =
      Application.get_env(:activity_pub, :rfc9421_software, %{})
      |> Enum.find(fn {_name, version} -> is_binary(version) end)

    mock_nodeinfo(host, %{"name" => name, "version" => min_version})

    assert %{name: ^name} = Instances.software(host)
    assert SignaturesAdapter.get_signature_format(host) == :rfc9421
  end
end
