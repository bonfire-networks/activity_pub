defmodule ActivityPub.Signature do
  @behaviour HTTPSignatures.Adapter
  import Untangle
  alias ActivityPub.Actor
  alias ActivityPub.Keys
  alias ActivityPub.Fetcher

  def key_id_to_actor_id(key_id) do
    uri =
      URI.parse(key_id)
      |> Map.put(:fragment, nil)

    uri =
      if not is_nil(uri.path) and String.ends_with?(uri.path, "/publickey") do
        Map.put(uri, :path, String.replace(uri.path, "/publickey", ""))
      else
        uri
      end

    URI.to_string(uri)
  end

  def fetch_public_key(conn) do
    with %{"keyId" => kid} <- HTTPSignatures.signature_for_conn(conn) |> info,
         actor_id <- key_id_to_actor_id(kid) |> info,
         {:ok, public_key} <- Actor.get_public_key_for_ap_id(actor_id) |> info do
      {:ok, public_key}
    else
      e ->
        error(e)
        # return ok so that HTTPSignatures calls `refetch_public_key/1`
        {:ok, nil}
    end
  end

  def refetch_public_key(conn) do
    with %{"keyId" => kid} <- HTTPSignatures.signature_for_conn(conn),
         actor_id <- key_id_to_actor_id(kid),
         # Ensure the remote actor is freshly fetched before updating
         {:ok, actor} <- Fetcher.fetch_fresh_object_from_id(actor_id) |> info,
         #  {:ok, actor} <- Actor.update_actor(actor_id) |> info,
         # FIXME: This might update the actor twice in a row ^
         {:ok, actor} <- Actor.update_actor(actor_id, actor) |> info,
         {:ok, public_key} <- Actor.get_public_key_for_ap_id(actor) do
      {:ok, public_key}
    else
      e ->
        {:error, e}
    end
  end

  def sign(actor, headers) do
    with {:ok, actor} <- Actor.ensure_keys_present(actor),
         keys <- actor.keys,
         {:ok, private_key, _} <- Keys.keys_from_pem(keys) do
      HTTPSignatures.sign(private_key, actor.data["id"] <> "#main-key", headers)
    end
  end
end
