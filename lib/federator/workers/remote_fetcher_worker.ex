# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Workers.RemoteFetcherWorker do
  use ActivityPub.Federator.Worker,
    queue: "remote_fetcher",
    unique: [fields: [:args], keys: [:op, :id]]

  alias ActivityPub.Federator.Fetcher

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "fetch_remote", "id" => id} = args}) do
    Fetcher.fetch_object_from_id(id,
      depth: args["depth"],
      max_depth: args["max_depth"],
      fetch_collection_entries: ActivityPub.Utils.maybe_to_atom(args["fetch_collection_entries"])
    )
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)
end
