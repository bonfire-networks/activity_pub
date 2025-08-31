defmodule ActivityPub.Web.C2SOutboxController do
  @moduledoc """
  Controller for ActivityPub Client-to-Server (C2S) API outbox endpoints.
  
  Handles POST requests to actor outboxes, translating ActivityPub activities
  into Bonfire's internal format and delegating to existing modules.
  """
  
  use ActivityPub.Web, :controller
  import Untangle
  
  alias Bonfire.Posts
  alias ActivityPub.{Object, Utils}
  alias ActivityPub.Web.C2SFormatter
  
  @doc """
  Handles POST requests to /actors/:username/outbox for C2S API.
  
  Validates the authenticated user matches the actor, formats the ActivityPub
  activity, and delegates to appropriate Bonfire modules.
  """
  def create(conn, %{"username" => username} = params) do
    current_user = conn.assigns.current_user
    
    with :ok <- validate_actor_match(current_user, username),
         {:ok, activity_type, formatted_attrs} <- C2SFormatter.format_activity(params, current_user),
         {:ok, result} <- dispatch_activity(activity_type, formatted_attrs, current_user, params) do
      
      conn
      |> put_status(:created)
      |> put_resp_header("location", get_activity_url(result))
      |> json(prepare_response(result, activity_type))
      
    else
      {:error, :actor_mismatch} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Actor does not match authenticated user"})
        
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
        |> json(%{error: "Failed to create activity"})
    end
  end
  
  
  # Handle malformed requests
  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Invalid request format"})
  end
  
  defp validate_actor_match(user, username) do
    user_username = get_in(user, [:character, :username]) || Map.get(user, :username)
    
    if user_username == username do
      :ok
    else
      {:error, :actor_mismatch}
    end
  end
  
  defp dispatch_activity("Create", attrs, user, _params) do
    # Convert Create activities to Bonfire posts for better integration
    Posts.publish(
      current_user: user, 
      post_attrs: attrs,
      boundary: "public"
    )
  end
  
  # Process activities through APActivities for proper Bonfire integration
  defp dispatch_activity(_activity_type, _attrs, user, params) do
    # Store in ap_object for C2S inbox compliance
    with {:ok, object} <- ActivityPub.Object.insert(params, true) do
      # Also create APActivity for Bonfire UI display
      case Bonfire.Social.APActivities.ap_receive(user, params, nil, true) do
        {:ok, _apactivity} -> 
          {:ok, object}
        {:error, _reason} -> 
          # Still return success if ap_object was created
          {:ok, object}
      end
    end
  end
  
  defp get_activity_url(%ActivityPub.Object{data: data, id: id}) do
    Map.get(data, "id") || Object.object_url(id)
  end
  
  defp prepare_response(%ActivityPub.Object{data: data}, _activity_type) do
    data
  end
  
end