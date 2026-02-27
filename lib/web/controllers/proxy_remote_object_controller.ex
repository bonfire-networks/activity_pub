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
    with :ok <- actor_authed?(conn),
         # this will fetch from cache if available, or fetch and store the and cache the JSON if not, but skip the adapter since the client just wants the raw object data and the app doesn't necessarily need to know about it
         {:ok, %{data: data}} <-
           ActivityPub.Federator.Fetcher.fetch_object_from_id(id, skip_adapter: true) do
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

  defp actor_authed?(%{assigns: %{current_user: %{} = _user}}) do
    :ok
  end

  defp actor_authed?(%{}) do
    {:error, :unauthorized}
  end
end
