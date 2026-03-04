defmodule ActivityPub.Instances do
  @moduledoc "Instances context."
  import Untangle

  @adapter ActivityPub.Instances.Instance

  alias ActivityPub.Federator.HTTP
  alias ActivityPub.Federator.WebFinger
  alias ActivityPub.Instances.Instance
  alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter
  alias ActivityPub.Utils
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

  def host(%URI{} = uri), do: Utils.authority(uri)

  def host(url_or_host) when is_binary(url_or_host) do
    if url_or_host =~ ~r/^http/i do
      Utils.authority(url_or_host)
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
    host = Utils.authority(instance_uri)

    # with true <- Config.get([:instances_nodeinfo, :enabled]),
    with {_, true} <- {:reachable, reachable?(host)},
         {:ok, %Tesla.Env{status: 200, body: body, headers: headers}} <-
           HTTP.get(
             "#{Utils.base_url(instance_uri)}/.well-known/nodeinfo",
             [{"Accept", "application/json"}],
             []
           ),
         _ <-
           ActivityPub.Safety.HTTP.Signatures.maybe_cache_accept_signature(host, headers),
         {:ok, json} <- Jason.decode(body),
         {:ok, %{"links" => links}} <- {:ok, json},
         # FEP-2677: extract application actor from JRD links
         _ <- maybe_store_application_actor(host, links),
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
      maybe_infer_format_from_nodeinfo(host, nodeinfo)
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
  def get_or_discover_signature_format(%URI{} = uri) do
    host = Utils.authority(uri)

    case SignaturesAdapter.get_signature_format(host) do
      format when format in [:rfc9421, :cavage] ->
        format

      nil ->
        unless Process.get(:ap_discovery_in_progress) || discovery_attempted?(host) do
          try do
            # Prevents re-entrant discovery (when handle_incoming during discovery
            # triggers another fetch) and suppresses Tesla retries
            Process.put(:ap_discovery_in_progress, true)
            mark_discovery_attempted(host)
            discover_service_actor(uri)
            discover_signature_format(host)
          rescue
            e -> warn(e, "Signature format discovery failed for #{host}, using default")
          after
            Process.delete(:ap_discovery_in_progress)
          end
        end

        SignaturesAdapter.determine_signature_format(host)
    end
  end

  def get_or_discover_signature_format(host) when is_binary(host) do
    get_or_discover_signature_format(%URI{host: host})
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
  defp discover_service_actor(%URI{} = uri) do
    host = Utils.authority(uri)
    wf_result = WebFinger.finger_host(uri)
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
      nodeinfo = scrape_nodeinfo(uri)
      info("#{host} — nodeinfo result: #{inspect(nodeinfo && nodeinfo["software"])}")

      info(
        "#{host} — after nodeinfo: cached_format=#{inspect(SignaturesAdapter.get_signature_format(host))}"
      )
    end
  end

  defp discover_service_actor(host) when is_binary(host) do
    # Parse host string to URI for proper URL construction
    uri =
      if host =~ ~r/^http/i do
        URI.parse(host)
      else
        scheme = if String.starts_with?(host, "localhost"), do: "http", else: "https"
        URI.parse("#{scheme}://#{host}")
      end

    discover_service_actor(uri)
  end

  # Step 2: Determine signature format from what we know about the host.
  # Passes signature_format: :cavage to skip discovery in the Fetcher, which would otherwise call get_or_discover_signature_format again (infinite loop).
  defp discover_signature_format(host) do
    cached = SignaturesAdapter.get_signature_format(host)
    info("#{host} — discover_signature_format: cached=#{inspect(cached)}")

    unless cached do
      service_actor_uri = Instance.get_service_actor_uri(host)
      info("#{host} — fetching service actor: #{inspect(service_actor_uri)}")

      with uri when is_binary(uri) <- service_actor_uri do
        case ActivityPub.Federator.Fetcher.fetch_object_from_id(uri,
               signature_format: :cavage
             ) do
          {:ok, %{data: data}} ->
            SignaturesAdapter.maybe_extract_generator_info(host, data)

          _ ->
            :ok
        end
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
