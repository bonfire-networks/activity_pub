# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.APPublisher do
  alias ActivityPub.Config
  alias ActivityPub.Actor
  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Federator.HTTP
  alias ActivityPub.Instances
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Utils

  import Untangle

  @behaviour ActivityPub.Federator.Publisher

  # handle all types
  def is_representable?(_activity), do: true

  def publish(actor, activity, opts \\ []) do
    {:ok, prepared_activity_data} =
      Transformer.prepare_outgoing(activity.data)

    # |> debug("data ready to publish as JSON")

    # |> info("JSON ready to publish")

    # Utils.maybe_forward_activity(activity)

    # embed the object in the activity JSON
    # object_ap_id = activity.data["object"]
    # object = Object.get_cached!(object_ap_id)
    # activity = Map.put(activity, )

    # TODO: reuse from activity?
    to = activity.data["to"] || []
    cc = activity.data["cc"] || []
    tos = to ++ cc
    is_public? = Utils.has_as_public?(tos)
    type = activity.data["type"]

    recipients =
      recipients(actor, prepared_activity_data, tos, is_public?)
      |> info("initial recipients for #{type}")

    num_recipients = length(recipients)

    case recipients
         |> determine_inboxes(is_public?, type, num_recipients)
         # |> maybe_federate_to_search_index(activity)
         |> Enum.uniq_by(fn {x, _} -> x end)
         |> Map.new()
         #  |> debug("inboxes")
         |> Instances.filter_reachable()
         |> debug("reacheable inboxes") do
      recipients when is_map(recipients) and recipients != %{} ->
        recipients
        |> Enum.map(fn {inbox, meta} ->
          json =
            Transformer.preserve_privacy_of_outgoing(
              prepared_activity_data,
              URI.parse(inbox).host,
              meta[:id]
            )
            # |> debug("safe json")
            |> Jason.encode!()

          params = %{
            inbox: inbox,
            json: json,
            actor_username: Map.get(actor, :username),
            actor_id: Map.get(actor, :id),
            id: prepared_activity_data["id"],
            unreachable_since: meta[:unreachable_since]
          }

          if opts[:federate_inline] do
            publish_one(params)
          else
            ActivityPub.Federator.Publisher.enqueue_one(__MODULE__, params)
          end
        end)

      _other ->
        info(activity, "found nobody to federate this to")
        []
    end
  end

  @doc """
  Publish a single message to a peer.  Takes a struct with the following
  parameters set:

  * `inbox`: the inbox to publish to
  * `json`: the JSON message body representing the ActivityPub message
  * `actor`: the actor which is signing the message
  * `id`: the ActivityStreams URI of the message
  """
  def publish_one(%{json: json, actor: %Actor{} = actor, inbox: inbox} = params) do
    uri = URI.parse(inbox)

    digest = "SHA-256=" <> (:crypto.hash(:sha256, json) |> Base.encode64())
    date = Utils.format_date()

    with {:ok, signature} <-
           ActivityPub.Safety.Keys.sign(actor, %{
             "(request-target)": "post #{uri.path}",
             host: ActivityPub.Safety.Keys.http_host(uri),
             "content-length": byte_size(json),
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

  def publish_one(%{actor_username: username} = params) when is_binary(username) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      params
      |> Map.delete(:actor_username)
      |> Map.put(:actor, actor)
      |> publish_one()
    else
      e ->
        warn(e, "Could not find actor by username `#{username}`, try another way...")
        publish_one(Map.drop(params, [:actor_username]))
    end
  end

  def publish_one(%{actor_id: id} = params) when is_binary(id) do
    debug("special case for Tombstone actor")

    with {:ok, actor} <- ActivityPub.Object.get_cached(id: id) do
      params
      |> Map.delete(:actor_id)
      |> Map.put(:actor, Actor.format_remote_actor(actor))
      |> publish_one()
    else
      e ->
        warn(e, "Could not find actor by ID")
    end
  end

  def publish_one(%{json: json} = params) do
    digest = "SHA-256=" <> (:crypto.hash(:sha256, json) |> Base.encode64())
    date = Utils.format_date()

    error(params, "not adding a signature, because we don't have an actor or inbox")

    do_publish_one(params, date, digest)
  end

  defp do_publish_one(%{inbox: inbox, json: json, id: id} = params, date, digest, headers \\ []) do
    info(inbox, "Federating #{id} to")

    with result = {:ok, %{status: code}} when code in 200..299 <-
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
         do: Instances.set_reachable(inbox)

      debug(result, "remote responded with #{code}")
    else
      {_post_result, %{status: code} = response} ->
        unless params[:unreachable_since], do: Instances.set_unreachable(inbox)
        error(response, "could not push activity to #{inbox}, got HTTP #{code}")

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

  defp recipients(actor, %{data: activity_data}, tos, is_public?),
    do: recipients(actor, activity_data, tos, is_public?)

  defp recipients(actor, activity_data, tos, is_public?) do
    addressed_recipients(activity_data) ++
      (if activity_data["type"] == "Flag" do
         # When handling Flag activities, we need special recipient handling
         flag_recipients(activity_data["object"])
       else
         if is_public? || actor.data["followers"] in tos do
           Actor.get_external_followers(actor, :publish)
           |> debug("external_followers")
         else
           # optionally send it to a subset of followers
           with {:ok, followers} <- Adapter.external_followers_for_activity(actor, activity_data) do
             followers
           else
             e ->
               error(e)
               nil
           end
         end
       end || [])
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
    |> debug("recipients from data")
    |> List.flatten()
    |> Enum.reject(&(is_nil(&1) or Utils.has_as_public?(&1)))
    |> Enum.map(&(Actor.get_cached!(ap_id: &1) || &1))
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
         activity.data["type"] in ["Create", "Update", "Delete"] do
      recipients ++
        [
          index
        ]
    else
      recipients
    end
  end

  @doc """
  Determine a user inbox to use based on heuristics.  These heuristics
  are based on an approximation of the ``sharedInbox`` rules in the
  [ActivityPub specification][ap-sharedinbox].

     [ap-sharedinbox]: https://www.w3.org/TR/activitypub/#shared-inbox-delivery
  """
  def determine_inboxes(
        inboxes,
        is_public?,
        type,
        num_recipients
      )
      when is_list(inboxes) do
    inboxes
    |> Enum.flat_map(&determine_inboxes(&1, is_public?, type, num_recipients))
  end

  def determine_inboxes(
        %{data: actor_data} = _user,
        is_public,
        type,
        num_recipients
      ) do
    cond do
      type in ["Flag", "Delete"] ->
        {maybe_use_sharedinbox(actor_data),
         %{
           id: actor_data["id"]
         }}

      is_public == true ->
        {maybe_use_sharedinbox(actor_data),
         %{
           id: actor_data["id"]
         }}

      num_recipients > 1 ->
        # FIXME: shouldn't this depend on recipients on a given instance?
        {maybe_use_sharedinbox(actor_data),
         %{
           id: actor_data["id"]
         }}

      inbox = actor_data["inbox"] ->
        {inbox,
         %{
           id: actor_data["id"]
         }}

      true ->
        warn(actor_data, "No inbox")

        []
    end
    |> List.wrap()
  end

  def determine_inboxes(inbox, _, _, _) when is_binary(inbox) do
    [{inbox, %{}}]
  end

  def determine_inboxes(user, _, _, _) do
    warn(user, "Invalid actor")
    []
  end

  defp maybe_use_sharedinbox(actor_data),
    do:
      (is_map(actor_data["endpoints"]) && Map.get(actor_data["endpoints"], "sharedInbox")) ||
        actor_data["inbox"]

  def gather_webfinger_links(actor) do
    base_url = ActivityPub.Web.base_url()

    [
      %{
        "rel" => "self",
        "type" => "application/activity+json",
        "href" => actor.data["id"]
      },
      %{
        "rel" => "self",
        "type" => "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
        "href" => actor.data["id"]
      },
      %{
        "rel" => "http://ostatus.org/schema/1.0/subscribe",
        "template" => base_url <> "/pub/remote_interaction?acct={uri}"
      }
    ]
  end
end
