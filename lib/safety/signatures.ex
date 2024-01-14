defmodule ActivityPub.Safety.Signatures do
  @moduledoc """
  Implementation for behaviour from `HTTPSignatures` library
  """
  @behaviour HTTPSignatures.Adapter

  import Untangle
  use Arrows

  # alias ActivityPub.Config
  # alias ActivityPub.Utils
  # alias ActivityPub.Actor
  alias ActivityPub.Safety.Keys
  alias ActivityPub.Federator.Fetcher

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
end
