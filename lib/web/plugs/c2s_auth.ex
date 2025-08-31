defmodule ActivityPub.Web.Plugs.C2SAuth do
  @moduledoc """
  Authentication plug for ActivityPub Client-to-Server API.
  
  Wraps the existing OAuth/Bearer token authentication from bonfire_open_id
  and adds scope validation specific to ActivityPub C2S operations.
  """
  
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2, put_status: 2]
  
  alias Bonfire.OpenID.Plugs.Authorize
  
  @doc """
  Initialize the plug with options.
  """
  def init(opts), do: opts
  
  @doc """
  Loads authorization for C2S API endpoints.
  
  Requires a valid Bearer token and checks for appropriate scopes.
  Returns 401 Unauthorized if authentication fails.
  """
  def call(conn, opts) do
    case Authorize.maybe_load_authorization(conn, []) do
      %Plug.Conn{} = authed_conn ->
        maybe_authorize_scopes(authed_conn, opts)
      
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Bearer token required for Client-to-Server API"})
        |> halt()
    end
  end
  
  defp maybe_authorize_scopes(conn, opts) do
    required_scopes = Keyword.get(opts, :scopes, [])
    
    if Enum.empty?(required_scopes) do
      conn
    else
      try do
        Authorize.authorize(conn, required_scopes)
      rescue
        Bonfire.Fail ->
          conn
          |> put_status(:forbidden)
          |> json(%{
            error: "Insufficient scope",
            error_description: "Required scopes: #{Enum.join(required_scopes, ", ")}"
          })
          |> halt()
      end
    end
  end
end