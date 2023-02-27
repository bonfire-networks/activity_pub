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

  # only accept relayed Creates
  def inbox(conn, %{"type" => "Create"} = params) do
    if Config.federating?() do
      warn(
        params,
        "Signature missing or not from author, so fetching object from source"
      )

      with {:error, :needs_login} <-
             Fetcher.fetch_object_from_id(params["object"]["id"] || params["object"]) do
        warn(
          "TEMPORARY WORKAROUND: Signature missing or not from author, but couldn't fetch a non-public object without authentication, so we accept what was received for now"
        )

        process_incoming(conn, params)
      end

      json(conn, "ok")
    else
      json(conn, "This instance is not federating")
    end
  end

  # heck u mastodon
  def inbox(conn, %{"type" => "Delete"}) do
    json(conn, "ok")
  end

  def inbox(conn, params) do
    invalid_signature(conn.req_headers, params)

    error("TODO: should we discard incoming unsigned or invalidly signed activities?")
    process_incoming(conn, params)

    # json(conn, "invalid signature")
  end

  def noop(conn, _params) do
    json(conn, "ok")
  end

  defp process_incoming(conn, params) do
    Logger.metadata(action: info("incoming_ap_doc"))

    if Config.federating?() do
      Federator.incoming_ap_doc(params)
      |> info("processed")

      Instances.set_reachable(params["actor"])

      json(conn, "ok")
    else
      json(conn, "not federating")
    end
  end

  defp invalid_signature(req_headers, params) do
    headers = Enum.into(req_headers, %{})

    if is_binary(headers["signature"]) and String.contains?(headers["signature"], params["actor"]) do
      error(
        params,
        "Signature validation error (make sure you are forwarding the HTTP Host header)"
      )
    else
      error("No signature provided (make sure you are forwarding the HTTP Host header)")
    end

    info(req_headers)
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
