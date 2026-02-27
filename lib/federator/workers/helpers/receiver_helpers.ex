defmodule ActivityPub.Federator.Worker.ReceiverHelpers do
  @moduledoc """
  Shared helpers for all incoming federation receiver workers.

  Provides shared `perform/1` and `maybe_process_unsigned/2` logic for
  handling incoming AP docs, including unsigned and unverified cases.

  ## Verification cascade

  When an activity arrives without a valid HTTP signature, verification
  is attempted in this order:

  1. Re-fetch the actor's public key and re-validate the HTTP signature
  2. Check for a Linked Data Signature (RsaSignature2017) embedded in the body
  3. Re-fetch the activity from its source URI
  4. Accept anyway if `ACCEPT_UNSIGNED_ACTIVITIES=1` is set

  ## Usage

      defmodule ActivityPub.Federator.Workers.ReceiverMentionsWorker do
        use ActivityPub.Federator.Worker, queue: "federator_incoming_mentions"
        @impl Oban.Worker
        def perform(job), do: ActivityPub.Federator.Worker.ReceiverHelpers.perform(job, :mentions)
      end

  """

  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Object
  alias ActivityPub.Safety.LinkedDataSignatures

  import Untangle

  @doc """
  Handles incoming AP doc jobs for all receiver queues.

  The `type` argument is an atom indicating the queue type:
  `:mentions`, `:follows`, `:verified`, `:unverified`, etc.
  """
  def perform(%Oban.Job{args: %{"op" => op, "params" => params, "repo" => repo}} = job, _type)
      when op in ["incoming_ap_doc", "incoming_ap_doc_mentions", "incoming_ap_doc_follows"] do
    ActivityPub.Federator.Adapter.set_multi_tenant_context(repo)
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
    ActivityPub.Federator.Adapter.set_multi_tenant_context(repo)
    Logger.metadata(action: "incoming_unverified_ap_doc")
    Untangle.debug("Handling incoming AP activity with no verified signature")
    maybe_process_unsigned(headers, params)
  end

  @doc """
  Handles unsigned or unverified incoming AP docs.

  Attempts HTTP signature re-validation, then Linked Data Signature
  verification, then falls back to refetching the activity from source.
  """
  def maybe_process_unsigned(headers, params) do
    actor = Object.actor_from_data(params)
    signed? = is_binary(headers["signature"]) and is_binary(actor)

    fetch_fresh_public_key? =
      if signed? do
        if String.contains?(headers["signature"], actor) do
          Untangle.warn(
            "HTTP signature validation failed for #{actor}, will start by re-fetching public key"
          )

          true
        else
          Untangle.warn(
            headers["signature"],
            "HTTP signature actor mismatch (expected it to contain #{actor}), skipping key re-fetch"
          )

          false
        end
      else
        Untangle.warn("No HTTP signature provided, will try LD signature or re-fetch from source")

        false
      end

    if fetch_fresh_public_key? and HTTPSignatures.validate(headers) do
      Untangle.debug("HTTP signature valid after key re-fetch, processing activity")
      ActivityPub.Federator.Transformer.handle_incoming(params)
    else
      if fetch_fresh_public_key? do
        Untangle.warn("HTTP signature still invalid after key re-fetch")
      end

      # Try Linked Data Signature (RsaSignature2017) embedded in the activity body.
      # This covers relay-forwarded activities and activities from shutting-down servers.
      if LinkedDataSignatures.has_verifiable_signature?(params) do
        case LinkedDataSignatures.verify(params) do
          {:ok, creator} ->
            Untangle.info("Valid Linked Data Signature from #{creator}, processing activity")

            ActivityPub.Federator.Transformer.handle_incoming(params)

          {:error, reason} ->
            Untangle.warn(
              reason,
              "Linked Data Signature verification failed, falling back to activity or object refetch"
            )

            maybe_process_unsigned_fallback(params)
        end
      else
        maybe_process_unsigned_fallback(params)
      end
    end
  end

  # Fallback logic for activities without valid HTTP or LD signatures: tries refetching from source, validates follow responses locally, or accepts if ACCEPT_UNSIGNED_ACTIVITIES is set.
  defp maybe_process_unsigned_fallback(params) do
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
        Untangle.debug(object, "Activity verified by re-fetching from source")
        {:ok, object}
      else
        e ->
          if System.get_env("ACCEPT_UNSIGNED_ACTIVITIES") == "1" do
            Untangle.warn(
              e,
              "No valid signature and re-fetch failed, but accepting because ACCEPT_UNSIGNED_ACTIVITIES=1"
            )

            ActivityPub.Federator.Transformer.handle_incoming(params)
          else
            reason =
              "Rejecting activity: no valid HTTP or LD signature, and re-fetch from source failed"

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
