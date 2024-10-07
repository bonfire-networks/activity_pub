defmodule ActivityPub.Web.RedirectController do
  use ActivityPub.Web, :controller
  import Untangle
  alias ActivityPub.Federator.Adapter
  # alias ActivityPub.Federator.WebFinger

  @limit_num Application.compile_env(:activity_pub, __MODULE__, 200)
  @limit_ms Application.compile_env(:activity_pub, __MODULE__, 60_000)

  plug Hammer.Plug,
    rate_limit: {"activity_pub_api", @limit_ms, @limit_num},
    by: :ip,
    # when_nil: :raise,
    on_deny: &ActivityPub.Web.rate_limit_reached/2

  # when action == :object

  def object(conn, %{"uuid" => uuid}) do
    object =
      ActivityPub.Object.get_cached!(id: uuid) ||
        ActivityPub.Object.get_cached!(pointer: uuid)
        |> debug()

    case Adapter.get_redirect_url(object || uuid) do
      nil ->
        conn
        |> send_resp(404, "Object not found or not permitted")
        |> halt

      "http" <> _ = url ->
        conn
        |> redirect(external: url)

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

      "http" <> _ = url ->
        conn
        |> redirect(external: url)

      url ->
        conn
        |> redirect(to: url)
    end
  end

  # incoming remote interaction
  def remote_interaction(conn, %{"acct" => username_or_uri}) do
    with {:ok, actor_or_object} <-
           ActivityPub.Actor.get_cached_or_fetch(username_or_uri),
         url when is_binary(url) <- Adapter.get_redirect_url(actor_or_object) do
      case url <> "?remote_interaction=follow" do
        "http" <> _ = url ->
          conn
          |> put_flash(
            :info,
            "Press the button again to confirm your action on this remote user or object."
          )
          |> redirect(external: url)

        url ->
          conn
          |> put_flash(
            :info,
            "Press the button again to confirm your action on this remote user or object."
          )
          |> redirect(to: url)
      end
    else
      _ ->
        conn
        |> send_resp(404, "Remote actor or object not found")
        |> halt
    end
  end

  # outgoing remote interaction
  def remote_interaction(conn, %{"outgoing" => outgoing} = params) do
    me = Map.get(params, "me") || Map.get(outgoing, "me")

    object =
      Map.get(params, "object") || Map.get(outgoing, "object") ||
        Map.get(outgoing, "follow")

    with {:ok, fingered} <-
           ActivityPub.Federator.WebFinger.finger(me) |> debug("fingered"),
         %{"subscribe_address" => subscribe_address}
         when is_binary(subscribe_address) <- fingered,
         true <- String.contains?(subscribe_address, "{uri}"),
         url <- String.replace(subscribe_address, "{uri}", object) do
      case url do
        "http" <> _ = url ->
          conn
          |> redirect(external: url)

        url ->
          conn
          |> redirect(to: url)
      end
    else
      %{"id" => url} ->
        error(
          url,
          "Remote didn't provide a `subscribe_address` in WebFinger, redirecting to profile instead"
        )

        conn
        |> redirect(external: url)

      other ->
        error(other)

        conn
        |> send_resp(
          404,
          "Sorry, your actor or remote interaction URL was not found"
        )
        |> halt
    end
  end

  def remote_interaction(conn, params) do
    error(params, "unrecognised params")

    conn
    |> send_resp(
      404,
      "Sorry, your actor or remote interaction URL was not found"
    )
    |> halt
  end
end
