# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.APPublisher do
  alias ActivityPub.Actor
  alias ActivityPub.Federator.HTTP
  alias ActivityPub.Instances
  alias ActivityPub.Federator.Transformer

  import Untangle

  @behaviour ActivityPub.Federator.Publisher

  # handle all types
  def is_representable?(_activity), do: true

  def publish(actor, activity) do
    {:ok, data} = Transformer.prepare_outgoing(activity.data)

    json =
      Jason.encode!(data)
      |> info("JSON ready to publish")

    # Utils.maybe_forward_activity(activity)

    recipients(actor, activity)
    |> info("initial recipients")
    |> Enum.map(&determine_inbox(activity, &1))
    |> maybe_federate_to_search_index(activity)
    |> Enum.uniq()
    |> info("possible recipients")
    |> Instances.filter_reachable()
    |> info("enqueue for")
    |> Enum.each(fn {inbox, unreachable_since} ->
      ActivityPub.Federator.Publisher.enqueue_one(__MODULE__, %{
        inbox: inbox,
        json: json,
        actor_username: actor.username,
        id: activity.data["id"],
        unreachable_since: unreachable_since
      })
    end)
  end

  @doc """
  Publish a single message to a peer.  Takes a struct with the following
  parameters set:

  * `inbox`: the inbox to publish to
  * `json`: the JSON message body representing the ActivityPub message
  * `actor`: the actor which is signing the message
  * `id`: the ActivityStreams URI of the message
  """
  def publish_one(%{inbox: inbox, json: json, actor: %Actor{} = actor, id: id} = params) do
    info(inbox, "Federating #{id} to")
    %{host: host, path: path} = URI.parse(inbox)

    digest = "SHA-256=" <> (:crypto.hash(:sha256, json) |> Base.encode64())

    date =
      NaiveDateTime.utc_now()
      |> Timex.format!("{WDshort}, {0D} {Mshort} {YYYY} {h24}:{m}:{s} GMT")

    signature =
      ActivityPub.Safety.Signatures.sign(actor, %{
        "(request-target)": "post #{path}",
        host: host,
        "content-length": byte_size(json),
        digest: digest,
        date: date
      })

    with result = {:ok, %{status: code}} when code in 200..299 <-
           HTTP.post(
             inbox,
             json,
             [
               {"Content-Type", "application/activity+json"},
               {"Date", date},
               {"signature", signature},
               {"digest", digest}
             ]
           ) do
      if !Map.has_key?(params, :unreachable_since) ||
           params[:unreachable_since],
         do: Instances.set_reachable(inbox)

      result
    else
      {_post_result, response} ->
        unless params[:unreachable_since], do: Instances.set_unreachable(inbox)
        error(response)
    end
  end

  def publish_one(%{actor_username: username} = params) do
    {:ok, actor} = Actor.get_cached(username: username)

    params
    |> Map.delete(:actor_username)
    |> Map.put(:actor, actor)
    |> publish_one()
  end

  defp recipients(actor, activity) do
    {:ok, followers} =
      if actor.data["followers"] in ((activity.data["to"] || []) ++
                                       (activity.data["cc"] || [])) do
        Actor.get_external_followers(actor) |> info("external_followers")
      else
        {:ok, []}
      end

    (remote_recipients(actor, activity) |> info("remote_recipients")) ++
      followers
  end

  # TODO: add bcc
  defp remote_recipients(_actor, %{data: data}) do
    ([Map.get(data, "to", nil)] ++
       [Map.get(data, "bto", nil)] ++
       [Map.get(data, "cc", nil)] ++
       [Map.get(data, "bcc", nil)] ++
       [Map.get(data, "audience", nil)] ++ [Map.get(data, "context", nil)])
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> List.delete(ActivityPub.Config.public_uri())
    |> Enum.map(&(Actor.get_cached!(ap_id: &1) || &1))
    |> Enum.reject(fn
      %{local: local} = actor ->
        info(actor, "Local actor?")

        local

      actor ->
        warn(actor, "Invalid actor")
        true
    end)
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

  Please do not edit this function (or its children) without reading
  the spec, as editing the code is likely to introduce some breakage
  without some familiarity.

     [ap-sharedinbox]: https://www.w3.org/TR/activitypub/#shared-inbox-delivery
  """
  def determine_inbox(
        %{data: activity_data},
        %{data: %{"inbox" => inbox}} = user
      ) do
    to = activity_data["to"] || []
    cc = activity_data["cc"] || []
    type = activity_data["type"]

    cond do
      type == "Delete" ->
        maybe_use_sharedinbox(user)

      ActivityPub.Config.public_uri() in to or ActivityPub.Config.public_uri() in cc ->
        maybe_use_sharedinbox(user)

      length(to) + length(cc) > 1 ->
        maybe_use_sharedinbox(user)

      true ->
        inbox
    end
  end

  def determine_inbox(_, user) do
    warn(user, "No inbox")
    nil
  end

  defp maybe_use_sharedinbox(%{data: data}),
    do:
      (is_map(data["endpoints"]) && Map.get(data["endpoints"], "sharedInbox")) ||
        data["inbox"]

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
