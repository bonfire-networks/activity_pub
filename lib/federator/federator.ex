# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator do
  alias ActivityPub.Actor
  # alias ActivityPub.Utils
  alias ActivityPub.Federator.Publisher
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Federator.Workers.PublisherWorker
  alias ActivityPub.Federator.Workers.ReceiverWorker

  import Untangle

  def incoming_ap_doc(params) do
    ReceiverWorker.enqueue("incoming_ap_doc", %{"params" => params})
  end

  def publish(%{id: activity}) do
    publish(activity)
  end

  def publish(%{"id" => _} = activity) do
    PublisherWorker.enqueue("publish", %{"activity" => activity})
  end

  def publish(activity) when is_binary(activity) do
    PublisherWorker.enqueue("publish", %{"activity_id" => activity})
  end

  @spec perform(atom(), module(), any()) :: {:ok, any()} | {:error, any()}
  def perform(:publish_one, module, params) do
    apply(module, :publish_one, [params])
  end

  def perform(:publish, %{data: _} = activity) do
    actor_id = activity.data["actor"]

    with {:ok, actor} <- Actor.get_cached(ap_id: actor_id),
         actor <- Actor.add_public_key(actor) do
      debug(activity.data["id"], "Running publish for")
      Publisher.publish(actor, activity)
    else
      e ->
        error(
          e,
          "Cannot publish because the actor #{inspect(actor_id)} is invalid"
        )
    end
  end

  def perform(:incoming_ap_doc, params) do
    debug("Handling incoming AP activity")

    Transformer.handle_incoming(params)
  end

  def perform(type, _) do
    error(type, "Unknown federator task")
  end
end
