defmodule ActivityPub.Federator.Workers.ReceiverWorker do
  use ActivityPub.Federator.Worker, queue: "federator_incoming"
  import Untangle
  # alias ActivityPub.Federator
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Object

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"op" => "incoming_ap_doc" = op, "params" => params, "repo" => repo}
      }) do
    ActivityPub.Utils.set_repo(repo)
    Logger.metadata(action: info(op))

    debug("Handling incoming AP activity")
    ActivityPub.Federator.Transformer.handle_incoming(params)
  end

  def perform(%Oban.Job{
        args: %{
          "op" => "incoming_unverified_ap_doc" = op,
          "params" => params,
          "headers" => headers,
          "repo" => repo
        }
      }) do
    ActivityPub.Utils.set_repo(repo)
    Logger.metadata(action: info(op))

    debug("Handling incoming AP activity with no verified signature")
    maybe_process_unsigned(headers, params)
  end

  defp maybe_process_unsigned(headers, params) do
    actor = Object.actor_from_data(params)
    signed? = is_binary(headers["signature"]) and is_binary(actor)

    fetch_fresh_public_key? =
      if signed? do
        if String.contains?(headers["signature"], actor) do
          error(
            headers,
            "Unknown HTTP signature validation error, will attempt re-fetching public_key and failing that fetch the AP activity from source"
          )

          true
        else
          error(
            headers,
            "No match between actor (#{actor}) and the HTTP signature provided, will attempt re-fetching AP activity from source"
          )

          false
        end
      else
        error(
          params,
          "No HTTP signature provided, will attempt re-fetching AP activity from source (note: if using a reverse proxy make sure you are forwarding the HTTP Host header)"
        )

        false
      end

    if fetch_fresh_public_key? and HTTPSignatures.validate(headers) do
      debug("Found a valid HTTP Signature upon refetch, handle activity now :)")
      ActivityPub.Federator.Transformer.handle_incoming(params)
    else
      if fetch_fresh_public_key? do
        warn("HTTP Signature was invalid even after refetch")
      end

      is_deleted? =
        debug(
          params["type"] in ["Delete", "Tombstone"] or params["object"]["type"] == "Tombstone",
          "is_deleted?"
        )

      with id when is_binary(id) <- params["id"],
           {:ok, object} <- Fetcher.fetch_fresh_object_from_id(id, return_tombstones: is_deleted?) do
        debug(object, "Unsigned activity workaround worked :)")

        {:ok, object}
      else
        e ->
          if System.get_env("ACCEPT_UNSIGNED_ACTIVITIES") == "1" do
            warn(
              e,
              "Unsigned incoming federation: HTTP Signature missing or not from author, AND we couldn't fetch a non-public object without authentication. Accept anyway because ACCEPT_UNSIGNED_ACTIVITIES is set in env."
            )

            ActivityPub.Federator.Transformer.handle_incoming(params)
          else
            error(
              e,
              "Reject incoming federation: HTTP Signature missing or not from author, AND we couldn't fetch a non-public object"
            )

            :ok
          end
      end
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)
end
