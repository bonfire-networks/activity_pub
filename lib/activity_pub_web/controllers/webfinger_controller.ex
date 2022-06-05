# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.WebFingerController do
  use ActivityPubWeb, :controller

  alias ActivityPub.WebFinger

  def webfinger(conn, %{"resource" => resource}) do
    with {:ok, response} <- WebFinger.output(resource) do
      json(conn, response)
    else
      _e ->
        conn
        |> put_status(404)
        |> json("Could not find user")
    end
  end
end
