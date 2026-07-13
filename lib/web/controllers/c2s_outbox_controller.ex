defmodule ActivityPub.Web.C2SOutboxController do
  @moduledoc """
  Controller for ActivityPub Client-to-Server (C2S) API outbox endpoints.

  Handles POST requests to actor outboxes.
  """

  use ActivityPub.Web, :controller
  import Untangle

  alias ActivityPub.{Object, Utils}
  alias ActivityPub.C2S
  alias ActivityPub.Federator.Adapter

  plug :rate_limit, key_prefix: :c2s

  @doc """
  Handles POST requests to /actors/:username/outbox (and the new-scheme
  /<type>/:actor_id/outbox) for C2S API.
  """
  def create(conn, %{"actor_id" => _} = _params), do: do_create(conn)
  def create(conn, %{"username" => _username} = _params), do: do_create(conn)

  defp do_create(conn) do
    # TODO: uncomment when scope validation is implemented
    # required_scopes = ["write:statuses"]
    # with true <- validate_authorized_scopes(conn, required_scopes) || {:error, :insufficient_scopes} do

    # the posted activity is read from `conn.body_params`, NOT the merged params: Phoenix merges
    # router path params in, which would inject fields into the activity (a path `:id`/`:username`
    # would land in the activity). `handle_c2s_activity` takes identity from the authenticated
    # `current_actor`, so no path param is needed.
    with {:ok, activity} <-
           C2S.handle_c2s_activity(conn.assigns[:current_actor], conn.body_params) do
      conn
      |> put_status(:created)
      |> maybe_put_location_header(activity)
      |> json(activity_to_json(activity))
    else
      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Please sign in to perform this action"})
        |> halt()

      {:error, :actor_mismatch} ->
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
          error_description: "Required scopes for this action"
        })
        |> halt()

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Object not found"})
        |> halt()

      {:error, :invalid_activity} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Invalid activity"})

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})

      {:error, reason} ->
        error(reason, "C2S activity processing failed")

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

  defp activity_to_json(%Object{data: data}), do: data
  defp activity_to_json(%{data: data}), do: data
  defp activity_to_json(data) when is_map(data), do: data

  defp maybe_put_location_header(conn, activity) do
    case get_activity_url(activity) do
      nil -> conn
      url -> put_resp_header(conn, "location", url)
    end
  end

  defp get_activity_url(%Object{data: %{"id" => id}}), do: id
  defp get_activity_url(%{data: %{"id" => id}}), do: id
  defp get_activity_url(%{"id" => id}), do: id
  defp get_activity_url(%Object{id: id}), do: Object.object_url(id)
  defp get_activity_url(_), do: nil

  # Scope validation - can be extended via adapter callback if needed
  defp validate_authorized_scopes(conn, required_scopes) do
    required_scopes = List.wrap(required_scopes)

    Enum.empty?(required_scopes) or
      Adapter.call_or(:validate_authorized_scopes, [conn, required_scopes], true)
  end
end
