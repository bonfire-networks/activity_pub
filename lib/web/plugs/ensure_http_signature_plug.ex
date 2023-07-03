# Akkoma: Magically expressive social media
# Copyright Â© 2022-2022 Akkoma Authors <https://akkoma.dev/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.EnsureHTTPSignaturePlug do
  @moduledoc """
  Ensures HTTP signature has been validated by previous plugs on ActivityPub requests.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [get_format: 1, text: 2]

  alias ActivityPub.Config

  def init(options) do
    options
  end

  def call(%{assigns: %{valid_signature: true}} = conn, _), do: conn

  def call(conn, _) do
    with true <- get_format(conn) in ["json", "activity+json"],
         true <- Config.get([:activitypub, :authorized_fetch_mode], true) do
      conn
      |> put_status(:unauthorized)
      |> text("Request not signed")
      |> halt()
    else
      _ -> conn
    end
  end
end
