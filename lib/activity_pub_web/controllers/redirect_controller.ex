defmodule ActivityPubWeb.RedirectController do
  # This entire module was pretty MN specific so need to figure out a way to make it generic

  use ActivityPubWeb, :controller

  def object(conn, %{"uuid" => _uuid}) do
    conn
    |> json("not implemented")
  end

  def actor(conn, %{"username" => _username}) do
    conn
    |> json("not implemented")
  end
end
