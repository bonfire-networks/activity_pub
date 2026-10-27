defmodule ActivityPub.Federator.Worker.ReceiverHelpers do
  @moduledoc """
  Shared helpers for all incoming federation receiver workers.

  Provides shared `perform/1` and `maybe_process_unsigned/2` logic for
  handling incoming AP docs, including unsigned and unverified cases.

  ## Verification cascade

  When an activity arrives without a valid HTTP signature, verification
  is attempted in this order:

  1. Check for an object integrity proof (FEP-8b32) in the body. It goes first because
     the FEP gives it precedence over an HTTP signature, and because it needs nothing
     fetched but a key we usually hold
  2. Re-fetch the actor's public key and re-validate the HTTP signature
  3. Check for a Linked Data Signature (RsaSignature2017) embedded in the body
  4. Re-fetch the activity from its source URI
  5. Accept anyway, as `config :activity_pub, :incoming_signatures` says: `unsigned:`
     when nothing signed it (`ActivityPub.Safety.accept_unsigned?/0`), `invalid:` when
     a signature did not hold (`ActivityPub.Safety.accept_invalid?/0`). Both refuse by
     default

  A proof or LD signature that does not verify goes on to the rest. One we cannot
  check counts as none.

  ## Over an HTTP signature

  A proof or LD signature in the body is checked too (FEP-8b32: "Recipients of an
  object SHOULD perform proof verification if it contains integrity proofs"), so what
  is stored says it vouched for the document (`authenticated:`), and whoever passes it
  on need not check it again. One that does not hold makes the delivery partly
  invalid, handled as `ActivityPub.Safety.partly_invalid/0` says: accepted on the
  HTTP signature by default, refetched from its origin, or refused.

  ## Usage

      defmodule ActivityPub.Federator.Workers.ReceiverMentionsWorker do
        use ActivityPub.Federator.Worker, queue: "federator_incoming_mentions"
        @impl Oban.Worker
        def perform(job), do: ActivityPub.Federator.Worker.ReceiverHelpers.perform(job, :mentions)
      end

  """

  import ActivityPub.Config
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.Forwarder
  alias ActivityPub.Object
  alias ActivityPub.Safety.IntegrityProofs
  alias ActivityPub.Safety.LinkedDataSignatures

  import Untangle

  @doc """
  Handles incoming AP doc jobs for all receiver queues.

  The `type` argument is an atom indicating the queue type:
  `:mentions`, `:follows`, `:verified`, `:unverified`, etc.
  """
  def perform(
        %Oban.Job{args: %{"op" => op, "params" => params, "repo" => repo} = args} = job,
        _type
      )
      when op in ["incoming_ap_doc", "incoming_ap_doc_mentions", "incoming_ap_doc_follows"] do
    ActivityPub.Federator.Adapter.set_multi_tenant_context(repo)
    # ap_type is the boost-storm fingerprint ("Announce" vs "Create" vs "Like") — StormRecorder
    Logger.metadata(action: op, ap_type: params["type"])
    Untangle.debug("Handling incoming AP activity (#{op})")

    # carry the identity the signature plugs verified for this delivery: it is the only thing we know about authorship when the document itself names no author
    handle_received(
      params,
      [from_inbox: true] ++ signed_by_http_signature(args["signed_by"])
    )
    |> Untangle.debug("result of handling incoming AP activity")
  end

  # Every delivery we accept goes on with the document as it reached us (`data_received:`), so it can be relayed unchanged (a group's Announce of it): whatever the handling normalises, this stays as the author sent it.
  # A reply in one of our users' threads is then forwarded to their followers (`Forwarder`). Whom it goes to is asked before handling it, since a `Delete` takes away the reply it is found through.
  defp handle_received(params, opts) do
    case signature_in_body(params, opts) do
      {:ok, opts} -> do_handle_received(params, opts)
      :refetch -> refetch_or_cancel(params, "its proof or LD signature does not hold")
      {:cancel, _reason} = cancel -> cancel
    end
  end

  # Accepted over an HTTP signature: a proof or LD signature in the body is checked too, so what is stored says it vouched for the document. Accepted another way, it was what vouched for it, or was checked already.
  defp signature_in_body(params, opts) do
    if opts[:authenticated] == :http_signature do
      case ActivityPub.Safety.with_author_signature(opts, params) do
        {:ok, opts} ->
          {:ok, opts}

        result ->
          if ActivityPub.Safety.broken_signature?(result),
            do: broken_signature(result, opts),
            else: {:ok, opts}
      end
    else
      {:ok, opts}
    end
  end

  defp broken_signature(result, opts) do
    case ActivityPub.Safety.partly_invalid() do
      :accept ->
        Untangle.warn(
          result,
          "Proof or LD signature does not hold, accepting on the HTTP signature"
        )

        {:ok, opts}

      :refetch ->
        :refetch

      :reject ->
        reason = "Rejecting activity: its proof or LD signature does not hold"
        Untangle.error(result, reason)
        {:cancel, reason}
    end
  end

  defp do_handle_received(params, opts) do
    opts = Keyword.put(opts, :data_received, params)
    forwarding = Forwarder.recipients(params, opts)

    result = ActivityPub.Federator.Transformer.handle_incoming(params, opts)

    Forwarder.maybe_forward(params, result, forwarding)
    result
  end

  # the job argument is only the signer's id, kept as it is so jobs queued before the mark existed still run
  defp signed_by_http_signature(signer) when is_binary(signer),
    do: [authenticated: :http_signature, signed_by: signer]

  defp signed_by_http_signature(_), do: []

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
    Logger.metadata(action: "incoming_unverified_ap_doc", ap_type: params["type"])
    Untangle.debug("Handling incoming AP activity with no verified signature")
    maybe_process_unsigned(headers, params)
  end

  @doc """
  Handles unsigned or unverified incoming AP docs.

  Attempts an integrity proof first, then HTTP signature re-validation, then
  Linked Data Signature verification, then falls back to refetching the
  activity from source.
  """
  def maybe_process_unsigned(headers, params) do
    case IntegrityProofs.check(params) do
      {:valid, controller} ->
        # the proof names who made the document, just as a verified HTTP signature names who sent it, so it stands as the author of one that names none (e.g. relay-forwarded)
        Untangle.info("Valid integrity proof from #{controller}, processing activity")

        handle_received(params,
          from_inbox: true,
          authenticated: :integrity_proof,
          signed_by: controller
        )

      :none ->
        maybe_process_unsigned_cascade(headers, params, false)

      {_invalid_or_unverifiable, reason} = result ->
        Untangle.warn(
          reason,
          "Integrity proof did not verify, falling back to the other ways to authenticate"
        )

        maybe_process_unsigned_cascade(
          headers,
          params,
          ActivityPub.Safety.broken_signature?(result)
        )
    end
  end

  # `invalid?`: a signature did not hold (here a proof in the body; then the actor's HTTP signature, or an LD signature), which decides which config says whether it can be accepted anyway at the end (`accept_anyway?/1`)
  defp maybe_process_unsigned_cascade(headers, params, invalid?) do
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
      handle_received(params, from_inbox: true)
    else
      # the actor's own HTTP signature, which still fails: a signature that does not hold. One by somebody else (a relay passing it on) says nothing about this actor either way
      invalid? =
        if fetch_fresh_public_key? do
          Untangle.warn("HTTP signature still invalid after key re-fetch")
          true
        else
          invalid?
        end

      # Try Linked Data Signature (RsaSignature2017) embedded in the activity body.
      # This covers relay-forwarded activities and activities from shutting-down servers.
      if LinkedDataSignatures.has_verifiable_signature?(params) do
        case LinkedDataSignatures.verify(params) do
          {:ok, creator} ->
            Untangle.info("Valid Linked Data Signature from #{creator}, processing activity")

            # an LD signature verifies an identity just as an HTTP signature does, so it can stand
            # as the author of a document that names none (e.g. relay-forwarded)
            handle_received(params,
              from_inbox: true,
              authenticated: :ld_signature,
              signed_by: creator
            )

          {:error, reason} = result ->
            Untangle.warn(
              reason,
              "Linked Data Signature verification failed, falling back to activity or object refetch"
            )

            maybe_process_unsigned_fallback(
              params,
              invalid? or ActivityPub.Safety.broken_signature?(result)
            )
        end
      else
        maybe_process_unsigned_fallback(params, invalid?)
      end
    end
  end

  # Fallback logic for activities without valid HTTP or LD signatures: tries refetching from source, validates follow responses locally, or accepts anyway when the config says so (`accept_anyway?/1`).
  defp maybe_process_unsigned_fallback(params, invalid?) do
    # Accept/Reject of Follow activities have unfetchable URLs (fragment identifiers like #accepts/follows/)
    # but can be safely validated against our local Follow activity records.
    # This mirrors how Mastodon handles it: https://github.com/mastodon/mastodon/blob/main/app/lib/activitypub/activity/accept.rb
    is_follow_response? =
      is_in(params["type"], ["Accept", "Reject"]) and
        is_map(params["object"]) and params["object"]["type"] == "Follow"

    if is_follow_response? do
      Untangle.debug(
        "Accept/Reject of Follow - validating against local Follow activity (URLs are typically unfetchable)"
      )

      handle_received(params, from_inbox: true)
    else
      case refetch_from_origin(params) do
        {:ok, object} ->
          {:ok, object}

        e ->
          if accept_anyway?(invalid?) do
            Untangle.warn(
              e,
              "No valid signature and re-fetch failed, but accepting because the config says so (incoming_signatures #{if invalid?, do: "invalid", else: "unsigned"}: :accept)"
            )

            handle_received(params, from_inbox: true)
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

  # unsigned and invalid are told apart: accepting what nobody signed is not accepting what a signature says is not what was signed
  defp accept_anyway?(true = _invalid?), do: ActivityPub.Safety.accept_invalid?()
  defp accept_anyway?(false = _invalid?), do: ActivityPub.Safety.accept_unsigned?()

  # the copy its origin serves, in place of the one delivered to us
  defp refetch_from_origin(params) do
    is_deleted? =
      Untangle.debug(
        is_in(params["type"], ["Delete", "Tombstone"]) or
          (is_map(params["object"]) and is_in(params["object"]["type"], ["Tombstone"])),
        "is_deleted?"
      )

    with id when is_binary(id) <- params["id"],
         {:ok, object} <-
           Fetcher.fetch_fresh_object_from_id(id, return_tombstones: is_deleted?) do
      Untangle.debug(object, "Activity verified by re-fetching from source")
      {:ok, object}
    end
  end

  defp refetch_or_cancel(params, why) do
    case refetch_from_origin(params) do
      {:ok, object} ->
        {:ok, object}

      e ->
        reason = "Rejecting activity: #{why}, and re-fetch from source failed"
        Untangle.error(e, reason)
        {:cancel, reason}
    end
  end
end
