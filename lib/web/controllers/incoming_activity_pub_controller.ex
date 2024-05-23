defmodule ActivityPub.Web.IncomingActivityPubController do
  @moduledoc """

  Endpoints for the ActivityPub inbox
  """

  use ActivityPub.Web, :controller

  import Untangle
  use Arrows

  alias ActivityPub.Config
  # alias ActivityPub.Actor
  alias ActivityPub.Federator.Fetcher
  # alias ActivityPub.Object
  alias ActivityPub.Utils
  # alias ActivityPub.Federator.Adapter
  alias ActivityPub.Instances
  # alias ActivityPub.Safety.Containment

  alias ActivityPub.Federator

  @limit_num Application.compile_env(:activity_pub, __MODULE__, 5000)
  @limit_ms Application.compile_env(:activity_pub, __MODULE__, 120_000)

  plug Hammer.Plug,
    rate_limit: {"activity_pub_incoming", @limit_ms, @limit_num},
    by: :ip,
    on_deny: &ActivityPub.Web.rate_limit_reached/2

  def inbox(%{assigns: %{valid_signature: true}} = conn, params) do
    apply_process(conn, params, &process_incoming/3)
  end

  # accept (but re-fetch) unsigned unsigned (or invalidly signed) activities
  def inbox(%{assigns: %{valid_signature: false}} = conn, params) do
    apply_process(conn, params, &maybe_process_unsigned/3)
  end

  # accept (but verify) unsigned Creates only?
  # def inbox(conn, %{"type" => "Create"} = params) do
  #       apply_process(conn, params, &maybe_process_unsigned/3)
  # end
  # def inbox(conn, params) do
  #   Utils.error_json(conn, "please send signed activities - activity was rejected", 401)
  # end

  # accept (but verify) unsigned any activities
  def inbox(conn, params) do
    apply_process(conn, params, &maybe_process_unsigned/3)
  end

  def outbox_info(conn, params) do
    if Config.federating?() do
      "this API path only accepts GET requests"
    else
      "this instance is not currently federating"
    end
    |> debug()
    |> Utils.error_json(conn, ..., 403)
  end

  defp apply_process(conn, %{"type" => "Delete"} = params, fun) do
    # TODO: check if the actor/object being deleted is even known locally before bothering?
    #  workaround in case the remote actor is not yet actually deleted
    fun.(conn, params, schedule_in: {2, :minutes})
  end

  defp apply_process(conn, params, fun) do
    fun.(conn, params, [])
  end

  defp process_incoming(conn, params, worker_args \\ []) do
    if Config.federating?() do
      ActivityPub.Federator.Workers.ReceiverWorker.enqueue(
        "incoming_ap_doc",
        %{
          "params" => params
        },
        worker_args
      )
      |> debug("handling enqueued or processed")

      # TODO: async
      Instances.set_reachable(params["actor"])

      json(conn, "ok")
    else
      Utils.error_json(conn, "this instance is not currently federating", 403)
    end
  end

  defp maybe_process_unsigned(conn, params, worker_args \\ []) do
    if Config.federating?() do
      ActivityPub.Federator.Workers.ReceiverWorker.enqueue(
        "incoming_unverified_ap_doc",
        %{
          "params" => params,
          "headers" => Enum.into(conn.req_headers, %{})
        },
        worker_args
      )
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
