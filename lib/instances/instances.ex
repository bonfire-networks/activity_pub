defmodule ActivityPub.Instances do
  @moduledoc "Instances context."

  @adapter ActivityPub.Instances.Instance

  defdelegate filter_reachable(urls_or_hosts), to: @adapter
  defdelegate reachable?(url_or_host), to: @adapter
  defdelegate set_reachable(url_or_host), to: @adapter

  defdelegate set_unreachable(url_or_host, unreachable_since \\ nil),
    to: @adapter

  def set_consistently_unreachable(url_or_host),
    do: set_unreachable(url_or_host, reachability_datetime_threshold())

  def reachability_datetime_threshold do
    federation_reachability_timeout_days =
      Application.get_env(:activity_pub, :instance)[
        :federation_reachability_timeout_day
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
end
