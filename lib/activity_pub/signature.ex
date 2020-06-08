# MoodleNet: Connecting and empowering educators worldwide
# Copyright © 2018-2020 Moodle Pty Ltd <https://moodle.com/moodlenet/>
# Contains code from Pleroma <https://pleroma.social/> and CommonsPub <https://commonspub.org/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Signature do
  @behaviour HTTPSignatures.Adapter

  alias ActivityPub.Actor
  alias ActivityPub.Keys

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
    with %{"keyId" => kid} <- HTTPSignatures.signature_for_conn(conn),
         actor_id <- key_id_to_actor_id(kid),
         {:ok, public_key} <- Actor.get_public_key_for_ap_id(actor_id) do
      {:ok, public_key}
    else
      e ->
        {:error, e}
    end
  end

  def refetch_public_key(conn) do
    with %{"keyId" => kid} <- HTTPSignatures.signature_for_conn(conn),
         actor_id <- key_id_to_actor_id(kid),
         # Ensure the actor is in the database before updating
         # This might potentially update the actor twice in a row
         # TODO: Fix that
         {:ok, _actor} <- Actor.get_or_fetch_by_ap_id(actor_id),
         {:ok, _actor} <- Actor.update_actor(actor_id),
         {:ok, public_key} <- Actor.get_public_key_for_ap_id(actor_id) do
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
