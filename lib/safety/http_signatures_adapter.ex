defmodule ActivityPub.Safety.HTTP.Signatures do
  @moduledoc """
  Implementation for behaviour from `HTTPSignatures` library.

  Also provides signature format discovery helpers for adaptive signing
  (RFC 9421 vs draft-cavage), using Cachex for per-host format caching
  and FEP-844e for capability detection.
  """
  @behaviour HTTPSignatures.Adapter

  import Untangle
  use Arrows

  alias ActivityPub.Safety.Keys
  alias ActivityPub.Federator.Fetcher

  @cache :ap_sig_format_cache
  @rfc9421_uri "https://datatracker.ietf.org/doc/html/rfc9421"

  @doc "Get public key from local cache/DB"
  def get_public_key(%Plug.Conn{} = conn) do
    with %{"keyId" => key_id} <- HTTPSignatures.extract_signature(conn) do
      get_public_key(key_id)
    end
  end

  def get_public_key(key_id) do
    with {:ok, actor_id} <- Keys.key_id_to_actor_id(key_id) |> debug("actor_id"),
         {:ok, public_key} <-
           Keys.get_public_key_for_ap_id(actor_id)
           |> debug("public_key after get_public_key_for_ap_id"),
         {:ok, decoded} <- Keys.public_key_decode(public_key) do
      {:ok, decoded}
    else
      e ->
        error(e)
        # return ok so that HTTPSignatures calls `fetch_fresh_public_key/1`
        {:ok, nil}
    end
  end

  @doc "Get or fetch public key from local cache/DB"
  def fetch_public_key(%Plug.Conn{} = conn) do
    with %{"keyId" => key_id} <- HTTPSignatures.extract_signature(conn) do
      fetch_public_key(key_id)
    end
  end

  def fetch_public_key(key_id) do
    with {:ok, actor_id} <- Keys.key_id_to_actor_id(key_id),
         {:ok, public_key} <-
           Keys.fetch_public_key_for_ap_id(actor_id)
           |> debug("public_key after get_public_key_for_ap_id"),
         {:ok, decoded} <- Keys.public_key_decode(public_key) do
      {:ok, decoded}
    else
      e ->
        error(e)
        # return ok so that HTTPSignatures calls `fetch_fresh_public_key/1`
        {:ok, nil}
    end
  end

  @doc "Fetch public key from remote actor"
  def fetch_fresh_public_key(%Plug.Conn{} = conn) do
    with %{"keyId" => key_id} <- HTTPSignatures.extract_signature(conn) do
      fetch_fresh_public_key(key_id)
    end
  end

  def fetch_fresh_public_key(key_id) do
    with {:ok, actor_id} <- Keys.key_id_to_actor_id(key_id),
         # Ensure the remote actor is freshly fetched before updating
         {:ok, actor} <- Fetcher.fetch_fresh_object_from_id(actor_id),
         #  {:ok, actor} <- Actor.update_actor(actor_id, actor) |> debug,
         {:ok, public_key} <- Keys.fetch_public_key_for_ap_id(actor),
         {:ok, decoded} <- Keys.public_key_decode(public_key) do
      {:ok, decoded}
    else
      e ->
        error(e)
    end
  end

  # --- Signature format discovery helpers ---

  @doc """
  Gets the cached signature format for a host.

  Returns `:rfc9421`, `:cavage`, or `nil` if unknown.
  """
  def get_signature_format(host) when is_binary(host) do
    case Cachex.get(@cache, host) do
      {:ok, format} when format in [:rfc9421, :cavage] -> format
      _ -> nil
    end
  end

  def get_signature_format(_), do: nil

  @doc """
  Caches the signature format for a host.
  """
  def put_signature_format(host, format) when is_binary(host) and format in [:rfc9421, :cavage] do
    Cachex.put(@cache, host, format)
  end

  def put_signature_format(_, _), do: :ok

  @doc """
  Checks if actor data advertises RFC 9421 support via FEP-844e.

  Looks for `@rfc9421_uri` in `actor.generator.implements` (user actors),
  or directly in `actor.implements` (Application/service actors which are
  themselves the generator).
  """
  def supports_rfc9421?(%{"generator" => generator}) when is_map(generator) do
    has_rfc9421_implements?(generator)
  end

  # Application/service actors have `implements` directly (they are the generator)
  def supports_rfc9421?(%{"implements" => _} = data) do
    has_rfc9421_implements?(data)
  end

  def supports_rfc9421?(_), do: false

  defp has_rfc9421_implements?(data) when is_map(data) do
    case data["implements"] do
      implements when is_list(implements) ->
        Enum.any?(implements, &rfc9421_implement?/1)

      implement when is_map(implement) ->
        rfc9421_implement?(implement)

      _ ->
        false
    end
  end

  defp rfc9421_implement?(%{"id" => id}) when is_binary(id) do
    String.contains?(id, "rfc9421")
  end

  defp rfc9421_implement?(%{"href" => href}) when is_binary(href) do
    String.contains?(href, "rfc9421")
  end

  defp rfc9421_implement?(uri) when is_binary(uri) do
    String.contains?(uri, "rfc9421")
  end

  defp rfc9421_implement?(_), do: false

  @doc """
  Extracts service_actor_uri and RFC 9421 support from actor data.

  Handles two cases:
  - User actors with a `generator` field (FEP-844e) pointing to the Application
  - Application/service actors with `implements` directly on themselves
  """
  def maybe_extract_generator_info(host, %{"generator" => generator} = _data)
      when is_binary(host) and is_map(generator) do
    # Store service_actor_uri if present
    service_actor_uri = generator["id"]

    if is_binary(service_actor_uri) do
      ActivityPub.Instances.Instance.set_service_actor_uri(host, service_actor_uri)
    end

    # Check FEP-844e implements for RFC 9421
    if has_rfc9421_implements?(generator) do
      put_signature_format(host, :rfc9421)
    end
  end

  # Application/service actors have `implements` directly
  def maybe_extract_generator_info(host, %{"implements" => _} = data)
      when is_binary(host) do
    if has_rfc9421_implements?(data) do
      put_signature_format(host, :rfc9421)
    end
  end

  def maybe_extract_generator_info(_, _), do: :ok

  @doc """
  Determines the signature format to use for a given host.

  Checks (in order):
  1. Cachex cache
  2. FEP-844e on recipient actor data (if provided)
  3. Stored service actor in DB
  4. Default to `:cavage`
  """
  def determine_signature_format(host, recipient_actor_data \\ nil) do
    with nil <- get_signature_format(host),
         false <- check_fep844e(host, recipient_actor_data),
         false <- check_stored_service_actor(host) do
      :cavage
    end
  end

  defp check_fep844e(host, %{"generator" => _} = actor_data) do
    if supports_rfc9421?(actor_data) do
      put_signature_format(host, :rfc9421)
      :rfc9421
    else
      false
    end
  end

  defp check_fep844e(_host, _), do: false

  defp check_stored_service_actor(host) do
    with %{service_actor_uri: uri} when is_binary(uri) <-
           ActivityPub.Instances.Instance.get_by_host(host),
         {:ok, %{data: actor_data}} <- ActivityPub.Actor.get_cached(ap_id: uri) do
      # Check both generator.implements (user actors pointing to the app)
      # and implements directly (the service/Application actor itself)
      if supports_rfc9421?(actor_data) do
        put_signature_format(host, :rfc9421)
        :rfc9421
      else
        false
      end
    else
      _ -> false
    end
  end

  @doc """
  Checks response headers for `Accept-Signature` (RFC 9421 §5.1) and caches the format if present. Works with both GET and POST responses.

  Accepts either a `%{headers: list}` response struct or a plain headers list, plus a host string or URI/URL to extract the host from.
  """
  def maybe_cache_accept_signature(host_or_uri, %{headers: headers}) when is_list(headers) do
    maybe_cache_accept_signature(host_or_uri, headers)
  end

  def maybe_cache_accept_signature(host_or_uri, headers) when is_list(headers) do
    if Enum.any?(headers, fn {k, _v} -> String.downcase(k) == "accept-signature" end) do
      host = extract_host(host_or_uri)

      if is_binary(host) do
        put_signature_format(host, :rfc9421)
      else
        :ok
      end
    else
      :ok
    end
  end

  def maybe_cache_accept_signature(_, _), do: :ok

  defp extract_host(%URI{host: host}) when is_binary(host), do: host

  defp extract_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      # Plain hostname without scheme (e.g. "example.com")
      _ -> url
    end
  end

  defp extract_host(_), do: nil
end
