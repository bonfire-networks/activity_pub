defmodule ActivityPubWeb.ActivityPubController do
  @moduledoc """

  Endpoints for serving objects and collections, so the ActivityPub API can be used to read information from the server.

  Even though we store the data in AS format, some changes need to be applied to the entity before serving it in the AP REST response. This is done in `ActivityPubWeb.ActivityPubView`.
  """

  use ActivityPubWeb, :controller

  require Logger

  alias ActivityPub.Actor
  alias ActivityPub.Fetcher
  alias ActivityPub.Object
  alias ActivityPubWeb.ActorView
  alias ActivityPubWeb.Federator
  alias ActivityPubWeb.ObjectView
  alias ActivityPubWeb.RedirectController

  def ap_route_helper(uuid) do
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    ActivityPubWeb.base_url() <> ap_base_path <> "/objects/" <> uuid
  end

  def object(conn, %{"uuid" => uuid}) do
    if get_format(conn) == "html" do
      with nil <- RedirectController.object(uuid) do
        object_json(conn, %{"uuid" => uuid})
      else
        url -> redirect(conn, to: url)
      end
    else
      object_json(conn, %{"uuid" => uuid})
    end
  end

  defp object_json(conn, %{"uuid" => uuid}) do
    with ap_id <- ap_route_helper(uuid),
          %Object{} = object <- Object.get_cached_by_ap_id(ap_id) do

      if true == object.public do
        conn
        |> put_resp_content_type("application/activity+json")
        |> put_view(ObjectView)
        |> render("object.json", %{object: object})
      else
        conn
        |> put_status(401)
        |> json(%{error: "unauthorised"})
      end

    else
      _ ->
        conn
        |> put_status(404)
        |> json(%{error: "not found"})
    end
  end

  def actor(conn, %{"username" => username})do
    if get_format(conn) == "html" do
      with nil <- RedirectController.actor(username) do
        actor_json(conn, %{"username" => username})
      else
        url -> redirect(conn, to: url)
      end
    else
      actor_json(conn, %{"username" => username})
    end
  end

  def actor_json(conn, %{"username" => username}) do
    with {:ok, actor} <- Actor.get_cached_by_username(username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("actor.json", %{actor: actor})
    else
      _ ->
        conn
        |> put_status(404)
        |> json(%{error: "not found"})
    end
  end

  def following(conn, %{"username" => username, "page" => page}) do
    with {:ok, actor} <- Actor.get_cached_by_username(username) do
      {page, _} = Integer.parse(page)

      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("following.json", %{actor: actor, page: page})
    end
  end

  def following(conn, %{"username" => username}) do
    with {:ok, actor} <- Actor.get_cached_by_username(username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("following.json", %{actor: actor})
    end
  end

  def followers(conn, %{"username" => username, "page" => page}) do
    with {:ok, actor} <- Actor.get_cached_by_username(username) do
      {page, _} = Integer.parse(page)

      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("followers.json", %{actor: actor, page: page})
    end
  end

  def followers(conn, %{"username" => username}) do
    with {:ok, actor} <- Actor.get_cached_by_username(username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("followers.json", %{actor: actor})
    end
  end

  def inbox(%{assigns: %{valid_signature: true}} = conn, params) do
    Federator.incoming_ap_doc(params)
    json(conn, "ok")
  end

  # only accept relayed Creates
  def inbox(conn, %{"type" => "Create"} = params) do
    Logger.info(
      "Signature missing or not from author, relayed Create message, fetching object from source"
    )

    Fetcher.fetch_object_from_id(params["object"]["id"])

    json(conn, "ok")
  end

  # heck u mastodon
  def inbox(conn, %{"type" => "Delete"}) do
    json(conn, "ok")
  end

  def inbox(conn, params) do
    headers = Enum.into(conn.req_headers, %{})

    if String.contains?(headers["signature"], params["actor"]) do
      Logger.info(
        "Signature validation error for: #{params["actor"]}, make sure you are forwarding the HTTP Host header!"
      )

      Logger.info(inspect(conn.req_headers))
    end

    json(conn, dgettext("errors", "error"))
  end

  def noop(conn, _params) do
    json(conn, "ok")
  end
end
