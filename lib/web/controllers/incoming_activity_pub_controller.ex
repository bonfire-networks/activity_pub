defmodule ActivityPub.Web.IncomingActivityPubController do
  @moduledoc """

  Endpoints for the ActivityPub inbox
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

  @limit_num Application.compile_env(:activity_pub, __MODULE__, 5000)
  @limit_ms Application.compile_env(:activity_pub, __MODULE__, 120_000)

  plug Hammer.Plug,
    rate_limit: {"activity_pub_incoming", @limit_ms, @limit_num},
    by: :ip,
    on_deny: &ActivityPub.Web.rate_limit_reached/2

  def shared_inbox(conn, params) do
    inbox(conn, params)
  end

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

  def outbox_info(conn, _params) do
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
          "params" => params,
          "username" => params["username"]
        },
        worker_args
      )
      |> debug("handling enqueued or processed")

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
          "params" => debug(params, "incoming_unverified_ap_doc params"),
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
end
