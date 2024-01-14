defmodule ActivityPub.Web.IncomingActivityPubController do
  @moduledoc """

  Endpoints for the ActivityPub inbox
  """

  use ActivityPub.Web, :controller

  import Untangle

  alias ActivityPub.Config
  # alias ActivityPub.Actor
  alias ActivityPub.Federator.Fetcher
  # alias ActivityPub.Object
  alias ActivityPub.Utils
  # alias ActivityPub.Federator.Adapter
  alias ActivityPub.Instances
  # alias ActivityPub.Safety.Containment

  alias ActivityPub.Federator

  @limit_num Application.compile_env(:activity_pub, __MODULE__, 1200)
  @limit_ms Application.compile_env(:activity_pub, __MODULE__, 60_000)

  plug Hammer.Plug,
    rate_limit: {"activity_pub_incoming", @limit_ms, @limit_num},
    by: :ip,
    # when_nil: :raise,
    on_deny: &ActivityPub.Web.rate_limit_reached/2

  # when action == :object

  def inbox(%{assigns: %{valid_signature: true}} = conn, params) do
    process_incoming(conn, params)
  end

  # accept (but re-fetch) unsigned unsigned (or invalidly signed) activities
  def inbox(%{assigns: %{valid_signature: false}} = conn, params) do
    maybe_process_unsigned(conn, params, true)
  end

  # accept (but verify) unsigned Creates only?
  # def inbox(conn, %{"type" => "Create"} = params) do
  #   maybe_process_unsigned(conn, params, nil)
  # end
  # def inbox(conn, params) do
  #   Utils.error_json(conn, "please send signed activities - activity was rejected", 401)
  # end

  # accept (but verify) unsigned any activities
  def inbox(conn, params) do
    maybe_process_unsigned(conn, params, false)
  end

  def inbox_info(conn, params) do
    if Config.federating?() do
      Utils.error_json(conn, "this API path only accepts POST requests", 403)
    else
      Utils.error_json(conn, "this instance is not currently federating", 403)
    end
  end

  defp process_incoming(conn, params) do
    if Config.federating?() do
      ActivityPub.Federator.Workers.ReceiverWorker.enqueue("incoming_ap_doc", %{
        "params" => params
      })
      |> debug("handling enqueued or processed")

      # TODO: async
      Instances.set_reachable(params["actor"])

      json(conn, "ok")
    else
      Utils.error_json(conn, "this instance is not currently federating", 403)
    end
  end

  defp maybe_process_unsigned(conn, params, _signed?) do
    if Config.federating?() do
      ActivityPub.Federator.Workers.ReceiverWorker.enqueue("incoming_unverified_ap_doc", %{
        "params" => params,
        "headers" => Enum.into(conn.req_headers, %{})
      })
      |> debug("verification enqueued or processed")

      # TODO: async
      Instances.set_reachable(params["actor"])

      json(conn, "tbd")
    else
      Utils.error_json(conn, "this instance is not currently federating", 403)
    end
  end

  # defp maybe_process_unsigned(conn, params, signed?) do
  #   if Config.federating?() do
  #     headers = Enum.into(conn.req_headers, %{})

  #     if signed? and is_binary(headers["signature"]) do
  #       if String.contains?(headers["signature"], params["actor"]) do
  #         error(
  #           headers,
  #           "Unknown HTTP signature validation error, will attempt re-fetching AP activity from source"
  #         )
  #       else
  #         error(
  #           headers,
  #           "No match between actor (#{params["actor"]}) and the HTTP signature provided, will attempt re-fetching AP activity from source"
  #         )
  #       end
  #     else
  #       error(
  #         params,
  #         "No HTTP signature provided, will attempt re-fetching AP activity from source (note: if using a reverse proxy make sure you are forwarding the HTTP Host header)"
  #       )
  #     end

  #     with id when is_binary(id) <-   params["id"],
  #          {:ok, object} <-  Fetcher.enqueue_fetch(id) do
  #       if signed? == true do
  #         debug(params, "HTTP Signature was invalid - unsigned activity workaround enqueued")

  #         Utils.error_json(
  #           conn,
  #           "HTTP Signature was invalid - object was not accepted as-in and will instead be re-fetched from origin",
  #           401
  #         )
  #       else
  #         debug(params, "No HTTP Signature provided - unsigned activity workaround enqueued")

  #         Utils.error_json(
  #           conn,
  #           "Please send activities with HTTP Signature - object was not accepted as-in and we'll instead attempt to re-fetch it from origin",
  #           401
  #         )
  #       end
  #     else
  #       e ->
  #         if System.get_env("ACCEPT_UNSIGNED_ACTIVITIES") == "1" do
  #           warn(
  #             e,
  #             "Unsigned incoming federation: HTTP Signature missing or not from author, AND we couldn't fetch a non-public object without authentication. Accept anyway because ACCEPT_UNSIGNED_ACTIVITIES is set in env."
  #           )

  #           process_incoming(conn, params)
  #         else
  #           error(
  #             e,
  #             "Reject incoming federation: HTTP Signature missing or not from author, AND we couldn't fetch a non-public object"
  #           )

  #           Utils.error_json(conn, "please send signed activities - activity was rejected", 401)
  #         end
  #     end
  #   else
  #     Utils.error_json(conn, "This instance is not currently federating", 403)
  #   end
  # end
end