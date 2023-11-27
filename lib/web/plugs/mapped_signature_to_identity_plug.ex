# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.MappedSignatureToIdentityPlug do
  alias ActivityPub.Helpers.AuthHelper
  alias ActivityPub.Safety.Keys
  alias Keys, as: Signature
  alias ActivityPub.Actor
  alias ActivityPub.Utils

  import Plug.Conn
  require Logger

  def init(options), do: options

  def call(%{assigns: %{user: %Actor{}}} = conn, _opts), do: conn

  # if this has payload make sure it is signed by the same actor that made it
  def call(%{assigns: %{valid_signature: true}, params: %{"actor" => actor}} = conn, _opts) do
    with actor_id <- Utils.get_ap_id(actor),
         {:user, %Actor{} = user} <- {:user, user_from_key_id(conn)},
         {:federate, true} <- {:federate, should_federate?(user)},
         {:user_match, true} <- {:user_match, user.ap_id == actor_id} do
      conn
      |> assign(:user, user)
      |> AuthHelper.skip_oauth()
    else
      {:user_match, false} ->
        Logger.debug("Failed to map identity from signature (payload actor mismatch)")
        Logger.debug("key_id=#{inspect(key_id_from_conn(conn))}, actor=#{inspect(actor)}")

        conn
        |> assign(:valid_signature, false)

      # remove me once testsuite uses mapped capabilities instead of what we do now
      {:user, nil} ->
        Logger.debug("Failed to map identity from signature (lookup failure)")
        Logger.debug("key_id=#{inspect(key_id_from_conn(conn))}, actor=#{actor}")

        conn
        |> assign(:valid_signature, false)

      {:federate, false} ->
        Logger.debug("Identity from signature is instance blocked")
        Logger.debug("key_id=#{inspect(key_id_from_conn(conn))}, actor=#{actor}")

        conn
        |> assign(:valid_signature, false)
    end
  end

  # no payload, probably a signed fetch
  def call(%{assigns: %{valid_signature: true}} = conn, _opts) do
    with %Actor{} = user <- user_from_key_id(conn),
         {:federate, true} <- {:federate, should_federate?(user)} do
      conn
      |> assign(:user, user)
      |> AuthHelper.skip_oauth()
    else
      {:federate, false} ->
        Logger.debug("Identity from signature is instance blocked")
        Logger.debug("key_id=#{inspect(key_id_from_conn(conn))}")

        conn
        |> assign(:valid_signature, false)

      nil ->
        Logger.debug("Failed to map identity from signature (lookup failure)")
        Logger.debug("key_id=#{inspect(key_id_from_conn(conn))}")

        only_permit_user_routes(conn)

      _ ->
        Logger.debug("Failed to map identity from signature (no payload actor mismatch)")
        Logger.debug("key_id=#{inspect(key_id_from_conn(conn))}")

        conn
        |> assign(:valid_signature, false)
    end
  end

  # no signature at all
  def call(conn, _opts), do: conn

  defp only_permit_user_routes(%{path_info: ["users", _]} = conn) do
    conn
    |> assign(:limited_ap, true)
  end

  defp only_permit_user_routes(conn) do
    conn
    |> assign(:valid_signature, false)
  end

  defp key_id_from_conn(conn) do
    with %{"keyId" => key_id} <- HTTPSignatures.signature_for_conn(conn),
         {:ok, ap_id} <- Signature.key_id_to_actor_id(key_id) do
      ap_id
    else
      _ ->
        nil
    end
  end

  defp user_from_key_id(conn) do
    with key_actor_id when is_binary(key_actor_id) <- key_id_from_conn(conn),
         {:ok, %Actor{} = user} <- Actor.get_cached_or_fetch(ap_id: key_actor_id) do
      user
    else
      _ ->
        nil
    end
  end

  defp should_federate?(%Actor{ap_id: ap_id}), do: should_federate?(ap_id)

  defp should_federate?(ap_id) do
    if Pleroma.Config.get([:activitypub, :authorized_fetch_mode], false) do
      Pleroma.Web.ActivityPub.Publisher.should_federate?(ap_id)
    else
      true
    end
  end
end
