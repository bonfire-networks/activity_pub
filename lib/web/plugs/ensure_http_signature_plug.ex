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

  def call(%{assigns: %{valid_signature: true}} = conn, _), do: conn

  def call(%{assigns: %{valid_signature: nil}} = conn, _) do
    info("Rejecting ActivityPub request from blocked actor/instance")
    debug(conn)
    ignore(conn)
  end

  def call(conn, _) do
    maybe_reject!(
      conn,
      conn.method != "POST" and Phoenix.Controller.get_format(conn) != "html" and
        Config.get([:activity_pub, :reject_unsigned], false)
    )
  end

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

  def ignore(conn) do
    conn
    |> Phoenix.Controller.text("OK")
    |> halt()
  end
end
