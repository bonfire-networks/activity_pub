# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.APPublisher do
  import ActivityPub.Config
  alias ActivityPub.Config
  alias ActivityPub.Actor
  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Federator.HTTP
  alias ActivityPub.Federator.HTTP.RetryAfter
  alias ActivityPub.Instances
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Utils
  alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter

  import Untangle

  @behaviour ActivityPub.Federator.Publisher

  # handle all types
  def is_representable?(_activity), do: true

  @doc "Publish/federate activity (or usually enqueue for publication) to all desired actors/instances."
  def publish(actor, activity, opts \\ []) do
    case prepare_publish_params(actor, activity) do
      params_list when is_list(params_list) and params_list != [] ->
        Enum.map(params_list, fn params ->
          if opts[:federate_inline] do
            publish_one(params)
          else
            ActivityPub.Federator.Publisher.enqueue_one(__MODULE__, actor, params)
          end
        end)

      _other ->
        []
    end
  end

  @doc """
  Builds the list of per-inbox params (including the JSON payload) that would be passed to `publish_one/1` or enqueued for async delivery.
  """
  def prepare_publish_params(actor, activity) do
    # embed the object in the activity JSON (note: already being done in prepare_outgoing)
    # object_ap_id = activity.data["object"]
    # object = Object.get_cached!(object_ap_id)
    # activity = Map.put(activity, :object, object)

    {:ok, prepared_activity_data} =
      Transformer.prepare_outgoing(activity.data)
      |> debug("prepared_activity_data")

    # a group relay goes out in BOTH shapes (see `Transformer.wrapped_relay_data/2`), built once here rather than per inbox, since one payload is fanned out to every recipient below
    wrapped_relay_data =
      Transformer.wrapped_relay_data(actor, prepared_activity_data)
      |> debug("wrapped_relay_data")

    # Utils.maybe_forward_activity(prepared_activity_data)

    to = activity.data["to"] || []
    cc = activity.data["cc"] || []
    tos = to ++ cc
    is_public? = Utils.has_as_public?(tos)
    type = activity.data["type"]

    case recipients(actor, prepared_activity_data, tos, is_public?)
         |> debug("initial recipients for #{type}")
         |> Enum.group_by(fn
           %{data: actor_data} ->
             maybe_use_sharedinbox(actor_data)

           inbox when is_binary(inbox) ->
             inbox

           other ->
             err(other, "dunno how to determine inbox for recipient")
             nil
         end)
         |> debug("initial inboxes")
         |> Enum.map(fn {inbox, recipients} ->
           ids =
             Enum.map(recipients, fn
               %{data: %{"id" => id}} -> id
               _ -> nil
             end)

           if is_in(type, ["Flag", "Delete"]) or length(ids) > 1 do
             {inbox, %{ids: ids}}
           else
             {List.first(recipients).data["inbox"], %{ids: ids}}
           end
         end)
         |> debug("determined inboxes")
         |> Enum.uniq_by(fn {inbox, _} -> inbox end)
         |> Map.new()
         |> Instances.filter_reachable()
         |> debug("reacheable inboxes") do
      recipients when is_map(recipients) and recipients != %{} ->
        Enum.flat_map(recipients, fn {inbox, meta} ->
          # one entry per shape per inbox: this is the last point before delivery, and the only one where the target host is in scope, so narrowing "both shapes to everyone" to "the shape this host understands" would be a change here rather than a redesign
          [prepared_activity_data, wrapped_relay_data]
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn data ->
            json =
              Transformer.preserve_privacy_of_outgoing(
                data,
                Utils.authority(inbox),
                meta[:ids]
              )
              |> debug("safe json")
              |> Jason.encode!()

            %{
              inbox: inbox,
              json: json,
              actor_username: Map.get(actor, :username),
              actor_id: Map.get(actor, :id),
              actor_ap_id: Map.get(actor, :ap_id) || (Map.get(actor, :data) || %{})["id"],
              id: data["id"],
              unreachable_since: meta[:unreachable_since]
            }
          end)
        end)

      _other ->
        info(activity, "found nobody to federate this to")
        []
    end
  end

  @doc """
  Publish a single message to a peer.  Takes a struct with the following parameters set:

  * `inbox`: the inbox to publish to
  * `json`: the JSON message body representing the ActivityPub message
  * `actor`: the actor which is signing the message
  * `id`: the ActivityStreams URI of the message
  """
  def publish_one(%{actor: %Actor{} = actor, inbox: _inbox} = params) do
    sign_and_publish_one(actor, params |> Map.delete(:actor))
  end

  def publish_one(%{actor_id: id, inbox: _inbox} = params) when is_binary(id) do
    with {:ok, actor} <- Actor.get_cached(id: id) do
      sign_and_publish_one(actor, params)
    else
      {:error, :not_found} ->
        with {:ok, actor} <- ActivityPub.Object.get_cached(id: id) do
          debug("special case to check for Tombstone actor")

          Actor.format_remote_actor(actor)
          |> sign_and_publish_one(params)
        else
          _ ->
            warn(id, "Could not find actor by ID, trying other methods")
            publish_one(Map.drop(params, [:actor_id]))
        end

      e ->
        warn(e, "Error while looking up actor, trying other methods")
        publish_one(Map.drop(params, [:actor_id]))
    end
  end

  def publish_one(%{actor_ap_id: ap_id, inbox: _inbox} = params) when is_binary(ap_id) do
    with {:ok, actor} <- Actor.get_cached(ap_id: ap_id) do
      sign_and_publish_one(actor, params)
    else
      {:error, :not_found} ->
        with {:ok, actor} <- ActivityPub.Object.get_cached(ap_id: ap_id) do
          debug("special case to check for Tombstone actor")

          Actor.format_remote_actor(actor)
          |> sign_and_publish_one(params)
        else
          _ ->
            warn(ap_id, "Could not find actor by AP ID, trying other methods")
            publish_one(Map.drop(params, [:actor_ap_id]))
        end

      _ ->
        warn(ap_id, "Could not find actor by AP ID, trying other methods")
        publish_one(Map.drop(params, [:actor_ap_id]))
    end
  end

  def publish_one(%{actor_username: username} = params) when is_binary(username) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      sign_and_publish_one(actor, params)
    else
      {:error, :not_found} ->
        warn(username, "Could not find actor by username, trying other methods")
        publish_one(Map.drop(params, [:actor_username]))

      e ->
        warn(e, "Error while looking up actor by username `#{username}`, trying other methods")
        publish_one(Map.drop(params, [:actor_username]))
    end
  end

  def publish_one(%{json: _json} = params) do
    publish_one_unsigned(params)
  end

  defp sign_and_publish_one(actor, %{json: json, inbox: inbox} = params) do
    # both checks come before signing, since the cheapest delivery to a host in trouble is the one we never build
    cond do
      too_stale?(params) ->
        warn(
          inbox,
          "giving up on a delivery that has been waiting too long to still be worth making"
        )

        {:cancel, "delivery too old"}

      seconds = Instances.pacing_snooze_sec(inbox) ->
        info(inbox, "backing off from a failing host for #{seconds}s, rescheduling this delivery")
        {:snooze, seconds}

      true ->
        do_sign_and_publish_one(actor, params, json, inbox)
    end
  end

  @doc """
  Whether a delivery has been waiting long enough that making it would be worse than dropping it.

  Riding the backoff curve costs a job nothing, since each snooze raises `max_attempts`, so nothing else ever stops a delivery to a host that stays down. Staleness is what should: by the time an activity is days late the post may have been edited or deleted and the `Follow` revoked, and nothing guarantees the `Delete` queued behind it arrives afterwards.

  ⚠️ Reaching this must CANCEL rather than error. A delivery that has been snoozing for days has as many attempts banked as it has snoozes, so an error here would retry it that many times against a host we have just decided is not worth delivering to.

  `queued_at` comes from the Oban job's `inserted_at`, which `PublisherWorker` passes down: the publisher cannot see the job. A delivery made outside a job carries none, and is never too old.
  """
  def too_stale?(%{queued_at: queued_at}) when not is_nil(queued_at) do
    case Utils.to_datetime(queued_at) do
      %DateTime{} = queued_at ->
        max_age_days = Config.get([:instance, :federation_delivery_max_age_days], 6)
        DateTime.diff(DateTime.utc_now(), queued_at, :second) > max_age_days * 24 * 3600

      # an unreadable timestamp says nothing about age, and refusing to deliver on that basis would be the more damaging guess
      _ ->
        false
    end
  end

  def too_stale?(_), do: false

  defp do_sign_and_publish_one(actor, params, json, inbox) do
    uri = URI.parse(inbox)

    # log-only (host cardinality is unbounded — not a StormRecorder counter key): during fan-out,
    # greping the storm window shows which remote instance's slow deliveries hold worker slots
    Logger.metadata(target_host: uri.host)
    format = Instances.get_or_discover_signature_format(uri)

    case format do
      :rfc9421 -> publish_one_rfc9421(params, actor, uri, json)
      _cavage -> publish_one_cavage(params, actor, uri, json)
    end
  end

  def publish_one_unsigned(%{json: json} = params) do
    digest = "SHA-256=" <> (:crypto.hash(:sha256, json) |> Base.encode64())
    date = Utils.format_date()

    warn(params, "not adding a signature, because we don't have an actor or inbox")

    do_publish_one(params, date, digest)
  end

  defp publish_one_rfc9421(params, actor, uri, json) do
    content_digest = "sha-256=:" <> Base.encode64(:crypto.hash(:sha256, json)) <> ":"

    # Provide sub-components so resolve_component("@target-uri") can reconstruct the full URI
    headers = %{
      "@method" => "POST",
      "@scheme" => uri.scheme || "https",
      "@authority" => ActivityPub.Safety.Keys.http_host(uri),
      "@path" => uri.path || "/",
      "content-digest" => content_digest
    }

    with {:ok, {sig_input, sig}} <-
           ActivityPub.Safety.Keys.sign(actor, headers,
             format: :rfc9421,
             components: ["@method", "@target-uri", "content-digest"]
           ) do
      debug(sig_input, "RFC 9421 outgoing signature-input")
      debug(headers, "RFC 9421 outgoing headers/components")

      do_publish_one(
        params,
        Utils.format_date(),
        content_digest,
        [{"signature-input", sig_input}, {"signature", sig}, {"content-digest", content_digest}]
      )
    else
      e ->
        error(e, "problem adding RFC 9421 signature, falling back to cavage")
        publish_one_cavage(params, actor, uri, json)
    end
  end

  defp publish_one_cavage(params, actor, uri, json) do
    digest = "SHA-256=" <> (:crypto.hash(:sha256, json) |> Base.encode64())
    date = Utils.format_date()

    with {:ok, signature} <-
           ActivityPub.Safety.Keys.sign(actor, %{
             "(request-target)": "post #{uri.path}",
             host: ActivityPub.Safety.Keys.http_host(uri),
             "content-length": byte_size(json),
             "content-type": "application/activity+json",
             digest: digest,
             date: date
           }) do
      do_publish_one(params, date, digest, [{"signature", signature}])
    else
      e ->
        error(e, "problem adding a signature, skip")
        do_publish_one(params, date, digest)
    end
  end

  defp do_publish_one(%{inbox: inbox, json: json, id: id} = params, date, digest, headers \\ []) do
    info(inbox, "Federating #{id} to")

    with result = {:ok, %{status: code} = response} when code in 200..299 <-
           HTTP.post(
             inbox,
             json,
             headers ++
               [
                 {"content-type", "application/activity+json"},
                 {"date", date},
                 {"digest", digest}
               ]
           ) do
      if !Map.has_key?(params, :unreachable_since) ||
           params[:unreachable_since],
         do: Instances.handle_successful_contact(inbox)

      SignaturesAdapter.maybe_cache_accept_signature(inbox, response)
      maybe_observe_delivery(inbox, json, code, Map.get(response, :body))
      debug(result, "remote responded with #{code}")
    else
      {_post_result, %{status: code, body: body} = response} ->
        if unreachable_status?(code) and !params[:unreachable_since],
          do: Instances.set_unreachable(inbox)

        SignaturesAdapter.maybe_cache_accept_signature(inbox, response)
        maybe_observe_delivery(inbox, json, code, body)

        delivery_refused(inbox, code, body, Map.get(response, :headers, []))

      {_post_result, response} when is_binary(response) or is_atom(response) ->
        unless params[:unreachable_since], do: Instances.set_unreachable(inbox)
        error("could not push activity to #{inbox}, got: #{response}")

      {_post_result, response} ->
        unless params[:unreachable_since], do: Instances.set_unreachable(inbox)
        error(response, "could not push activity to #{inbox}, got")
        #  so we can see the result in Sentry
        {:error, "could not push activity to #{inbox}, got: #{inspect(response)}"}
    end
  end

  @doc """
  Whether a delivery that got this status is worth attempting again.

  A 4xx is the receiver saying THIS PAYLOAD is wrong, and identical bytes get refused identically, so it is discarded rather than retried. The exceptions describe the moment rather than the document: 408, where the server could not take the request in time, and 429, where it is shedding load.

  This is not academic since the group relay, which sends both announce shapes so that receivers understanding either can file it: Lemmy answers the shape it cannot parse with a 400 every single time.
  """
  def retryable_status?(status) when status in [408, 429], do: true
  def retryable_status?(status) when is_integer(status) and status >= 500, do: true
  def retryable_status?(_), do: false

  @doc """
  Whether this status counts towards giving up on the host.

  `Instances` treats the flag as a clock rather than a block: it changes nothing until the host has failed continuously past `federation_reachability_timeout_days`, and any success in either direction clears it. So the question each status answers is "if this were all we ever got for that long, should we stop trying?"

  A host that answers is reachable, whatever it answered, which leaves three cases that count. 408, where the server says it could not take the request in time, is a timeout it happened to report. 502, 503 and 504 come from the gateway in front of an application that is not answering, which is the same condition as no answer at all.

  **A plain 500 does NOT count**, and the distinction is worth keeping: that is their application erroring on our document, which says nothing about the host being there, and a genuinely dead instance answers with a refused connection rather than a 500.
  """
  def unreachable_status?(status) when status in [408, 502, 503, 504], do: true
  def unreachable_status?(_), do: false

  # Log the BODY, not the whole `%Tesla.Env{}`: remote error messages are the single most useful diagnostic (Lemmy's parse errors name the offending field), and inspecting the env truncates long before reaching `body:`.
  defp delivery_refused(inbox, code, body, headers) do
    cond do
      not retryable_status?(code) ->
        warn(body, "#{inbox} refused this activity with HTTP #{code}, so not sending it again")
        {:cancel, "refused with HTTP #{code}"}

      # an overloaded host naming its own recovery time is better information than our backoff guessing. Unlike the 429 case, which `HTTP.RetryAfter` absorbs, this one had to reach us first so the failure above could be recorded
      seconds = RetryAfter.retry_after_sec(headers) ->
        info(body, "#{inbox} is unavailable for #{seconds}s (HTTP #{code}), rescheduling")
        {:snooze, seconds}

      # a host we already know is failing: reschedule rather than error, so riding out the outage does not spend the job's three attempts. What stops it eventually is the delivery age limit, not the attempt count
      seconds = Instances.failure_snooze_sec(inbox) ->
        info(body, "#{inbox} is still failing (HTTP #{code}), retrying in #{seconds}s")
        {:snooze, seconds}

      true ->
        error(body, "could not push activity to #{inbox}, got HTTP #{code}")
    end
  end

  # The outgoing half of `ActivityPub.Observer`: what we sent, where, and what they made of it. Only decodes when someone is watching, since a delivery otherwise never needs the payload parsed. Transport failures with no HTTP response are skipped: there is no answer to record.
  defp maybe_observe_delivery(inbox, json, status, body) do
    if ActivityPub.Observer.observing?() do
      case Jason.decode(json) do
        {:ok, document} ->
          ActivityPub.Observer.maybe_observe(document, %{
            source: :delivery,
            url: inbox,
            status: status,
            body: body
          })

        _ ->
          :ok
      end
    end
  end

  defp recipients(actor, %{data: activity_data}, tos, is_public?),
    do: recipients(actor, activity_data, tos, is_public?)

  defp recipients(actor, activity_data, tos, is_public?) do
    addressed = addressed_recipients(activity_data)

    # Collect pointer_ids of already-addressed recipients to skip redundant lookups
    addressed_pointer_ids =
      addressed
      |> Enum.map(fn
        %{pointer_id: pid} when is_binary(pid) -> pid
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    followers =
      cond do
        # Accept/Reject should only go to addressed recipients, not fan out to followers
        is_in(activity_data["type"], ["Accept", "Reject"]) ->
          []

        # When handling Flag activities, we need special recipient handling
        activity_data["type"] == "Flag" ->
          flag_recipients(activity_data["object"])

        is_public? || actor.data["followers"] in tos ->
          get_external_followers_except(actor, :publish, addressed_pointer_ids)

        true ->
          # optionally send it to a subset of followers
          with {:ok, followers} <-
                 Adapter.external_followers_for_activity(
                   actor,
                   activity_data,
                   addressed_pointer_ids
                 )
                 |> debug("external_followers_for_activity from Adapter") do
            followers
          else
            e ->
              error(e)
              nil
          end
      end || []

    addressed ++ followers
  end

  defp get_external_followers_except(actor, purpose, addressed_pointer_ids) do
    exclude_set = MapSet.new(addressed_pointer_ids)

    Adapter.get_follower_local_ids(actor, purpose)
    |> Enum.reject(&(is_nil(&1) or MapSet.member?(exclude_set, &1)))
    |> Actor.list_cached()
    |> Enum.filter(fn x -> !x.local end)
    # apply the same outgoing federation gate as the addressed/non-public path, so e.g. an
    # allowlist-only instance doesn't fan a public post out to non-allowlisted remote followers
    |> Enum.filter(&Adapter.federation_allowed?(&1, direction: :out, by_actor: actor))
    |> debug("external_followers (excluding already addressed)")
  end

  defp flag_recipients(objects) when is_list(objects) do
    Enum.flat_map(objects, fn object_id -> flag_recipients(object_id) end)
  end

  defp flag_recipients(object_id) when is_binary(object_id) do
    # When handling Flag activities, we need special recipient handling
    case ActivityPub.Object.get_cached(ap_id: object_id) do
      {:ok, %{data: object_data}} ->
        # Check if the object is an actor
        if Map.has_key?(object_data, "type") &&
             object_data["type"] in Config.supported_actor_types() do
          # Use the actor's shared outbox recipients
          if inbox = (object_data["endpoints"] || %{})["sharedInbox"] do
            [inbox]
          else
            warn("actor has not sharedInbox endpoint")
            nil
          end
        else
          # Look up the object's attributedTo and use that actor's shared outbox
          actor = Map.get(object_data, "attributedTo") || Map.get(object_data, "actor")

          if is_binary(actor) do
            case Actor.get_cached(ap_id: actor) do
              {:ok, %{data: %{"endpoints" => %{"sharedInbox" => inbox}}}} ->
                [inbox]

              e ->
                warn(e, "could not find attributed actor or sharedInbox for flag")
                nil
            end
          else
            warn(actor, "flag target has no attributedTo")
            nil
          end
        end

      e ->
        warn(e, "could not find object for flag")
        nil
    end || []
  end

  defp flag_recipients(objects) do
    error(objects, "could not recognise object for flag")
    []
  end

  defp addressed_recipients(data) do
    ap_base_url = Utils.ap_base_url()
    public_uris = ActivityPub.Config.public_uris()

    [
      Map.get(data, "to", nil),
      Map.get(data, "bto", nil),
      Map.get(data, "cc", nil),
      Map.get(data, "bcc", nil),
      Map.get(data, "audience", nil),
      Map.get(data, "context", nil)
    ]
    |> List.flatten()
    |> debug("recipients from data")
    |> Enum.reject(&(is_nil(&1) or Utils.has_as_public?(&1)))
    |> Enum.map(fn ap_id ->
      case Actor.get_cached(ap_id: ap_id) do
        {:ok, actor} -> actor
        _ -> ap_id
      end
    end)
    |> Enum.reject(fn
      %{local: true} ->
        true

      # FIXME: temporary workaround for bad data
      %{data: %{"id" => id}} ->
        String.starts_with?(id, ap_base_url)

      %{local: false} ->
        false

      actor ->
        warn(actor, "Not a valid actor")
        true
    end)
    |> debug()
  end

  @doc """
  If you put the URL of the shared inbox of an ActivityPub instance in the following env variable, all public content will be pushed there via AP federation for search indexing purposes: PUSH_ALL_PUBLIC_CONTENT_TO_INSTANCE
  #TODO: move to adapter
  """
  def maybe_federate_to_search_index(recipients, activity) do
    index = System.get_env("PUSH_ALL_PUBLIC_CONTENT_TO_INSTANCE", "false")

    if index !== "false" and
         activity.public and
         is_in(activity.data["type"], ["Create", "Update", "Delete"]) do
      recipients ++
        [
          index
        ]
    else
      recipients
    end
  end

  defp maybe_use_sharedinbox(actor_data),
    do:
      (is_map(actor_data["endpoints"]) && Map.get(actor_data["endpoints"], "sharedInbox")) ||
        actor_data["inbox"]

  def gather_webfinger_links(%{data: %{"id" => id}}), do: gather_webfinger_links(id)
  def gather_webfinger_links(%{"id" => id}), do: gather_webfinger_links(id)

  def gather_webfinger_links(id) when is_binary(id) do
    base_url = ActivityPub.Web.base_url()

    [
      %{
        "rel" => "self",
        "type" => "application/activity+json",
        "href" => id
      },
      %{
        "rel" => "self",
        "type" => "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
        "href" => id
      },
      %{
        "rel" => "http://ostatus.org/schema/1.0/subscribe",
        "template" => base_url <> "/pub/remote_interaction?acct={uri}"
      }
    ]
  end
end
