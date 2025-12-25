defmodule ActivityPub.Federator.Worker.ReceiverHelpers do
  @moduledoc """
  Shared helpers for all incoming federation receiver workers.

  Provides shared `perform/1` and `maybe_process_unsigned/2` logic for
  handling incoming AP docs, including unsigned and unverified cases.

  ## Usage

      defmodule ActivityPub.Federator.Workers.ReceiverMentionsWorker do
        use ActivityPub.Federator.Worker, queue: "federator_incoming_mentions"
        @impl Oban.Worker
        def perform(job), do: ActivityPub.Federator.Worker.ReceiverHelpers.perform(job, :mentions)
      end

  """

  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Object

  import Untangle

  @doc """
  Handles incoming AP doc jobs for all receiver queues.

  The `type` argument is an atom indicating the queue type:
  `:mentions`, `:follows`, `:verified`, `:unverified`, etc.
  """
  def perform(%Oban.Job{args: %{"op" => op, "params" => params, "repo" => repo}} = job, _type)
      when op in ["incoming_ap_doc", "incoming_ap_doc_mentions", "incoming_ap_doc_follows"] do
    ActivityPub.Utils.set_repo(repo)
    Logger.metadata(action: op)
    Untangle.debug("Handling incoming AP activity (#{op})")

    ActivityPub.Federator.Transformer.handle_incoming(params)
    |> Untangle.debug("result of handling incoming AP activity")
  end

  def perform(
        %Oban.Job{
          args: %{
            "op" => "incoming_unverified_ap_doc",
            "params" => params,
            "headers" => headers,
            "repo" => repo
          }
        },
        _type
      ) do
    ActivityPub.Utils.set_repo(repo)
    Logger.metadata(action: "incoming_unverified_ap_doc")
    Untangle.debug("Handling incoming AP activity with no verified signature")
    maybe_process_unsigned(headers, params)
  end

  @doc """
  Handles unsigned or unverified incoming AP docs.
  """
  def maybe_process_unsigned(headers, params) do
    actor = Object.actor_from_data(params)
    signed? = is_binary(headers["signature"]) and is_binary(actor)

    fetch_fresh_public_key? =
      if signed? do
        if String.contains?(headers["signature"], actor) do
          Untangle.error(
            headers,
            "Unknown HTTP signature validation error, will attempt re-fetching public_key and failing that fetch the AP activity from source"
          )

          true
        else
          Untangle.error(
            headers,
            "No match between actor (#{actor}) and the HTTP signature provided, will attempt re-fetching AP activity from source"
          )

          false
        end
      else
        Untangle.error(
          params,
          "No HTTP signature provided, will attempt re-fetching AP activity from source (note: if using a reverse proxy make sure you are forwarding the HTTP Host header)"
        )

        false
      end

    if fetch_fresh_public_key? and HTTPSignatures.validate(headers) do
      Untangle.debug("Found a valid HTTP Signature upon refetch, handle activity now :)")
      ActivityPub.Federator.Transformer.handle_incoming(params)
    else
      if fetch_fresh_public_key? do
        Untangle.warn("HTTP Signature was invalid even after refetch")
      end

      # Accept/Reject of Follow activities have unfetchable URLs (fragment identifiers like #accepts/follows/)
      # but can be safely validated against our local Follow activity records.
      # This mirrors how Mastodon handles it: https://github.com/mastodon/mastodon/blob/main/app/lib/activitypub/activity/accept.rb
      is_follow_response? =
        params["type"] in ["Accept", "Reject"] and
          is_map(params["object"]) and params["object"]["type"] == "Follow"

      if is_follow_response? do
        Untangle.debug(
          "Accept/Reject of Follow - validating against local Follow activity (URLs are typically unfetchable)"
        )

        ActivityPub.Federator.Transformer.handle_incoming(params)
      else
        is_deleted? =
          Untangle.debug(
            params["type"] in ["Delete", "Tombstone"] or
              (is_map(params["object"]) and params["object"]["type"] == "Tombstone"),
            "is_deleted?"
          )

        with id when is_binary(id) <- params["id"],
             {:ok, object} <-
               Fetcher.fetch_fresh_object_from_id(id, return_tombstones: is_deleted?) do
          Untangle.debug(object, "Unsigned activity workaround worked :)")
          {:ok, object}
        else
          e ->
            if System.get_env("ACCEPT_UNSIGNED_ACTIVITIES") == "1" do
              Untangle.warn(
                e,
                "Unsigned incoming federation: HTTP Signature missing or not from author, AND we couldn't fetch a non-public object without authentication. Accept anyway because ACCEPT_UNSIGNED_ACTIVITIES is set in env."
              )

              ActivityPub.Federator.Transformer.handle_incoming(params)
            else
              reason =
                "Reject incoming federation: HTTP Signature missing or not from author, AND we couldn't fetch a non-public object"

              Untangle.error(
                e,
                reason
              )

              {:cancel, reason}
            end
        end
      end
    end
  end
end
