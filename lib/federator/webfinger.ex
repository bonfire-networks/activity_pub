# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.WebFinger do
  @moduledoc """
  Serves and fetches data (mainly actor URI) necessary for federation when only the username and host is known.
  """
  use Arrows
  import Untangle

  alias ActivityPub.Actor
  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Federator.HTTP
  alias ActivityPub.Federator.Publisher
  alias ActivityPub.Utils

  @doc """
  Fetches webfinger data for an account given in "@username@domain.tld" format.

  Pass `opts` to scope the instance-restriction check. The caller owns directionality and context:
  `direction: :out` for an outgoing interaction the local user initiates, plus `by_actor:` (an AP
  `Actor`) or `current_user:` (a local user) so per-user blocks apply. With no `direction`, the
  check falls back to blocking on *any* block type (a safe default for neutral/inbound lookups).
  """
  def finger(account, opts \\ []) do
    account = String.trim_leading(account, "@")

    with {:ok, base_url} <- remote_base_url(account),
         # apply instance restrictions here too, so we don't even attempt to discover (and thus leak  interest in / reach out to) an actor on a blocked/disallowed instance, honouring the direction and per-user/actor context the caller passes via opts
         # TODO: need to make sure all callers pass current actor/user in opts for this to also take into account user-level allows & blocks
         true <-
           Adapter.federation_allowed?(URI.parse(base_url), opts) ||
             {:error, :not_allowed},
         response <-
           HTTP.get(
             "#{base_url}/.well-known/webfinger?#{URI.encode_query(%{"resource" => "acct:#{account}"})}",
             [{"Accept", "application/jrd+json"}]
           ),
         {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 <-
           response,
         _ <- ActivityPub.Safety.HTTP.Signatures.maybe_cache_accept_signature(base_url, headers),
         {:ok, doc} <- Jason.decode(body) do
      webfinger_from_json(doc)
    else
      {:error, :not_allowed} = e ->
        debug(account, "WebFinger lookup blocked: instance is not allowed")
        e

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

  defp gather_links(%{data: %{"id" => id}}), do: gather_links(id)
  defp gather_links(%{"id" => id}), do: gather_links(id)

  defp gather_links(id) when is_binary(id) do
    [
      %{
        "rel" => "http://webfinger.net/rel/profile-page",
        "type" => "text/html",
        "href" => id
      }
    ] ++ Publisher.gather_webfinger_links(id)
  end

  def local_hostname,
    do: ActivityPub.Federator.Adapter.base_url() |> Utils.authority()

  defp remote_base_url(account) do
    {name, domain} =
      case String.split(account, "@") do
        [name, domain] ->
          {name, domain}

        ["", name, domain] ->
          {name, domain}

        _e ->
          #  TODO: can we parse the name?
          {nil, Utils.authority(account)}
      end
      |> debug()

    local = local_hostname()

    # also match bare hostname when local runs on a non-standard port (e.g. "localhost" matches "localhost:4000")
    local_host = local |> String.split(":") |> List.first()

    if local == domain or local_host == domain or domain == "localhost" do
      {:error, {:local_user, name}}
    else
      {:ok, Utils.base_url(domain)}
    end
  end

  @doc """
  Formats gathered data into a JRD format.
  """
  def represent_user(actor) do
    id = actor.data["id"]

    %{
      "subject" => "acct:#{Actor.format_username(actor.data)}",
      "aliases" => [id],
      "links" => gather_links(id)
    }
  end

  @doc """
  FEP-d556: Discover the server actor for a host via WebFinger.
  Queries `resource=https://host/` and extracts the `self` link.
  """
  def finger_host(%URI{} = uri) do
    base_url = Utils.base_url(uri)
    host = Utils.authority(uri)

    with {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 <-
           HTTP.get(
             "#{base_url}/.well-known/webfinger?#{URI.encode_query(%{"resource" => base_url})}",
             [{"Accept", "application/jrd+json"}]
           ),
         _ <-
           ActivityPub.Safety.HTTP.Signatures.maybe_cache_accept_signature(host, headers),
         {:ok, doc} <- Jason.decode(body),
         %{"href" => service_actor_uri} <-
           Enum.find(doc["links"] || [], fn link ->
             link["rel"] == "self" and
               link["type"] in [
                 "application/activity+json",
                 "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""
               ]
           end) do
      {:ok, service_actor_uri}
    else
      _ -> {:error, :not_found}
    end
  end

  def finger_host(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.host do
      finger_host(uri)
    else
      # Bare hostname like "example.com" — URI.parse misparses it
      scheme = if String.starts_with?(url, "localhost"), do: "http", else: "https"
      finger_host(URI.parse("#{scheme}://#{url}"))
    end
  end

  @doc "Processes an incoming webfinger JSON document into a map of useful data."
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
