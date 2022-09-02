# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.WebFinger do
  @moduledoc """
  Serves and fetches data (mainly actor URI) necessary for federation when only the username and host is known.
  """

  alias ActivityPub.Actor
  alias ActivityPub.HTTP
  alias ActivityPubWeb.Federator.Publisher

  import Untangle

  @doc """
  Fetches webfinger data for an account given in "@username@domain.tld" format.
  """
  def finger(account) do
    account = String.trim_leading(account, "@")

    domain =
      with [_name, domain] <- String.split(account, "@") do
        domain
      else
        _e ->
          URI.parse(account).host
      end

    protocol = if Application.get_env(:activity_pub, :env) in [:test, :dev], do: "http", else: "https"

    address = "#{protocol}://#{domain}/.well-known/webfinger?resource=acct:#{account}"

    with response <-
           HTTP.get(
             address,
             Accept: "application/jrd+json"
           ),
         {:ok, %{status: status, body: body}} when status in 200..299 <- response,
         {:ok, doc} <- Jason.decode(body) do
      webfinger_from_json(doc)
    else
      e ->
        error(account, "Could not finger")
        warn(e)
        {:error, e}
    end
  end

  @doc """
  Serves a webfinger response for the requested username.
  """
  def output("acct:"<>resource), do: output(resource)
  def output(resource) do
    host = URI.parse(ActivityPub.Adapter.base_url()).host

    with %{"username" => username} <- Regex.named_captures(~r/(?<username>[a-z0-9A-Z_\.-]+)@#{host}/, resource) || Regex.named_captures(~r/(?<username>[a-z0-9A-Z_\.-]+)/, resource),
         {:ok, actor} <- Actor.get_cached_by_username(username) do
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

  @doc """
  Formats gathered data into a JRD format.
  """
  def represent_user(actor) do
    host = URI.parse(ActivityPub.Adapter.base_url()).host

    %{
      "subject" => "acct:#{actor.data["preferredUsername"]}@#{host}",
      "aliases" => [actor.data["id"]],
      "links" => gather_links(actor)
    }
  end

  defp webfinger_from_json(doc) do
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
