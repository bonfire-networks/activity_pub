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
    with :ok <- validate_actor_auth(conn),
         {:ok, %{data: data} = _object} <- ActivityPub.Object.get_cached(ap_id: id) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> send_resp(200, Jason.encode!(data))
    else
      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authentication required"})
        |> halt()

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Object not found"})
        |> halt()
    end
  end

  def proxy(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required 'id' parameter"})
    |> halt()
  end

  defp validate_actor_auth(conn) do
    if conn.assigns[:current_user] do
      :ok
    else
      {:error, :unauthorized}
    end
  end
end
