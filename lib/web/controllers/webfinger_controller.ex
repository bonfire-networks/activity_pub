# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.WebFingerController do
  use ActivityPub.Web, :controller
  import Untangle

  alias ActivityPub.Federator.WebFinger

  @limit_num Application.compile_env(:activity_pub, __MODULE__, 200)
  @limit_ms Application.compile_env(:activity_pub, __MODULE__, 60_000)

  plug Hammer.Plug,
    rate_limit: {"activity_pub_api", @limit_ms, @limit_num},
    by: :ip,
    # when_nil: :raise,
    on_deny: &ActivityPub.Web.rate_limit_reached/2

  # when action == :object

  def webfinger(conn, %{"resource" => resource}) do
    with {:ok, response} <- WebFinger.output(resource) do
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
