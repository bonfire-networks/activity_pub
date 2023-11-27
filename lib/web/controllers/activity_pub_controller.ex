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

    if opts[:exporting] == true or Adapter.actor_federating?(json |> Map.get("actor")) != false do
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

      Adapter.actor_federating?(username) != false ->
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
        Utils.error_json(conn, "Invalid actor", 500)
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
  # def inbox(conn, %{"type" => "Create"} = params) do
  #   maybe_process_unsigned(conn, params, nil)
  # end

  def inbox(%{assigns: %{valid_signature: false}} = conn, params) do
    maybe_process_unsigned(conn, params, true)
  end

  def inbox(conn, params) do
    maybe_process_unsigned(conn, params, false)
  end

  def inbox_info(conn, params) do
    if Config.federating?() do
      Utils.error_json(conn, "this endpoint only accepts POST requests", 403)
    else
      Utils.error_json(conn, "this instance is not currently federating", 403)
    end
  end

  def noop(conn, _params) do
    json(conn, "ok")
  end

  defp maybe_process_unsigned(conn, params, signed?) do
    if Config.federating?() do
      headers = Enum.into(conn.req_headers, %{})

      if signed? and is_binary(headers["signature"]) do
        if String.contains?(headers["signature"], params["actor"]) do
          error(
            headers,
            "Unknown HTTP signature validation error, will attempt re-fetching AP activity from source"
          )
        else
          error(
            headers,
            "No match between actor (#{params["actor"]}) and the HTTP signature provided, will attempt re-fetching AP activity from source"
          )
        end
      else
        error(
          params,
          "No HTTP signature provided, will attempt re-fetching AP activity from source (note: if using a reverse proxy make sure you are forwarding the HTTP Host header)"
        )
      end

      with id when is_binary(id) <-
             params["id"],
           {:ok, object} <-
             Fetcher.enqueue_fetch(id) do
        if signed? == true do
          debug(params, "HTTP Signature was invalid - unsigned activity workaround enqueued")

          Utils.error_json(
            conn,
            "HTTP Signature was invalid - object was not accepted as-in and will instead be re-fetched from origin",
            401
          )
        else
          debug(params, "No HTTP Signature provided - unsigned activity workaround enqueued")

          Utils.error_json(
            conn,
            "Please send activities with HTTP Signature - object was not accepted as-in and will instead be re-fetched from origin",
            401
          )
        end
      else
        e ->
          if System.get_env("ACCEPT_UNSIGNED_ACTIVITIES") == "1" do
            warn(
              e,
              "Unsigned incoming federation: HTTP Signature missing or not from author, AND we couldn't fetch a non-public object without authentication. Accept anyway because ACCEPT_UNSIGNED_ACTIVITIES is set in env."
            )

            process_incoming(conn, params)
          else
            error(
              e,
              "Reject incoming federation: HTTP Signature missing or not from author, AND we couldn't fetch a non-public object"
            )

            Utils.error_json(conn, "please send signed activities - activity was rejected", 401)
          end
      end
    else
      Utils.error_json(conn, "This instance is not currently federating", 403)
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
      Utils.error_json(conn, "this instance is not currently federating", 403)
    end
  end

  defp page_number("true"), do: 1
  defp page_number(page) when is_binary(page), do: Integer.parse(page) |> elem(0)
  defp page_number(_), do: 1
end
