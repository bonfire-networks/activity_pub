defmodule ActivityPub.Web.IncomingActivityPubController do
  @moduledoc """
  Endpoints for the ActivityPub inbox.

  Incoming activities are routed based on HTTP signature validity:
  - Valid HTTP signature: processed immediately
  - Missing or invalid HTTP signature: queued for verification cascade
    (key re-fetch, LD signature check, source re-fetch — see `ReceiverHelpers`)
  """

  use ActivityPub.Web, :controller

  import Untangle
  use Arrows

  alias ActivityPub.Config
  # alias ActivityPub.Actor
  # alias ActivityPub.Federator.Fetcher
  # alias ActivityPub.Object
  alias ActivityPub.Utils
  # alias ActivityPub.Federator.Adapter
  alias ActivityPub.Instances
  # alias ActivityPub.Safety.Containment
  # alias ActivityPub.Federator
  alias ActivityPub.Federator.Worker.ReceiverRouter

  plug :rate_limit,
    key_prefix: :incoming,
    scale_ms: 120_000,
    limit: 5000

  def shared_inbox(conn, params) do
    inbox(conn, params)
  end

  def inbox(%{assigns: %{valid_signature: true}} = conn, params) do
    apply_process(conn, params, &process_incoming/3)
  end

  # HTTP signature missing or invalid — queue for the full verification cascade
  # (key re-fetch, LD signature check, source re-fetch) in ReceiverHelpers.
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

  def only_get_error!(conn, _params) do
    if Config.federating?() do
      "this API path only accepts GET requests"
    else
      "this instance is not currently federating"
    end
    |> debug()
    |> Utils.error_json(conn, ..., 403)
  end

  defp apply_process(conn, %{"type" => "Delete"} = params, fun) do
    # # Check if we know the object locally before enqueueing -> NOTE: can't do here as it may have been pruned from AP db but exists in adapter
    # object_id = ActivityPub.Object.get_ap_id(params["object"])

    # case ActivityPub.Object.get_cached(ap_id: object_id) do
    #   {:ok, _object} ->

    # process the deletion with a delay (in the remote is still in the process of deleting it)
    fun.(conn, params, schedule_in: {2, :minutes})

    #   {:error, :not_found} ->
    #     # Object not cached locally, discard without enqueueing
    #     debug(object_id, "Discarding Delete for unknown object")
    #     json(conn, "nok")
    # end
  end

  defp apply_process(conn, params, fun) do
    fun.(conn, params, [])
  end

  defp process_incoming(conn, params, worker_args \\ []) do
    if Config.federating?() do
      ReceiverRouter.route_worker(params, true).enqueue(
        "incoming_ap_doc",
        %{
          "params" => params,
          "username" => params["username"]
        },
        worker_args
      )
      |> debug("handling enqueued or processed")

      Instances.handle_successful_contact(params["actor"])

      conn
      |> Plug.Conn.put_resp_header("accept-signature", "sig1=()")
      |> json("ok")
    else
      Utils.error_json(conn, "this instance is not currently federating", 403)
    end
  end

  defp maybe_process_unsigned(conn, params, worker_args \\ []) do
    if Config.federating?() do
      ReceiverRouter.route_worker(params, false).enqueue(
        "incoming_unverified_ap_doc",
        %{
          "params" => debug(params, "incoming_unverified_ap_doc params"),
          "headers" => Enum.into(conn.req_headers, %{})
        },
        worker_args
      )
      |> debug("verification enqueued or processed")

      Instances.handle_successful_contact(params["actor"])

      conn
      |> Plug.Conn.put_resp_header("accept-signature", "sig1=()")
      |> json("tbd")
    else
      Utils.error_json(conn, "this instance is not currently federating", 403)
    end
  end
end
