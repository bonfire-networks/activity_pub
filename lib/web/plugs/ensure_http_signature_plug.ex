# Akkoma: Magically expressive social media
# Copyright Â© 2022-2022 Akkoma Authors <https://akkoma.dev/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.EnsureHTTPSignaturePlug do
  @moduledoc """
  Ensures HTTP signature has been validated by previous plugs on ActivityPub requests.
  """
  import Plug.Conn
  import Untangle

  alias ActivityPub.Config

  def init(options) do
    options
  end

  def call(%{assigns: %{current_actor: %{}}} = conn, _opts) do
    # already authorized somehow?
    conn
  end

  def call(%{assigns: %{current_user: %{}}} = conn, _opts) do
    # already authorized somehow?
    conn
  end

  def call(%{assigns: %{valid_signature: true}} = conn, _), do: conn

  # a delivery from a blocked or non-allowlisted server is answered with a quiet 200, so the sender cannot tell it was refused
  def call(%{assigns: %{valid_signature: nil}, method: "POST"} = conn, _) do
    info("Rejecting ActivityPub request from blocked actor/instance")
    debug(conn)
    ignore(conn)
  end

  # a fetch is refused with a real status, so the asker does not take the answer for the object
  def call(%{assigns: %{valid_signature: nil}} = conn, _) do
    info("Refusing ActivityPub fetch from blocked actor/instance")
    debug(conn)
    forbidden(conn)
  end

  def call(conn, _) do
    maybe_reject!(
      conn,
      conn.method != "POST" and Phoenix.Controller.get_format(conn) != "html" and
        signature_required?(conn, Config.signed_fetch_required())
    )
  end

  defp signature_required?(_conn, false), do: false
  defp signature_required?(conn, :all), do: not service_actor_request?(conn)

  defp signature_required?(conn, :except_public_actors),
    do: not service_actor_request?(conn) and not public_actor_request?(conn)

  # An actor's own document stays fetchable without a signature when the adapter would serve that actor to an asker it knows nothing about, which is the check the controller makes before serving it. Servers that don't sign their fetches (eg. Lemmy before 1.0) can then find our public groups and people, and read the keys that verify what we send them. The actor's collections, and every object and activity, still need a signature. Only evaluated for a request that would be refused anyway, since it looks the route and the actor up.
  defp public_actor_request?(%{private: %{phoenix_router: router}} = conn) do
    with %{plug: ActivityPub.Web.ActivityPubController, plug_opts: action, path_params: params}
         when action in [:actor, :actor_by_id] <-
           Phoenix.Router.route_info(router, conn.method, conn.path_info, conn.host),
         {:ok, %ActivityPub.Actor{local: true} = actor} <- requested_actor(action, params) do
      ActivityPub.Federator.Adapter.federate_actor?(nil, :out, actor) != false
    else
      _ -> false
    end
  end

  defp public_actor_request?(_conn), do: false

  defp requested_actor(:actor, %{"username" => username}),
    do: ActivityPub.Actor.get_cached(username: username)

  defp requested_actor(:actor_by_id, %{"id" => id}),
    do: ActivityPub.Actor.get_cached(pointer: id)

  defp requested_actor(_action, _params), do: nil

  # The service actor stays fetchable without a signature. Other servers read its public key to verify the fetches we sign as it, so if it needed a signature, two servers that both require one could never verify each other. Only evaluated for a request that would be refused anyway, since it may look the actor up.
  defp service_actor_request?(%{request_path: path}) do
    case ActivityPub.Utils.service_actor() do
      {:ok, %{ap_id: ap_id} = actor} when is_binary(ap_id) ->
        path in [URI.parse(ap_id).path, service_actor_alias_path(actor)]

      _ ->
        false
    end
  end

  defp service_actor_alias_path(%{username: username}) when is_binary(username),
    do: "#{URI.parse(ActivityPub.Utils.ap_base_url()).path}/actors/#{username}"

  defp service_actor_alias_path(_), do: nil

  def maybe_reject!(conn, false), do: conn
  def maybe_reject!(%{assigns: %{valid_signature: true}} = conn, _true), do: conn

  def maybe_reject!(conn, _true) do
    info("Rejecting ActivityPub request with invalid signature")
    debug(conn)
    unauthorized(conn)
  end

  def unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.text("Please include an HTTP Signature in your requests")
    |> halt()
  end

  def forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.text("Forbidden")
    |> halt()
  end

  def ignore(conn) do
    conn
    |> Phoenix.Controller.text("OK")
    |> halt()
  end
end
