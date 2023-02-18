# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Workers.RemoteFetcherWorker do
  use ActivityPub.Workers.WorkerHelper, queue: "remote_fetcher"
  alias ActivityPub.Fetcher

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "fetch_remote", "id" => id} = args}) do
    {:ok, _object} = Fetcher.fetch_object_from_id(id, depth: args["depth"])
  end
end