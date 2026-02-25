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

      conn
      |> ActivityPub.Utils.maybe_advertise_accept_signature()
      |> json(response)
    else
      e ->
        msg = "Could not find user"
        error(e, msg)

        conn
        |> put_status(404)
        |> json(msg)
    end
  end

  def webfinger(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"error" => "Missing required parameter: resource"})
  end

  @doc """
  Returns a compliant host-meta response per RFC 6415.
  This enables WebFinger discovery by providing the template URL.
  """
  def host_meta(conn, _params) do
    base_url = ActivityPub.Web.base_url()

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0">
      <Link rel="lrdd" template="#{base_url}/.well-known/webfinger?resource={uri}"/>
    </XRD>
    """

    conn
    |> put_resp_content_type("application/xrd+xml")
    |> send_resp(200, xml)
  end
end
