defmodule ActivityPub.Web.ActivityPubController do
  @moduledoc """

  Endpoints for serving objects and collections, so the ActivityPub API can be used to read information from the server.

  Even though we store the data in AS format, some changes need to be applied to the entity before serving it in the AP REST response. This is done in `ActivityPub.Web.ActivityPubView`.
  """

  use ActivityPub.Web, :controller

  import Untangle
  import ActivityPub.Config

  alias ActivityPub.Config
  alias ActivityPub.Actor
  # alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Object
  alias ActivityPub.Utils
  alias ActivityPub.Federator.Adapter
  # alias ActivityPub.Instances
  # alias ActivityPub.Safety.Containment

  alias ActivityPub.Web.ActorView
  # alias ActivityPub.Federator
  alias ActivityPub.Web.ObjectView

  plug :rate_limit,
    key_prefix: :api,
    scale_ms: 120_000,
    limit: 3000

  # when action == :object

  def ap_route_helper(uuid) do
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    "#{ActivityPub.Web.base_url()}#{ap_base_path}/objects/#{uuid}"
  end

  def object(conn, %{"uuid" => uuid}) do
    cond do
      get_format(conn) == "html" ->
        ActivityPub.Web.RedirectController.object(conn, %{"uuid" => uuid})

      Config.federating?() != false ->
        json_object_with_cache(conn, uuid)

      true ->
        Utils.error_json(conn, "this instance is not currently federating", 403)
    end
  end

  def json_object_with_cache(conn \\ nil, id, opts \\ [])

  def json_object_with_cache(conn_or_nil, id, opts) do
    Utils.json_with_cache(
      conn_or_nil,
      &object_json/2,
      :ap_object_cache,
      id,
      &maybe_return_json/4,
      opts
    )
  end

  defp maybe_return_json(conn, meta, json, opts) do
    # debug(json)

    is_deletion? = is_in(json["type"], ["Delete", "Tombstone"])

    if is_deletion? || opts[:exporting] == true ||
         may_serve_actor?(Map.get(json, "actor"), conn) do
      # If published date is in the future, do not return the object
      published_in_future? =
        case is_deletion? || json["published"] do
          true ->
            false

          nil ->
            false

          date when is_binary(date) ->
            case DateTime.from_iso8601(date) do
              {:ok, dt, _} -> DateTime.compare(dt, DateTime.utc_now()) == :gt
              _ -> false
            end

          _ ->
            false
        end

      if published_in_future? do
        Utils.error_json(conn, "not found", 404)
      else
        Utils.return_json(conn, meta, json)
      end
    else
      Utils.error_json(conn, "this actor is not currently federating", 403)
    end
  end

  defp object_json([json: id], opts) when is_binary(id) do
    #  TODO: support prefixed UUIDs?
    if Utils.is_ulid?(id) do
      debug(id, "querying by pointer - handle local objects")

      #  true <- object.id != id, # huh?
      #  current_user <- Map.get(conn.assigns, :current_user, nil) |> debug("current_user"), # TODO: should/how users make authenticated requested?
      # || Containment.visible_for_user?(object, current_user)) |> debug("public or visible for current_user?") 
      maybe_object_json(
        Object.get_cached!(pointer: id) ||
          Object.get_cached!(ap_id: ap_route_helper(id)) ||
          Adapter.maybe_publish_object(id, opts |> Keyword.put(:manually_fetching?, true)),
        opts
      )
    else
      debug(id, "query by ap_id based on UUID")

      ap_id =
        ap_route_helper(id)
        |> debug("resolved AP id")

      maybe_object_json(Object.get_cached!(ap_id: ap_id) |> debug("object from cache"), opts)
    end
    |> debug("generated json for cache")
  end

  defp object_json([json: %ActivityPub.Object{} = object], opts) do
    maybe_object_json(
      object,
      opts
    )
  end

  defp maybe_object_json(%{public: true} = object, opts) do
    # debug(object)
    {:ok,
     %{
       json: ObjectView.render("object.json", %{object: object, opts: opts}),
       meta: %{updated_at: object.updated_at}
     }}
  end

  defp maybe_object_json(%{data: %{"type" => type}} = object, opts)
       when is_in(type, ["Accept", "Undo", "Delete", "Tombstone"]) do
    debug(
      "workaround for being able to delete, and accept follow and unfollow without HTTP Signatures"
    )

    {:ok,
     %{
       json: ObjectView.render("object.json", %{object: object, opts: opts}),
       meta: %{updated_at: object.updated_at}
     }}
  end

  defp maybe_object_json({:ok, object}, opts) do
    maybe_object_json(object, opts)
  end

  defp maybe_object_json(%Object{}, _opts) do
    # TODO: support authenticated fetching for non-public objects (especially needed for C2S)
    warn(
      "someone attempted to fetch a non-public object, we acknowledge its existence but do not return it"
    )

    {:error, 401, "authentication required"}
  end

  defp maybe_object_json(other, _opts) do
    debug(other, "Pointable not found")
    {:error, 404, "not found"}
  end

  def actor(conn, %{"username" => username}) do
    cond do
      get_format(conn) == "html" ->
        ActivityPub.Web.RedirectController.actor(conn, %{"username" => username})

      may_serve_actor?(username, conn) ->
        actor_with_cache(conn, username)

      true ->
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
        with {:ok, actor} <- Object.get_cached(username: username, local: true) do
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
    with true <- may_serve_actor?(username, conn),
         {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("following.json", %{actor: actor, page: page_number(params["page"])})
    end
  end

  def followers(conn, %{"username" => username} = params) do
    with true <- may_serve_actor?(username, conn),
         {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ActorView)
      |> render("followers.json", %{actor: actor, page: page_number(params["page"])})
    end
  end

  def outbox(conn, %{"username" => username} = params) do
    with true <- may_serve_actor?(username, conn),
         {:ok, actor} <- Actor.get_cached(username: username) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ObjectView)
      |> render("outbox.json", %{actor: actor, page: page_number(params["page"])})
    else
      e ->
        error(e, "Invalid actor")
        Utils.error_json(conn, "Invalid actor", 500)
    end
  end

  def collection(conn, %{"type" => type, "uuid" => uuid} = params) do
    with {:ok, collection} <- get_servable_collection(type, uuid, conn) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ObjectView)
      |> render("collection.json", %{
        collection: collection,
        page: page_number(params["page"]),
        embed: params["embed"] == "true"
      })
    else
      e ->
        error(e, "Invalid collection")
        Utils.error_json(conn, "Not found", 404)
    end
  end

  # Serve an already-persisted collection by id, or build one for a servable singleton-per-actor
  # collection of a local actor. Store-vs-adapter ownership is inferred cheaply (no member queries).
  defp get_servable_collection(type, uuid, conn) do
    id = ActivityPub.Utils.collection_ap_id(type, uuid)

    case Object.get_cached(ap_id: id) do
      {:ok, %Object{} = collection} ->
        {:ok, collection}

      _ ->
        case build_servable_collection(type, uuid, conn) do
          %Object{} = collection -> {:ok, collection}
          _ -> {:error, :not_found}
        end
    end
  end

  defp build_servable_collection(type, uuid, conn) do
    # only singleton-per-actor collections (uuid = owner actor id) are served here; non-singleton
    # types fall through to 404
    with true <- Config.type_in?(type, :singleton_collection_types),
         {:ok, %{local: true} = actor} <- Actor.get_cached(pointer: uuid),
         true <- may_serve_actor?(actor.username, conn) do
      if ActivityPub.Federator.Adapter.adapter_handles?({:collection, type}) do
        # adapter/extension-owned (e.g. Pins/featured): synthesise an envelope; membership comes
        # from the adapter (no persisted store object needed)
        coll_type =
          if Config.type_in?(type, :ordered_collection_types),
            do: "OrderedCollection",
            else: "Collection"

        %Object{
          data: %{
            "id" => ActivityPub.Utils.collection_ap_id(type, uuid),
            "type" => coll_type,
            "attributedTo" => actor.ap_id
          }
        }
      else
        # store-backed (e.g. keyPackages): persist a metadata object (anchors membership FK)
        case ActivityPub.GenericCollectionStore.get_or_create_collection(type, uuid, actor.ap_id) do
          {:ok, collection} -> collection
          _ -> nil
        end
      end
    else
      _ -> nil
    end
  end

  def shared_outbox(conn, params) do
    if Config.env() != :prod and Config.federating?() do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ObjectView)
      |> render("outbox.json", %{outbox: :shared_outbox, page: page_number(params["page"])})
    else
      Utils.error_json(conn, "Not allowed", 400)
    end
  end

  def maybe_inbox(conn, %{"username" => request_username} = params) do
    # Check if this is a C2S request with Bearer token

    with %{username: current_username} = current_actor <- conn.assigns[:current_actor],
         true <- current_username == request_username do
      # {:ok, actor} <- Actor.get_cached(username: username),
      # ["Bearer " <> _token] <-  get_req_header(conn, "authorization") do

      # For C2S requests with Bearer token, render the shared inbox for now
      # TODO: This is a minimal implementation - should check token validity and show user-specific inbox
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ObjectView)
      |> render("inbox.json", %{actor: current_actor, page: page_number(params["page"])})
    else
      false ->
        warn(
          conn.assigns[:current_actor],
          "Requested user `#{request_username}` does not match current_actor username"
        )

        Utils.error_json(
          conn,
          "this API endpoint only accepts POST requests, or authenticated GET requests",
          403
        )

      e ->
        warn(e, "Not a C2S request with Bearer token")
        # This is a federation request - return error for GET
        Utils.error_json(
          conn,
          "this API endpoint only accepts POST requests, or authenticated GET requests",
          403
        )
    end
  end

  # MLS-over-ActivityPub `mls:messages`: the actor's received MLS activities, so an E2EE client can skip
  # scanning the inbox. Owner-only (like the inbox), since the envelope metadata is private even though
  # payloads are encrypted.
  def mls_messages(conn, %{"username" => request_username} = params) do
    with %{username: current_username} = current_actor <- conn.assigns[:current_actor],
         true <- current_username == request_username do
      conn
      |> put_resp_content_type("application/activity+json")
      |> put_view(ObjectView)
      |> render("mls_messages.json", %{
        actor: current_actor,
        page: page_number(params["page"]),
        paged: Map.has_key?(params, "page")
      })
    else
      _ ->
        Utils.error_json(
          conn,
          "this endpoint only accepts authenticated GET requests by the owner",
          403
        )
    end
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

  defp may_serve_actor?(local_actor, conn) do
    # the local actor whose data is being served is the LOCAL party (`by_actor`); the requesting
    # actor (from the HTTP signature, may be nil) is the `subject` checked against. This honors the
    # served actor's own per-user federation setting (e.g. `user_federating: false`) and "does this
    # actor allow the requester", matching the by_actor=local / subject=remote convention elsewhere.
    Adapter.federate_actor?(
      Map.get(conn.assigns, :current_user) || Map.get(conn.assigns, :current_actor),
      :out,
      local_actor
    ) != false
  end

  defp page_number("true"), do: 1
  defp page_number(page) when is_binary(page), do: Integer.parse(page) |> elem(0)
  defp page_number(_), do: nil
end
