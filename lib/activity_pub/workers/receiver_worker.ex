# MoodleNet: Connecting and empowering educators worldwide
# Copyright © 2018-2020 Moodle Pty Ltd <https://moodle.com/moodlenet/>
# Contains code from Pleroma <https://pleroma.social/> and CommonsPub <https://commonspub.org/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Workers.ReceiverWorker do
  alias ActivityPubWeb.Federator

  use ActivityPub.Workers.WorkerHelper, queue: "federator_incoming"

  @impl Oban.Worker
  def perform(%{"op" => "incoming_ap_doc", "params" => params}, _job) do
    Federator.perform(:incoming_ap_doc, params)
  end
end
