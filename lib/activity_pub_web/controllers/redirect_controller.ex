defmodule ActivityPubWeb.RedirectController do
  use ActivityPubWeb, :controller

  alias ActivityPub.Adapter

  def object(conn, %{"uuid" => uuid}) do
    object = ActivityPub.Object.get_by_id(uuid)

    case object.pointer_id do
      nil ->
        conn
        |> json("not found")

      pointer_id ->
        case Adapter.get_redirect_url(object) do
          nil ->
            conn
            |> json("not found")

          url ->
            conn
            |> redirect(to: url)
        end
    end
  end

  def actor(conn, %{"username" => username}) do
    case Adapter.get_redirect_url(username) do
      nil ->
        conn
        |> json("not found")

      url ->
        conn
        |> redirect(to: url)
    end
  end
end
