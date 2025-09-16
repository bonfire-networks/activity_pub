# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator do
  alias ActivityPub.Actor
  alias ActivityPub.Utils
  alias ActivityPub.Safety.Keys
  alias ActivityPub.Federator.Publisher
  # alias ActivityPub.Federator.Transformer
  alias ActivityPub.Federator.Workers.PublisherWorker

  import Untangle

  def publish(activity, opts \\ [])

  def publish(%{id: activity_id} = activity, opts) do
    if opts[:federate_inline] do
      perform(:publish, activity, opts)
    else
      publish(activity_id, opts)
    end
  end

  def publish(%{"id" => _} = activity, opts) do
    if opts[:federate_inline] do
      perform(:publish, activity, opts)
    else
      PublisherWorker.enqueue(
        "publish",
        build_actor_fields(%{"activity" => activity}, opts[:actor]),
        opts[:worker_args]
      )
    end
  end

  def publish(activity_id, opts) when is_binary(activity_id) do
    PublisherWorker.enqueue(
      "publish",
      build_actor_fields(%{"activity_id" => activity_id}, opts[:actor]),
      opts[:worker_args]
    )
  end

  def perform(task, activity_or_module, params_or_opts \\ [])

  def perform(:publish, %{data: _} = activity, opts) do
    actor_id = activity.data["actor"]

    with {:ok, actor} <- Actor.get_cached(ap_id: actor_id),
         actor <- Keys.add_public_key(actor) do
      debug(activity.data["id"], "Running publish for")

      if opts[:federate_inline] do
        ActivityPub.Federator.APPublisher.publish(actor, activity, opts)
      else
        Publisher.publish(actor, activity)
      end
    else
      e ->
        debug(activity, "Activity with invalid actor")

        error(
          e,
          "Cannot publish because the actor #{inspect(actor_id)} is invalid"
        )
    end
  end

  def perform(:publish_one, module, params) do
    apply(module, :publish_one, [params])
  end

  def perform(type, _, _) do
    error(type, "Unknown federator task")
  end

  defp build_actor_fields(map, nil), do: map
  defp build_actor_fields(map, actor) when is_binary(actor), do: Map.put(map, "actor", actor)

  defp build_actor_fields(map, %{} = actor) do
    map
    |> Utils.maybe_put("user_id", Map.get(actor, :pointer_id))
    |> Utils.maybe_put("username", Map.get(actor, :username))
  end

  defp build_actor_fields(map, _), do: map
end
