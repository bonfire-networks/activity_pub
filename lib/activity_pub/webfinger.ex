# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.WebFinger do
  @moduledoc """
  Serves and fetches data (mainly actor URI) necessary for federation when only the username and host is known.
  """

  alias ActivityPub.Actor
  alias ActivityPub.HTTP
  alias ActivityPubWeb.Federator.Publisher

  require Logger

  @doc """
  Serves a webfinger response for the requested username.
  """
  def webfinger(resource) do
    host = URI.parse(ActivityPub.Adapter.base_url()).host
    regex = ~r/(acct:)?(?<username>[a-z0-9A-Z_\.-]+)@#{host}/

    with %{"username" => username} <- Regex.named_captures(regex, resource),
         {:ok, actor} <- Actor.get_cached_by_username(username) do
      {:ok, represent_user(actor)}
    else
      _e ->
        case Actor.get_cached_by_ap_id(resource) do
          {:ok, actor} ->
            {:ok, represent_user(actor)}

          _ ->
            {:error, "Couldn't find"}
        end
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
    host = Application.get_env(:activity_pub, :instance)[:hostname]

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
            Logger.debug("Unhandled type: #{inspect(link["type"])}")
            data
        end
      end)

    {:ok, data}
  end

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

    address = "https://#{domain}/.well-known/webfinger?resource=acct:#{account}"

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
        Logger.debug(fn -> "Couldn't finger #{account}" end)
        Logger.debug(fn -> inspect(e) end)
        {:error, e}
    end
  end
end
