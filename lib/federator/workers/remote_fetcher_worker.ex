# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Workers.RemoteFetcherWorker do
  use ActivityPub.Federator.Worker,
    queue: "remote_fetcher",
    unique: [fields: [:args], keys: [:op, :id]]

  alias ActivityPub.Federator.Fetcher

  @impl true
  def perform_job(%Job{args: %{"op" => "fetch_remote", "id" => id} = args}) do
    fetch_fn =
      if args["fresh"],
        do: &Fetcher.fetch_fresh_object_from_id/2,
        else: &Fetcher.fetch_object_from_id/2

    fetch_fn.(id,
      depth: args["depth"],
      max_depth: args["max_depth"],
      # don't fetch pages async when we are already in a background job, to avoid too much nesting of jobs
      mode: true,
      fetch_collection: true,
      fetch_collection_entries: ActivityPub.Utils.maybe_to_atom(args["fetch_collection_entries"]),
      user_id: args["user_id"],
      fetch_context_opener: args["fetch_context_opener"],
      triggered_by: args["context"] || "remote_fetcher_worker"
    )
  end

  # A whole collection, read as the user the job carries, and handed to the adapter with its type and owner, for the extension that claims the type to apply (a group's `members`). The limits come from the job, as the defaults (10 items, 2 more pages) are far under what the caller wants: `max_items` and `max_pages` bound what is read, and `max_total` skips the collection when its root states more items than that, before any page is read. The entries are handed over as the collection lists them (`fetch_collection_entries` "none", the default here), not fetched as objects. A collection that can't be read, or has too many, ends the job; the caller queues it again when it needs to
  def perform_job(%Job{
        args: %{"op" => "fetch_collection", "id" => id, "collection_type" => type} = args
      }) do
    limits =
      for {key, option} <- [
            {"max_items", :max_items},
            {"max_pages", :max_pages},
            {"max_total", :max_total}
          ],
          is_integer(args[key]),
          do: {option, args[key]}

    case Fetcher.fetch_collection(
           id,
           [
             mode: true,
             fetch_collection_entries:
               ActivityPub.Utils.maybe_to_atom(args["fetch_collection_entries"]) || :none,
             user_id: args["user_id"]
           ] ++ limits
         ) do
      {:ok, items} ->
        ActivityPub.Federator.Adapter.handle_remote_collection(
          %{id: id, type: type, owner: args["owner"], user_id: args["user_id"]},
          items
        )

      other ->
        {:cancel, "could not read the collection: #{inspect(other)}"}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)
end
