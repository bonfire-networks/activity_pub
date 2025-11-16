defmodule ActivityPub.Web.C2SOutboxController do
  @moduledoc """
  Controller for ActivityPub Client-to-Server (C2S) API outbox endpoints.

  Handles POST requests to actor outboxes
  """

  use ActivityPub.Web, :controller
  import Untangle

  alias ActivityPub.{Object, Utils}
  alias ActivityPub.C2S

  plug :rate_limit, key_prefix: :c2s

  @doc """
  Handles POST requests to /actors/:username/outbox for C2S API.
  """
  def create(conn, %{"username" => username} = params) do
    required_scopes = ["write:statuses"]

    #  with  true <- C2S.validate_authorized_scopes(conn, required_scopes) || {:error, :insufficient_scopes}, # TODO: check scope?
    with {:ok, %ActivityPub.Object{data: data} = object} <- C2S.handle_c2s_activity(conn, params) do
      conn
      |> put_status(:created)
      # |> put_resp_header("location", get_activity_url(object))
      |> json(data)
    else
      false ->
        debug("Actor does not match authenticated user")

        conn
        |> put_status(:forbidden)
        |> json(%{error: "Actor does not match authenticated user"})
        |> halt()

      {:error, :insufficient_scopes} ->
        debug("Actor does not have scopes")

        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "Insufficient scope",
          error_description: "Required scopes: #{Enum.join(required_scopes, ", ")}"
        })
        |> halt()

      {:error, :unsupported_activity} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Unsupported activity type"})

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to process activity"})
    end
  end

  # Handle malformed requests
  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Invalid request format"})
  end

  defp get_activity_url(%ActivityPub.Object{data: data, id: id}) do
    Map.get(data, "id") || Object.object_url(id)
  end
end
