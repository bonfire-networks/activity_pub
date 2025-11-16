# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.WebFingerController do
  use ActivityPub.Web, :controller
  import Untangle

  alias ActivityPub.Federator.WebFinger

  plug :rate_limit,
    key_prefix: :webfinger,
    scale_ms: 60_000,
    limit: 200

  def webfinger(conn, %{"resource" => resource}) do
    with {:ok, response} <- WebFinger.output(resource) do
      debug(response, "WebFinger response")

      json(conn, response)
    else
      e ->
        msg = "Could not find user"
        error(e, msg)

        conn
        |> put_status(404)
        |> json(msg)
    end
  end
end
