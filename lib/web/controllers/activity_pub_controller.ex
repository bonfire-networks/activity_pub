defmodule ActivityPub.Web.ActivityPubController do
  @moduledoc """

  Endpoints for serving objects and collections, so the ActivityPub API can be used to read information from the server.

  Even though we store the data in AS format, some changes need to be applied to the entity before serving it in the AP REST response. This is done in `ActivityPub.Web.ActivityPubView`.
  """

  use ActivityPub.Web, :controller

  import Untangle

  alias ActivityPub.Config
  alias ActivityPub.Actor
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Object
  alias ActivityPub.Utils
  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Instances
  alias ActivityPub.Safety.Containment

  alias ActivityPub.Web.ActorView
  alias ActivityPub.Federator
  alias ActivityPub.Web.ObjectView
  # alias ActivityPub.Web.RedirectController

  def ap_route_helper(uuid) do
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    ActivityPub.Web.base_url() <> ap_base_path <> "/objects/" <> uuid
  end

  def object(conn, %{"uuid" => uuid}) do
    if get_format(conn) == "html" do
      case Adapter.get_redirect_url(uuid) do
        "http" <> _ = url -> redirect(conn, external: url)
        url when is_binary(url) -> redirect(conn, to: url)
        _ -> object_json(conn, %{"uuid" => uuid})
      end
    else
      object_json(conn, %{"uuid" => uuid})
    end
  end

  defp object_json(conn, %{"uuid" => uuid}) do
    if Utils.is_ulid?(uuid) do
      # querying by pointer - handle local objects
      with {:ok, object} <-
             Object.get_cached(pointer: uuid) ||
               Adapter.maybe_publish_object(uuid),
           #  true <- object.id != uuid, # huh?
           #  current_user <- Map.get(conn.assigns, :current_user, nil) |> debug("current_user"), # TODO: should/how users make authenticated requested?
           # || Containment.visible_for_user?(object, current_user)) |> debug("public or visible for current_user?") do
           true <- object.public do
        conn
        |> put_resp_content_type("application/activity+json")
        |> put_view(ObjectView)
        |> render("object.json", %{object: object})
      else
        false ->
          warn(
            "someone attempted to fetch a non-public object, we acknowledge its existence but do not return it"
          )

          ret_error(conn, "authentication required", 401)

        e ->
          error(e, "Pointable object not found")
          ret_error(conn, "not found", 404)
      end
    else
      # query by UUID
      with ap_id <- ap_route_helper(uuid),
           {:ok, object} <- Object.get_cached(ap_id: ap_id),
           true <- object.public do
        conn
        |> put_resp_content_type("application/activity+json")
        |> put_view(ObjectView)
        |> render("object.json", %{object: object})
      else
        false ->
          warn(
            "someone attempted to fetch a non-public object, we acknowledge its existence but do not return it"
          )

          ret_error(conn, "authentication required", 401)

        _ ->
          ret_error(conn, "not found", 404)
      end
    end
  end

  def actor(conn, %{"username" => username}) do
    if get_format(conn) == "html" do
      case Adapter.get_redirect_url(username) do
        "http" <> _ = url -> redirect(conn, external: url)
        url when is_binary(url) -> redirect(conn, to: url)
        _ -> actor_json(conn, %{"username" => username})
      end
    else
      actor_json(conn, %{"username" => username})
    end
  end

  def actor_json(conn, %{"username" => username}) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("actor.json", %{actor: actor})
    else
      _ ->
        ret_error(conn, "not found", 404)
    end
  end

  def following(conn, %{"username" => username, "page" => page}) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("following.json", %{actor: actor, page: page_number(page)})
    end
  end

  def following(conn, %{"username" => username}) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("following.json", %{actor: actor})
    end
  end

  def followers(conn, %{"username" => username, "page" => page}) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("followers.json", %{actor: actor, page: page_number(page)})
    end
  end

  def followers(conn, %{"username" => username}) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("followers.json", %{actor: actor})
    end
  end

  def outbox(conn, %{"username" => username, "page" => page}) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ObjectView)
      |> render("outbox.json", %{actor: actor, page: page_number(page)})
    else
      e ->
        ret_error(conn, "Invalid actor", 500)
    end
  end

  def outbox(conn, %{"username" => username}) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ObjectView)
      |> render("outbox.json", %{actor: actor})
    end
  end

  def inbox(%{assigns: %{valid_signature: true}} = conn, params) do
    process_incoming(conn, params)
  end

  # accept (but verify) unsigned Creates
  def inbox(conn, %{"type" => "Create"} = params) do
    maybe_process_unsigned(conn, params)
  end

  def inbox(conn, params) do
    maybe_process_unsigned(conn, params)
  end

  def noop(conn, _params) do
    json(conn, "ok")
  end

  defp maybe_process_unsigned(conn, params) do
    if Config.federating?() do
      headers = Enum.into(conn.req_headers, %{})

      if is_binary(headers["signature"]) do
        if String.contains?(headers["signature"], params["actor"]) do
          error(
            headers,
            "Unknown HTTP signature validation error, will attempt re-fetching AP activity from source (note: make sure you are forwarding the HTTP Host header)"
          )
        else
          error(
            headers,
            "No match between actor (#{params["actor"]}) and the HTTP signature provided, will attempt re-fetching AP activity from source (note: make sure you are forwarding the HTTP Host header)"
          )
        end
      else
        error(
          params,
          "No HTTP signature provided, will attempt re-fetching AP activity from source (note: make sure you are forwarding the HTTP Host header)"
        )
      end

      with {:ok, object} <-
             Fetcher.fetch_object_from_id(params["id"]) do
        debug(object, "unsigned activity workaround worked")

        ret_error(
          conn,
          "please send signed activities - object was not accepted as-in and instead re-fetched from origin",
          202
        )
      else
        e ->
          error(
            e,
            "Reject incoming federation: HTTP Signature missing or not from author, AND we couldn't fetch a non-public object without authentication."
          )

          ret_error(conn, "please send signed activities - activity was rejected", 401)
      end
    else
      ret_error(conn, "this instance is not currently federating", 403)
    end
  end

  defp process_incoming(conn, params) do
    Logger.metadata(action: info("incoming_ap_doc"))

    if Config.federating?() do
      Federator.incoming_ap_doc(params)
      |> info("processed")

      Instances.set_reachable(params["actor"])

      json(conn, "ok")
    else
      ret_error(conn, "this instance is not currently federating", 403)
    end
  end

  defp ret_error(conn, error, status \\ 500) do
    conn
    |> put_status(status)
    |> json(%{error: error})
  end

  defp page_number("true"), do: 1
  defp page_number(page) when is_binary(page), do: Integer.parse(page) |> elem(0)
  defp page_number(_), do: 1
end
