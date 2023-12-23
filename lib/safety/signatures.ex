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

  def fetch_public_key(conn) do
    with %{"keyId" => kid} <- HTTPSignatures.signature_for_conn(conn) |> debug("keyId"),
         {:ok, actor_id} <- Keys.key_id_to_actor_id(kid) |> debug("actor_id"),
         {:ok, public_key} <-
           Keys.get_public_key_for_ap_id(actor_id)
           |> debug("public_key after get_public_key_for_ap_id"),
         {:ok, decoded} <- Keys.public_key_decode(public_key) do
      {:ok, decoded}
    else
      e ->
        error(e)
        # return ok so that HTTPSignatures calls `refetch_public_key/1`
        {:ok, nil}
    end
  end

  def refetch_public_key(conn) do
    with %{"keyId" => kid} <- HTTPSignatures.signature_for_conn(conn),
         {:ok, actor_id} <- Keys.key_id_to_actor_id(kid) |> debug("SESESESE"),
         # Ensure the remote actor is freshly fetched before updating
         {:ok, actor} <- Fetcher.fetch_fresh_object_from_id(actor_id) |> debug,
         #  {:ok, actor} <- Actor.update_actor(actor_id, actor) |> debug,
         {:ok, public_key} <- Keys.get_public_key_for_ap_id(actor),
         {:ok, decoded} <- Keys.public_key_decode(public_key) do
      {:ok, decoded}
    else
      e ->
        error(e)
    end
  end
end
