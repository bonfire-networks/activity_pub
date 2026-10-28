# Akkoma: Magically expressive social media
# Copyright Â© 2022-2022 Akkoma Authors <https://akkoma.dev/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.EnsureHTTPSignaturePlug do
  @moduledoc """
  Ensures HTTP signature has been validated by previous plugs on ActivityPub requests.
  """
  import Plug.Conn
  import Untangle

  alias ActivityPub.Config

  def init(options) do
    options
  end

  def call(%{assigns: %{current_actor: %{}}} = conn, _opts) do
    # already authorized somehow?
    conn
  end

  def call(%{assigns: %{current_user: %{}}} = conn, _opts) do
    # already authorized somehow?
    conn
  end

  def call(%{assigns: %{valid_signature: true}} = conn, _), do: conn

  # a delivery from a blocked or non-allowlisted server is answered with a quiet 200, so the sender cannot tell it was refused
  def call(%{assigns: %{valid_signature: nil}, method: "POST"} = conn, _) do
    info("Rejecting ActivityPub request from blocked actor/instance")
    debug(conn)
    ignore(conn)
  end

  # a fetch is refused with a real status, so the asker does not take the answer for the object
  def call(%{assigns: %{valid_signature: nil}} = conn, _) do
    info("Refusing ActivityPub fetch from blocked actor/instance")
    debug(conn)
    forbidden(conn)
  end

  def call(conn, _) do
    maybe_reject!(
      conn,
      conn.method != "POST" and Phoenix.Controller.get_format(conn) != "html" and
        Config.reject_unsigned?() and not service_actor_request?(conn)
    )
  end

  # The service actor stays fetchable without a signature. Other servers read its public key to verify the fetches we sign as it, so if it needed a signature, two servers that both require one could never verify each other. Only evaluated for a request that would be refused anyway, since it may look the actor up.
  defp service_actor_request?(%{request_path: path}) do
    case ActivityPub.Utils.service_actor() do
      {:ok, %{ap_id: ap_id} = actor} when is_binary(ap_id) ->
        path in [URI.parse(ap_id).path, service_actor_alias_path(actor)]

      _ ->
        false
    end
  end

  defp service_actor_alias_path(%{username: username}) when is_binary(username),
    do: "#{URI.parse(ActivityPub.Utils.ap_base_url()).path}/actors/#{username}"

  defp service_actor_alias_path(_), do: nil

  def maybe_reject!(conn, false), do: conn
  def maybe_reject!(%{assigns: %{valid_signature: true}} = conn, _true), do: conn

  def maybe_reject!(conn, _true) do
    info("Rejecting ActivityPub request with invalid signature")
    debug(conn)
    unauthorized(conn)
  end

  def unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.text("Please include an HTTP Signature in your requests")
    |> halt()
  end

  def forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.text("Forbidden")
    |> halt()
  end

  def ignore(conn) do
    conn
    |> Phoenix.Controller.text("OK")
    |> halt()
  end
end
