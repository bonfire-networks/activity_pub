defmodule ActivityPub.Instances do
  @moduledoc "Instances context."
  import Untangle

  @adapter ActivityPub.Instances.Instance

  alias ActivityPub.Federator.HTTP
  # alias ActivityPub.Config

  defdelegate filter_reachable(urls_or_hosts), to: @adapter
  defdelegate reachable?(url_or_host), to: @adapter
  defdelegate set_reachable(url_or_host), to: @adapter

  defdelegate set_unreachable(url_or_host, unreachable_since \\ nil),
    to: @adapter

  def set_consistently_unreachable(url_or_host),
    do: set_unreachable(url_or_host, reachability_datetime_threshold())

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
         {:ok, %Tesla.Env{status: 200, body: body}} <-
           Tesla.get(
             "https://#{instance_uri.host}/.well-known/nodeinfo",
             headers: [{"Accept", "application/json"}]
           ),
         {:ok, json} <- Jason.decode(body),
         {:ok, %{"links" => links}} <- {:ok, json},
         {:ok, %{"href" => href}} <-
           {:ok,
            Enum.find(links, &(&1["rel"] == "http://nodeinfo.diaspora.software/ns/schema/2.0"))},
         {:ok, %Tesla.Env{body: data}} <-
           HTTP.get(href, [{"accept", "application/json"}], []),
         {:length, true} <- {:length, String.length(data) < 50_000},
         {:ok, nodeinfo} <- Jason.decode(data) do
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
end
