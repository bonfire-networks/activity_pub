defmodule ActivityPubWeb.RedirectController do
  use ActivityPubWeb, :controller

  alias ActivityPub.Adapter

  def object(conn, %{"uuid" => uuid}) do
    object = ActivityPub.Object.get_by_id(uuid)

    case Adapter.get_redirect_url(object) do
      nil ->
        conn
        |> send_resp(404, "Object not found or not permitted")
        |> halt

      url ->
        conn
        |> redirect(to: url)
    end
  end

  def actor(conn, %{"username" => username}) do
    case Adapter.get_redirect_url(username) do
      nil ->
        conn
        |> send_resp(404, "Actor not found")
        |> halt

      url ->
        conn
        |> redirect(to: url)
    end
  end
end
