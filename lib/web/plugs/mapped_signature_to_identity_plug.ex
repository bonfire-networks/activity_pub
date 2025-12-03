# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.MappedSignatureToIdentityPlug do
  alias ActivityPub.Safety.Keys
  alias Keys, as: Signature
  alias ActivityPub.Actor
  # alias ActivityPub.Utils
  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Object

  import Plug.Conn
  import Untangle

  def init(options), do: options

  def call(%{assigns: %{current_actor: %Actor{}, current_user: %{id: _}}} = conn, _opts), do: conn

  def call(
        %{assigns: %{current_actor: %Actor{pointer: %{id: _} = pointer} = _actor}} = conn,
        _opts
      ) do
    flood(pointer, "deriving current_user from current_actor")

    conn
    |> assign(:current_user, pointer)
  end

  # already authorized somehow? current_actor is set but current_user is not, so derive current_user from actor's pointer
  def call(%{assigns: %{current_actor: %Actor{pointer_id: pointer_id} = actor}} = conn, _opts) do
    case Adapter.get_actor_by_id(pointer_id) do
      {:ok, %Actor{pointer: pointer}} when not is_nil(pointer) ->
        flood(actor, "deriving current_user from current_actor")

        conn
        |> assign(:current_user, pointer)

      _ ->
        flood(actor, "could not derive current_user from current_actor, continuing without")

        conn
        |> assign(:valid_signature, false)
    end
  end

  # already authorized somehow? but we need an Actor and not just a user
  def call(%{assigns: %{current_user: %{id: pointer_id}}} = conn, _opts) do
    with {:ok, %Actor{} = actor} <- Actor.get_cached(pointer: pointer_id) do
      debug(actor, "found current_actor from current_user #{pointer_id}")

      conn
      |> assign(:current_actor, actor)
    else
      other ->
        flood(other, "Failed to find current Actor based on current_user")

        conn
        |> assign(:valid_signature, false)
    end
  end

  # if this has a POST payload make sure it is signed by the same actor that made it
  def call(%{assigns: %{valid_signature: true}, params: %{"actor" => actor}} = conn, _opts) do
    flood(actor, "verifying signature identity for payload actor")
    key_id = key_id_from_conn(conn)

    with actor_id <- Object.get_ap_id(actor),
         {:actor, %Actor{} = actor} <- {:actor, actor_from_key_id(key_id)},
         {:federate, true} <- {:federate, Adapter.federate_actor?(actor, :in)},
         {:actor_match, true} <- {:actor_match, actor.ap_id == actor_id} do
      conn
      |> assign(:current_actor, actor)
    else
      {:actor_match, false} ->
        flood("Failed to map identity from signature (payload actor mismatch)")
        debug("key_id=#{inspect(key_id)}, actor=#{inspect(actor)}")

        conn
        |> assign(:valid_signature, false)

      # remove me once testsuite uses mapped capabilities instead of what we do now
      {:actor, nil} ->
        flood("Failed to map identity from signature (lookup failure)")
        debug("key_id=#{inspect(key_id)}, actor=#{actor}")

        conn
        |> assign(:valid_signature, false)

      {:federate, false} ->
        flood("Identity from signature is instance blocked")
        debug("key_id=#{inspect(key_id)}, actor=#{actor}")

        conn
        |> assign(:valid_signature, nil)

      other ->
        flood(other, "Failed to verify signature identity (no pattern matched)")
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
        flood("Identity from signature is instance blocked")
        debug("key_id=#{inspect(key_id)}")

        conn
        |> assign(:valid_signature, nil)

      nil ->
        flood("Failed to map identity from signature (lookup failure)")
        debug("key_id=#{inspect(key_id)}")

        conn
        |> assign(:valid_signature, false)

      other ->
        flood(other, "Failed to verify signature identity (no pattern matched)")
        debug("key_id=#{inspect(key_id)}")

        conn
        |> assign(:valid_signature, false)
    end
  end

  # no signature at all
  def call(conn, _opts), do: conn

  defp key_id_from_conn(conn) do
    with %{"keyId" => key_id} <- HTTPSignatures.extract_signature(conn) do
      key_id
    else
      _ ->
        nil
    end
  end

  defp actor_from_key_id(key_actor_id) do
    with {:ok, ap_id} <- Signature.key_id_to_actor_id(key_actor_id),
         {:ok, %Actor{} = actor} <-
           is_binary(key_actor_id) and Actor.get_cached(ap_id: ap_id) do
      actor
    else
      _ ->
        nil
    end
  end
end
