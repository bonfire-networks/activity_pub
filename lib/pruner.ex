defmodule ActivityPub.Pruner do
  @moduledoc """
  Prunes objects from the database.
  """
  @remote_misc_retention_days 10
  @remote_post_retention_days 30

  alias ActivityPub.Object
  alias ActivityPub.Config
  alias ActivityPub.Utils
  import Utils
  import Ecto.Query
  require Logger

  def prune_all(cutoff_days \\ nil) do
    Logger.info("Pruning old data from the database")
    prune_objects(remote_post_retention_days: cutoff_days)

    prune_deletes(cutoff_days)

    prune_stale_follow_requests(cutoff_days)

    prune_undos(cutoff_days)

    prune_removes(cutoff_days)

    prune_tombstones(cutoff_days)
  end

  def prune_objects(
        options \\ [prune_orphaned_activities: true, keep_threads: false, keep_non_public: false]
      ) do
    # TODO: do not keep threads by default after we're sure reply_to still works for pruned posts

    deadline =
      options[:remote_post_retention_days] ||
        Config.get([:instance, :remote_post_retention_days], @remote_post_retention_days)

    time_deadline = NaiveDateTime.utc_now() |> NaiveDateTime.add(-(deadline * 86_400))

    log_message = "Pruning objects older than #{deadline} days"

    log_message =
      if Keyword.get(options, :keep_non_public) do
        log_message <> ", keeping non public posts"
      else
        log_message
      end

    log_message =
      if Keyword.get(options, :keep_threads) do
        log_message <> ", keeping threads intact"
      else
        log_message
      end

    log_message =
      if Keyword.get(options, :prune_orphaned_activities) do
        log_message <> ", pruning orphaned activities"
      else
        log_message
      end

    Logger.info(log_message)

    if Keyword.get(options, :keep_threads) do
      # Filter objects from threads where:
      # 1. the newest post is still old
      # 2. none of the activities is local
      # 3. optionally none of the posts is non-public
      deletable_context =
        if Keyword.get(options, :keep_non_public) do
          Object
          |> group_by([a], fragment("? ->> 'context'::text", a.data))
          |> having(
            [a],
            not fragment(
              # Posts (checked on Create Activity) is non-public
              "bool_or((not(?->'to' \\? ? OR ?->'cc' \\? ?)) and ? ->> 'type' = 'Create')",
              a.data,
              ^Config.public_uri(),
              a.data,
              ^Config.public_uri(),
              a.data
            )
          )
        else
          Object
          |> group_by([a], fragment("? ->> 'context'::text", a.data))
        end
        |> having([a], max(a.updated_at) < ^time_deadline)
        |> having([a], not fragment("bool_or(?)", a.local))
        |> select([a], fragment("? ->> 'context'::text", a.data))

      Object
      |> where([o], fragment("? ->> 'context'::text", o.data) in subquery(deletable_context))
    else
      if Keyword.get(options, :keep_non_public) do
        Object
        |> where(
          [o],
          fragment(
            "?->'to' \\? ? OR ?->'cc' \\? ?",
            o.data,
            ^Config.public_uri(),
            o.data,
            ^Config.public_uri()
          )
        )
      else
        Object
      end
      |> where([o], o.updated_at < ^time_deadline)
      |> where(
        [o],
        fragment("split_part(?->>'actor', '/', 3) != ?", o.data, ^Utils.ap_base_url())
      )
    end
    |> repo().delete_all(timeout: :infinity)
    |> IO.inspect(label: "pruned objects")

    if Keyword.get(options, :prune_orphaned_activities) do
      prune_orphaned_activities()
    end
  end

  def prune_orphaned_activities do
    # Prune activities who were linked to a single pruned object
    """
    delete from ap_object
    where id in (
      select a.id from ap_object a
      left join ap_object o on a.data ->> 'object' = o.data ->> 'id'
      left join ap_object a2 on a.data ->> 'object' = a2.data ->> 'id'
      where a.is_object != true 
      and not a.local
      and jsonb_typeof(a."data" -> 'object') = 'string'
      and o.id is null
      and a2.id is null
    )
    """
    |> repo().query([], timeout: :infinity)
    |> IO.inspect(label: "pruned orphaned activities - part 1")

    # Prune activities who were linked to an array of pruned objects
    """
    delete from  ap_object
    where id in (
      select a.id from  ap_object a
      join json_array_elements_text((a."data" -> 'object')::json) as j on jsonb_typeof(a."data" -> 'object') = 'array'
      left join ap_object o on j.value = o.data ->> 'id'
      left join ap_object a2 on j.value = a2.data ->> 'id'
      where a.is_object != true 
      group by a.id
      having max(o.data ->> 'id') is null
      and max(a2.data ->> 'id') is null
    )
    """
    |> repo().query([], timeout: :infinity)
    |> IO.inspect(label: "pruned orphaned activities - part 2")
  end

  def prune_deletes(cutoff_days) do
    before_time = cutoff(cutoff_days)

    from(a in Object,
      where: fragment("?->>'type' = ?", a.data, "Delete") and a.inserted_at < ^before_time
    )
    |> repo().delete_all(timeout: :infinity)
    |> IO.inspect(label: "removed Delete activities")
  end

  def prune_undos(cutoff_days) do
    before_time = cutoff(cutoff_days)

    from(a in Object,
      where: fragment("?->>'type' = ?", a.data, "Undo") and a.inserted_at < ^before_time
    )
    |> repo().delete_all(timeout: :infinity)
    |> IO.inspect(label: "removed Undo activities")
  end

  def prune_removes(cutoff_days) do
    before_time = cutoff(cutoff_days)

    from(a in Object,
      where: fragment("?->>'type' = ?", a.data, "Remove") and a.inserted_at < ^before_time
    )
    |> repo().delete_all(timeout: :infinity)
    |> IO.inspect(label: "removed Remove activities")
  end

  def prune_stale_follow_requests(cutoff_days) do
    before_time = cutoff(cutoff_days)

    from(a in Object,
      where:
        fragment("?->>'type' = ?", a.data, "Follow") and a.inserted_at < ^before_time and
          fragment("?->>'state' = ?", a.data, "reject")
    )
    |> repo().delete_all(timeout: :infinity)
    |> IO.inspect(label: "removed stale Follow requests")
  end

  def prune_tombstones(cutoff_days) do
    before_time = cutoff(cutoff_days)

    from(o in Object,
      where: fragment("?->>'type' = ?", o.data, "Tombstone") and o.inserted_at < ^before_time
    )
    |> repo().delete_all(timeout: :infinity, on_delete: :delete_all)
    |> IO.inspect(label: "removed old Tombstone activities")
  end

  def remove_embedded_objects do
    Logger.info("Removing embedded objects")

    repo().query!(
      "update ap_object set data = safe_jsonb_set(data, '{object}'::text[], data->'object'->'id') where data->'object'->>'id' is not null;",
      [],
      timeout: :infinity
    )
    |> IO.inspect(label: "removed embedded objects")
  end

  defp cutoff(cutoff_days) do
    cutoff =
      cutoff_days ||
        Config.get([:instance, :remote_misc_retention_days], @remote_misc_retention_days)

    DateTime.utc_now() |> Timex.shift(days: -cutoff)
    # TODO: use `NaiveDateTime.diff` ?
  end

  defmodule PruneDatabaseWorker do
    @moduledoc """
    The worker to prune old data from the database.
    """
    require Logger
    use Oban.Worker, queue: "database_prune"
    # TODO: schedule this worker to run automatically

    @impl Oban.Worker
    def perform(_job) do
      ActivityPub.Pruner.prune_all()

      :ok
    end
  end
end
