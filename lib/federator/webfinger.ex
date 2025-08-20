# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.WebFinger do
  @moduledoc """
  Serves and fetches data (mainly actor URI) necessary for federation when only the username and host is known.
  """
  use Arrows
  import Untangle

  alias ActivityPub.Actor
  alias ActivityPub.Federator.HTTP
  alias ActivityPub.Federator.Publisher

  @doc """
  Fetches webfinger data for an account given in "@username@domain.tld" format.
  """
  def finger(account) do
    account = String.trim_leading(account, "@")

    with {:ok, base_url} <- remote_base_url(account),
         response <-
           HTTP.get(
             "#{base_url}/.well-known/webfinger?#{URI.encode_query(%{"resource" => "acct:#{account}"})}",
             [{"Accept", "application/jrd+json"}]
           ),
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           response,
         {:ok, doc} <- Jason.decode(body) do
      webfinger_from_json(doc)
    else
      {:error, {:local_user, name}} ->
        output(name || account)
        ~> webfinger_from_json()

      {:error, {:options, :incompatible, [verify: :verify_peer, cacerts: :undefined]}} ->
        error("No SSL certificates available")

      {:error, e} when is_binary(e) ->
        error(e)

      e ->
        error(e, "Could not finger #{account}")
        {:error, e}
    end
  end

  @doc """
  Serves a webfinger response for the requested username.
  """
  def output("acct:" <> resource), do: output(resource)

  def output("http" <> _ = url) do
    with {:ok, actor} <- Actor.get_cached(ap_id: url) do
      {:ok, represent_user(actor)}
    else
      _ ->
        {:error, "Could not find such a user"}
    end
  end

  def output(resource) do
    with %{"username" => username} <-
           Regex.named_captures(
             ~r/(?<username>[a-z0-9A-Z_\.-]+)@#{local_hostname()}/,
             resource
           ) ||
             Regex.named_captures(~r/(?<username>[a-z0-9A-Z_\.-]+)/, resource),
         {:ok, actor} <- Actor.get_cached(username: username) do
      {:ok, represent_user(actor)}
    else
      _ ->
        {:error, "Could not find such a user"}
    end
  end

  defp gather_links(actor) do
    [
      %{
        "rel" => "http://webfinger.net/rel/profile-page",
        "type" => "text/html",
        "href" => actor.data["id"]
      }
    ] ++ Publisher.gather_webfinger_links(actor)
  end

  def local_hostname,
    do: ActivityPub.Federator.Adapter.base_url() |> hostname_with_optional_port() |> debug()

  defp hostname_with_optional_port(%{} = uri) do
    if uri.port not in [80, 443], do: "#{uri.host}:#{uri.port}", else: uri.host
  end

  defp hostname_with_optional_port(url), do: URI.parse(url) |> hostname_with_optional_port()

  defp remote_base_url(account) do
    {name, domain} =
      case String.split(account, "@") do
        [name, domain] ->
          {name, domain}

        ["", name, domain] ->
          {name, domain}

        _e ->
          #  TODO: can we parse the name?
          {nil, hostname_with_optional_port(account)}
      end
      |> debug()

    if local_hostname() == domain do
      {:error, {:local_user, name}}
    else
      # TODO: don't assume
      {:ok,
       if(String.starts_with?(domain, "localhost"),
         do: "http://#{domain}",
         else: "https://#{domain}"
       )}
    end
  end

  @doc """
  Formats gathered data into a JRD format.
  """
  def represent_user(actor) do
    %{
      "subject" => "acct:#{Actor.format_username(actor.data)}",
      "aliases" => [actor.data["id"]],
      "links" => gather_links(actor)
    }
  end

  def webfinger_from_json(doc) do
    data =
      Enum.reduce(doc["links"], %{"subject" => doc["subject"]}, fn link, data ->
        case {link["type"], link["rel"]} do
          {"application/activity+json", "self"} ->
            Map.put(data, "id", link["href"])

          {"application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"", "self"} ->
            Map.put(data, "id", link["href"])

          {_, "magic-public-key"} ->
            "data:application/magic-public-key," <> magic_key = link["href"]
            Map.put(data, "magic_key", magic_key)

          {"application/atom+xml", "http://schemas.google.com/g/2010#updates-from"} ->
            Map.put(data, "topic", link["href"])

          {_, "salmon"} ->
            Map.put(data, "salmon", link["href"])

          {_, "http://ostatus.org/schema/1.0/subscribe"} ->
            Map.put(data, "subscribe_address", link["template"])

          _ ->
            warn(link["type"], "Unhandled webfinger link type")
            data
        end
      end)

    {:ok, data}
  end
end
