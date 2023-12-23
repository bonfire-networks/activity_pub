# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.MappedSignatureToIdentityPlug do
  alias ActivityPub.Helpers.AuthHelper
  alias ActivityPub.Safety.Keys
  alias Keys, as: Signature
  alias ActivityPub.Actor
  # alias ActivityPub.Utils
  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Object

  import Plug.Conn
  import Untangle

  def init(options), do: options

  def call(%{assigns: %{user: %Actor{}}} = conn, _opts), do: conn

  # if this has a POST payload make sure it is signed by the same actor that made it
  def call(%{assigns: %{valid_signature: true}, params: %{"actor" => actor}} = conn, _opts) do
    key_id = key_id_from_conn(conn)

    with actor_id <- Object.get_ap_id(actor),
         {:actor, %Actor{} = actor} <- {:actor, actor_from_key_id(key_id)},
         {:federate, true} <- {:federate, Adapter.federate_actor?(actor, :in)},
         {:actor_match, true} <- {:actor_match, actor.ap_id == actor_id} do
      conn
      |> assign(:current_actor, actor)
    else
      {:actor_match, false} ->
        info("Failed to map identity from signature (payload actor mismatch)")
        debug("key_id=#{inspect(key_id)}, actor=#{inspect(actor)}")

        conn
        |> assign(:valid_signature, false)

      # remove me once testsuite uses mapped capabilities instead of what we do now
      {:actor, nil} ->
        info("Failed to map identity from signature (lookup failure)")
        debug("key_id=#{inspect(key_id)}, actor=#{actor}")

        conn
        |> assign(:valid_signature, false)

      {:federate, false} ->
        info("Identity from signature is instance blocked")
        debug("key_id=#{inspect(key_id)}, actor=#{actor}")

        conn
        |> assign(:valid_signature, nil)

      other ->
        info(other, "Failed to verify signature identity (no pattern matched)")
        debug("key_id=#{inspect(key_id)}, actor=#{actor}")

        conn
        |> assign(:valid_signature, false)
    end
  end

  # no payload, probably a signed fetch
  def call(%{assigns: %{valid_signature: true}} = conn, _opts) do
    key_id = key_id_from_conn(conn)

    with %Actor{} = actor <- actor_from_key_id(key_id),
         {:federate, true} <- {:federate, Adapter.federate_actor?(actor)} do
      conn
      |> assign(:current_actor, actor)
    else
      {:federate, false} ->
        info("Identity from signature is instance blocked")
        debug("key_id=#{inspect(key_id)}")

        conn
        |> assign(:valid_signature, nil)

      nil ->
        info("Failed to map identity from signature (lookup failure)")
        debug("key_id=#{inspect(key_id)}")

        conn
        |> assign(:valid_signature, false)

      other ->
        info(other, "Failed to verify signature identity (no pattern matched)")
        debug("key_id=#{inspect(key_id)}")

        conn
        |> assign(:valid_signature, false)
    end
  end

  # no signature at all
  def call(conn, _opts), do: conn

  defp key_id_from_conn(conn) do
    with %{"keyId" => key_id} <- HTTPSignatures.signature_for_conn(conn),
         {:ok, ap_id} <- Signature.key_id_to_actor_id(key_id) do
      ap_id
    else
      _ ->
        nil
    end
  end

  defp actor_from_key_id(key_actor_id) do
    with {:ok, %Actor{} = user} <-
           is_binary(key_actor_id) and Actor.get_cached_or_fetch(ap_id: key_actor_id) do
      user
    else
      _ ->
        nil
    end
  end
end
