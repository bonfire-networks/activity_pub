# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.EnsurePublicOrAuthenticatedPlug do
  @moduledoc """
  Ensures instance publicity or _user_ authentication
  (app-bound user-unbound tokens are accepted only if the instance is public).
  """

  import Plug.Conn

  alias ActivityPub.Config

  def init(options) do
    options
  end

  @impl true
  def perform(conn, _) do
    public? = Config.get!([:instance, :public])

    case {public?, conn} do
      {true, _} ->
        conn

      {false, %{assigns: %{user: %{}}}} ->
        conn

      {false, _} ->
        conn
        |> Plug.Conn.put_status(:forbidden)
        |> Phoenix.Controller.json("This resource requires authentication.")
        |> halt
    end
  end
end
