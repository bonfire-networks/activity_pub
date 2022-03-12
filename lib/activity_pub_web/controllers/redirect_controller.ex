defmodule ActivityPubWeb.RedirectController do
  use ActivityPubWeb, :controller

  alias ActivityPub.Adapter
  alias ActivityPub.WebFinger

  def object(conn, %{"uuid" => uuid}) do
    object = ActivityPub.Object.get_cached_by_id(uuid)

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

  # incoming remote follow
  def remote_interaction(conn, %{"acct" => username_or_uri}) do
    with {:ok, actor} <- ActivityPub.Actor.get_or_fetch(username_or_uri) |> IO.inspect,
    url when is_binary(url) <- Adapter.get_redirect_url(actor) do
      conn
        |> put_flash(:info, "Press the follow button again to confirm that you want to follow this remote user.")
        |> redirect(to: url<>"?remote_interaction=follow")

    else _ ->
        conn
        |> send_resp(404, "Actor not found")
        |> halt
    end
  end

  # outgoing remote follow
  def remote_interaction(conn, %{"outgoing" => outgoing} = params) do
    me = Map.get(params, "me") || Map.get(outgoing, "me")
    user_to_follow = Map.get(params, "follow") || Map.get(outgoing, "follow")

    with {:ok, fingered} <- ActivityPub.WebFinger.finger(me) |> IO.inspect,
    %{"subscribe_address" => subscribe_address} when is_binary(subscribe_address) <- fingered,
    true <- String.contains?(subscribe_address, "{uri}"),
    url <- String.replace(subscribe_address, "{uri}", user_to_follow) do
      conn
        |> redirect(external: url)

    else _ ->
        conn
        |> send_resp(404, "Sorry, your actor or remote interaction URL was not found")
        |> halt
    end
  end

end
