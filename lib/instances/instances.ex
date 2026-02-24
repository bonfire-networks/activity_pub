defmodule ActivityPub.Instances do
  @moduledoc "Instances context."
  import Untangle

  @adapter ActivityPub.Instances.Instance

  alias ActivityPub.Federator.HTTP
  alias ActivityPub.Federator.WebFinger
  alias ActivityPub.Instances.Instance
  alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter
  # alias ActivityPub.Config

  @discovery_cache :ap_sig_format_cache

  @as_application_rel "https://www.w3.org/ns/activitystreams#Application"

  defdelegate filter_reachable(urls_or_hosts), to: @adapter
  defdelegate reachable?(url_or_host), to: @adapter
  defdelegate set_reachable(url_or_host), to: @adapter

  defdelegate set_unreachable(url_or_host, unreachable_since \\ nil),
    to: @adapter

  def set_consistently_unreachable(url_or_host),
    do: set_unreachable(url_or_host, reachability_datetime_threshold())

  @doc """
  Called after successful contact with a remote host.
  Marks the host as reachable.
  """
  def handle_successful_contact(url_or_host) do
    set_reachable(url_or_host)
  end

  def reachability_datetime_threshold do
    federation_reachability_timeout_days =
      Application.get_env(:activity_pub, :instance, [])[
        :federation_reachability_timeout_days
      ] || 0

    if federation_reachability_timeout_days > 0 do
      NaiveDateTime.add(
        NaiveDateTime.utc_now(Calendar.ISO),
        -federation_reachability_timeout_days * 24 * 3600,
        :second
      )
    else
      ~N[0000-01-01 00:00:00]
    end
  end

  def host(%URI{host: host}) do
    host
  end

  def host(url_or_host) when is_binary(url_or_host) do
    if url_or_host =~ ~r/^http/i do
      URI.parse(url_or_host).host
    else
      url_or_host
    end
    |> case do
      "" -> nil
      host -> host
    end
  end

  def host(_), do: nil

  def scrape_nodeinfo(%URI{} = instance_uri) do
    # with true <- Config.get([:instances_nodeinfo, :enabled]),
    with {_, true} <- {:reachable, reachable?(instance_uri.host)},
         {:ok, %Tesla.Env{status: 200, body: body, headers: headers}} <-
           Tesla.get(
             "https://#{instance_uri.host}/.well-known/nodeinfo",
             headers: [{"Accept", "application/json"}]
           ),
         _ <-
           ActivityPub.Safety.HTTP.Signatures.maybe_cache_accept_signature(instance_uri, headers),
         {:ok, json} <- Jason.decode(body),
         {:ok, %{"links" => links}} <- {:ok, json},
         # FEP-2677: extract application actor from JRD links
         _ <- maybe_store_application_actor(instance_uri.host, links),
         {:ok, %{"href" => href}} <-
           {:ok,
            Enum.find(links, fn link ->
              link["rel"] in [
                "http://nodeinfo.diaspora.software/ns/schema/2.1",
                "http://nodeinfo.diaspora.software/ns/schema/2.0"
              ]
            end)},
         {:ok, %Tesla.Env{body: data, headers: headers}} <-
           HTTP.get(href, [{"accept", "application/json"}], []),
         #  _ <- ActivityPub.Safety.HTTP.Signatures.maybe_cache_accept_signature(href, headers),
         {:length, true} <- {:length, String.length(data) < 50_000},
         {:ok, nodeinfo} <- Jason.decode(data) do
      # Infer signature format from known software versions
      maybe_infer_format_from_nodeinfo(instance_uri.host, nodeinfo)
      nodeinfo
    else
      {:reachable, false} ->
        info(
          instance_uri,
          "ignored unreachable host"
        )

        nil

      {:length, false} ->
        info(
          instance_uri,
          "ignored too long body"
        )

        nil

      _ ->
        nil
    end
  end

  def scrape_nodeinfo(instance_uri), do: URI.parse(instance_uri) |> scrape_nodeinfo()

  @doc """
  Returns the signature format for a host, running discovery first if needed.

  Checks cache first, then runs discovery (WebFinger, nodeinfo, FEP-844e) if the format is unknown and discovery hasn't been attempted recently.
  Always returns `:rfc9421` or `:cavage`.
  """
  def get_or_discover_signature_format(host) when is_binary(host) do
    case SignaturesAdapter.get_signature_format(host) do
      format when format in [:rfc9421, :cavage] ->
        format

      nil ->
        unless discovery_attempted?(host) do
          mark_discovery_attempted(host)
          discover_service_actor(host)
          discover_signature_format(host)
        end

        SignaturesAdapter.determine_signature_format(host)
    end
  end

  def get_or_discover_signature_format(_), do: :cavage

  defp discovery_attempted?(host) do
    Cachex.get(@discovery_cache, "discovery:#{host}") == {:ok, true}
  end

  defp mark_discovery_attempted(host) do
    Cachex.put(@discovery_cache, "discovery:#{host}", true)
  end

  # Step 1: Find the service actor URI via WebFinger (FEP-d556) or nodeinfo (FEP-2677),
  # and infer signature format from nodeinfo software version.
  defp discover_service_actor(host) do
    wf_result = WebFinger.finger_host(host)
    info("#{host} — finger_host result: #{inspect(wf_result)}")

    case wf_result do
      {:ok, service_actor_uri} ->
        Instance.set_service_actor_uri(host, service_actor_uri)

      _ ->
        :ok
    end

    service_actor = Instance.get_service_actor_uri(host)
    cached_format = SignaturesAdapter.get_signature_format(host)

    info(
      "#{host} — after WebFinger: service_actor=#{inspect(service_actor)}, cached_format=#{inspect(cached_format)}"
    )

    # If WebFinger didn't already give us enough, try nodeinfo for
    # FEP-2677 application actor and software version-based format inference.
    if is_nil(service_actor) or is_nil(cached_format) do
      nodeinfo = scrape_nodeinfo(%URI{host: host, scheme: "https"})
      info("#{host} — nodeinfo result: #{inspect(nodeinfo && nodeinfo["software"])}")

      info(
        "#{host} — after nodeinfo: cached_format=#{inspect(SignaturesAdapter.get_signature_format(host))}"
      )
    end
  end

  # Step 2: Determine signature format from what we know about the host
  defp discover_signature_format(host) do
    # Already found via Accept-Signature header during WebFinger/nodeinfo fetch?
    cached = SignaturesAdapter.get_signature_format(host)
    info("#{host} — discover_signature_format: cached=#{inspect(cached)}")

    unless cached do
      # Try fetching the service actor to check FEP-844e generator/implements
      uri = Instance.get_service_actor_uri(host)
      info("#{host} — fetching service actor: #{inspect(uri)}")

      with uri when is_binary(uri) <- uri do
        fetch_result = ActivityPub.Federator.Fetcher.get_cached_object_or_fetch_ap_id(uri)

        info(
          "#{host} — service actor fetch result: #{inspect(elem(fetch_result, 0))} — format now: #{inspect(SignaturesAdapter.get_signature_format(host))}"
        )
      end
    end
  end

  defp rfc9421_software do
    Application.get_env(:activity_pub, :rfc9421_software, %{})
  end

  defp maybe_infer_format_from_nodeinfo(host, %{"software" => %{"name" => name} = software})
       when is_binary(host) and is_binary(name) do
    # Skip if format is already cached
    if is_nil(SignaturesAdapter.get_signature_format(host)) do
      name = String.downcase(name)

      case Map.get(rfc9421_software(), name) do
        # All versions support it
        :any ->
          SignaturesAdapter.put_signature_format(host, :rfc9421)

        min_version when is_binary(min_version) ->
          version = software["version"] || ""

          if version_gte?(version, min_version) do
            SignaturesAdapter.put_signature_format(host, :rfc9421)
          end

        _ ->
          :ok
      end
    end
  end

  defp maybe_infer_format_from_nodeinfo(_, _), do: :ok

  defp version_gte?(version, min_version) do
    # Extract leading semver-like portion (e.g. "4.5.0-nightly" -> "4.5.0")
    parse = fn v ->
      case Regex.run(~r/^(\d+(?:\.\d+)*)/, v) do
        [_, semver] -> String.split(semver, ".") |> Enum.map(&String.to_integer/1)
        _ -> []
      end
    end

    case {parse.(version), parse.(min_version)} do
      {[], _} -> false
      {_, []} -> true
      {v, m} -> v >= m
    end
  end

  defp maybe_store_application_actor(host, links) when is_list(links) do
    case Enum.find(links, &(&1["rel"] == @as_application_rel)) do
      %{"href" => service_actor_uri} when is_binary(service_actor_uri) ->
        Instance.set_service_actor_uri(host, service_actor_uri)

      _ ->
        :ok
    end
  end

  defp maybe_store_application_actor(_, _), do: :ok
end
