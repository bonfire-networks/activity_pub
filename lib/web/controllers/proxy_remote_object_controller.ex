defmodule ActivityPub.Web.ProxyRemoteObjectController do
  use ActivityPub.Web, :controller

  @doc """
  Proxies a remote ActivityStreams object given by the `id` parameter.

  ## Examples

      POST /proxy
      Content-Type: application/x-www-form-urlencoded

      id=https://remote.server/object/123

  Returns the fetched object as JSON, or an error if not found or fetch fails.
  """
  def proxy(conn, %{"id" => id}) when is_binary(id) do
    validate_actor_auth!(conn)

    # TODO: should this fetch remote objects if not in cache?
    object =
      ActivityPub.Object.get_cached!(id: id)

    if object do
      conn
      |> put_resp_content_type("application/activity+json")
      |> send_resp(200, Jason.encode!(object))
    else
      raise :not_found
    end
  end

  def proxy(conn, _params) do
    raise :bad_request
  end

  def validate_actor_auth!(conn) do
    if conn.assigns[:current_user] do
      :ok
    else
      raise :unauthorized
    end
  end
end
