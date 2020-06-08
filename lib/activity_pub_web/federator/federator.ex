# MoodleNet: Connecting and empowering educators worldwide
# Copyright © 2018-2020 Moodle Pty Ltd <https://moodle.com/moodlenet/>
# Contains code from Pleroma <https://pleroma.social/> and CommonsPub <https://commonspub.org/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.Federator do
  alias ActivityPub.Actor
  alias ActivityPub.Utils
  alias ActivityPubWeb.Federator.Publisher
  alias ActivityPubWeb.Transmogrifier
  alias ActivityPub.Workers.PublisherWorker
  alias ActivityPub.Workers.ReceiverWorker

  require Logger

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
    Logger.debug(fn -> "Running publish for #{activity.data["id"]}" end)

    with {:ok, actor} <- Actor.get_cached_by_ap_id(activity.data["actor"]),
         {:ok, actor} <- Actor.ensure_keys_present(actor) do
      Publisher.publish(actor, activity)
    end
  end

  def perform(:incoming_ap_doc, params) do
    Logger.info("Handling incoming AP activity")

    params = Utils.normalize_params(params)

    Transmogrifier.handle_incoming(params)
  end

  def perform(type, _) do
    Logger.debug(fn -> "Unknown task: #{type}" end)
    {:error, "Don't know what to do with this"}
  end
end
