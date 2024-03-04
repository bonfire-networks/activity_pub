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

  @limit_num Application.compile_env(:activity_pub, __MODULE__, 3000)
  @limit_ms Application.compile_env(:activity_pub, __MODULE__, 120_000)

  plug Hammer.Plug,
    rate_limit: {"activity_pub_api", @limit_ms, @limit_num},
    by: :ip,
    # when_nil: :raise,
    on_deny: &ActivityPub.Web.rate_limit_reached/2

  # when action == :object

  def ap_route_helper(uuid) do
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    "#{ActivityPub.Web.base_url()}#{ap_base_path}/objects/#{uuid}"
  end

  def object(conn, %{"uuid" => uuid}) do
    cond do
      get_format(conn) == "html" ->
        redirect_to_url(conn, uuid)

      Config.federating?() != false ->
        json_object_with_cache(conn, uuid)

      true ->
        # redirect_to_url(conn, uuid)
        Utils.error_json(conn, "this instance is not currently federating", 403)
    end
  end

  defp redirect_to_url(conn, username_or_id) do
    case Adapter.get_redirect_url(username_or_id) do
      "http" <> _ = url -> redirect(conn, external: url)
      url when is_binary(url) -> redirect(conn, to: url)
      _ -> nil
    end
  end

  def json_object_with_cache(conn \\ nil, id, opts \\ [])

  def json_object_with_cache(conn_or_nil, id, opts) do
    Utils.json_with_cache(
      conn_or_nil,
      &object_json/1,
      :ap_object_cache,
      id,
      &maybe_return_json/4,
      opts
    )
    |> debug()
  end

  defp maybe_return_json(conn, meta, json, opts) do
    debug(json)

    if opts[:exporting] == true or federate_actor?(Map.get(json, "actor"), conn) do
      Utils.return_json(conn, meta, json)
    else
      Utils.error_json(conn, "this actor is not currently federating", 403)
    end
  end

  defp object_json(json: id) do
    if Utils.is_ulid?(id) do
      # querying by pointer - handle local objects
      #  true <- object.id != id, # huh?
      #  current_user <- Map.get(conn.assigns, :current_user, nil) |> debug("current_user"), # TODO: should/how users make authenticated requested?
      # || Containment.visible_for_user?(object, current_user)) |> debug("public or visible for current_user?") 
      maybe_object_json(Object.get_cached!(pointer: id) || Adapter.maybe_publish_object(id, true))
    else
      # query by UUID

      maybe_object_json(Object.get_cached!(ap_id: ap_route_helper(id)))
    end
  end

  defp maybe_object_json(%{public: true} = object) do
    # debug(object)
    {:ok,
     %{
       json: ObjectView.render("object.json", %{object: object}),
       meta: %{updated_at: object.updated_at}
     }}
  end

  defp maybe_object_json(%{data: %{"type" => type}} = object)
       when type in ["Accept", "Undo", "Delete", "Tombstone"] do
    debug(
      "workaround for being able to delete, and accept follow and unfollow without HTTP Signatures"
    )

    {:ok,
     %{
       json: ObjectView.render("object.json", %{object: object}),
       meta: %{updated_at: object.updated_at}
     }}
  end

  defp maybe_object_json({:ok, object}) do
    maybe_object_json(object)
  end

  defp maybe_object_json(%Object{}) do
    warn(
      "someone attempted to fetch a non-public object, we acknowledge its existence but do not return it"
    )

    {:error, 401, "authentication required"}
  end

  defp maybe_object_json(other) do
    debug(other, "Pointable not found")
    {:error, 404, "not found"}
  end

  def actor(conn, %{"username" => username}) do
    cond do
      get_format(conn) == "html" ->
        redirect_to_url(conn, username)

      federate_actor?(username, conn) ->
        actor_with_cache(conn, username)

      true ->
        # redirect_to_url(conn, username)
        Utils.error_json(conn, "this instance is not currently federating", 403)
    end
  end

  defp actor_with_cache(conn, username) do
    Utils.json_with_cache(conn, &actor_json/1, :ap_actor_cache, username)
  end

  defp actor_json(json: username) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      {:ok,
       %{
         json: ActorView.render("actor.json", %{actor: actor}),
         meta: %{updated_at: actor.updated_at}
       }}
    else
      _ ->
        with {:ok, actor} <- Object.get_cached(username: username) do
          # for Tombstone
          {:ok,
           %{
             json: ActorView.render("actor.json", %{actor: actor}),
             meta: %{updated_at: actor.updated_at}
           }}
        else
          _ ->
            {:error, 404, "not found"}
        end
    end
  end

  def following(conn, %{"username" => username} = params) do
    with true <- federate_actor?(username, conn),
         {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("following.json", %{actor: actor, page: page_number(params["page"])})
    end
  end

  def followers(conn, %{"username" => username} = params) do
    with true <- federate_actor?(username, conn),
         {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("followers.json", %{actor: actor, page: page_number(params["page"])})
    end
  end

  def outbox(conn, %{"username" => username} = params) do
    with true <- federate_actor?(username, conn),
         {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ObjectView)
      |> render("outbox.json", %{actor: actor, page: page_number(params["page"])})
    else
      e ->
        Utils.error_json(conn, "Invalid actor", 500)
    end
  end

  def outbox(conn, params) do
    if Config.env() != :prod and Config.federating?() do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ObjectView)
      |> render("outbox.json", %{outbox: :shared_outbox, page: page_number(params["page"])})
    else
      Utils.error_json(conn, "Not allowed", 400)
    end
  end

  def maybe_inbox(conn, %{"username" => username} = params) do
    # if Config.env() != :prod and federate_actor?(username, conn) do
    #  # TODO?
    # else
    Utils.error_json(conn, "this API path only accepts POST requests", 403)
    # end
  end

  def maybe_inbox(conn, params) do
    if Config.env() != :prod and Config.federating?() do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ObjectView)
      |> render("inbox.json", %{inbox: :shared_inbox, page: page_number(params["page"])})
    else
      Utils.error_json(conn, "this API path only accepts POST requests", 403)
    end
  end

  defp federate_actor?(username, conn) do
    Adapter.federate_actor?(username, :out, Map.get(conn.assigns, :current_actor)) != false
  end

  defp page_number("true"), do: 1
  defp page_number(page) when is_binary(page), do: Integer.parse(page) |> elem(0)
  defp page_number(_), do: 1
end
