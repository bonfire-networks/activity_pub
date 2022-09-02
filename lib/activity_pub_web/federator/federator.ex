# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.Federator do
  alias ActivityPub.Actor
  alias ActivityPub.Utils
  alias ActivityPubWeb.Federator.Publisher
  alias ActivityPubWeb.Transmogrifier
  alias ActivityPub.Workers.PublisherWorker
  alias ActivityPub.Workers.ReceiverWorker

  import Untangle

  def incoming_ap_doc(params) do
    ReceiverWorker.enqueue("incoming_ap_doc", %{"params" => params})
  end

  def publish(activity) do
    PublisherWorker.enqueue("publish", %{"activity_id" => activity.id})
  end

  @spec perform(atom(), module(), any()) :: {:ok, any()} | {:error, any()}
  def perform(:publish_one, module, params) do
    apply(module, :publish_one, [params])
  end

  def perform(:publish, activity) do
    actor_id = activity.data["actor"]
    with {:ok, actor} <- Actor.get_cached_by_ap_id(actor_id),
         {:ok, actor} <- Actor.ensure_keys_present(actor) do

      debug(activity.data["id"], "Running publish for")
      Publisher.publish(actor, activity)

    else e ->
      error(e, "Cannot publish because the actor #{inspect actor_id} is invalid")
    end
  end

  def perform(:incoming_ap_doc, params) do
    debug("Handling incoming AP activity")

    params = Utils.normalize_params(params)

    Transmogrifier.handle_incoming(params)
  end

  def perform(type, _) do
    error(type, "Unknown federator task")
    {:error, "Don't know what to do with this"}
  end
end
