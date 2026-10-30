defmodule ActivityPub.Object do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  import ActivityPub.Queries.Fragments
  import Untangle
  use Arrows
  import ActivityPub.Config, only: [is_in: 2]

  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Actor
  alias ActivityPub.Object
  alias ActivityPub.MRF
  alias ActivityPub.Queries
  alias ActivityPub.Safety
  # `one/1` is this module's own, which loads rows with their data merged (`one/1`, `many/1`)
  import ActivityPub.Utils, except: [one: 1]
  alias ActivityPub.Utils
  alias ActivityPub.Object.MergePatch

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ap_object" do
    field(:data, :map)

    # a document that carries a proof or a signature, exactly as it arrived, so it still verifies when relayed, forwarded or served; such a row keeps in `data` only what normalisation changed (a merge patch, `ActivityPub.Object.MergePatch`). `nil` for every other row.
    # TEMPORARY until received documents are stored this way: the adapter handover also sets it on the struct to the activity as it reached our inbox, for whatever the adapter passes the activity to (a group's Announce of it). Not written from there, as nothing casts it
    field(:data_received, :map)

    field(:local, :boolean, default: true)
    field(:public, :boolean, default: false)
    # is it an object rather than an activity?
    field(:is_object, :boolean, default: false)

    # the actor whose `Announce` delivered this activity, if any: a group (FEP-1b12), and in principle a relay or a hashtag service, which an adapter tells apart by the actor's type. A property of the DELIVERY rather than of the activity, so never stored, only carried to the adapter, which can then tell a post a group relayed (and so accepted) from one that merely names it
    field(:relayed_by, :string, virtual: true)

    # how this document was vouched for, kept so a copy that is not can be told from one that is, and a better one replace it. `nil` is nothing recorded (every row from before this column). Ranked, lowest first, which is the order of the Postgres enum behind it (a value can be added to it but never removed or reordered): `nil`, then `:unverified` (checked, no usable proof, nothing fetched) and `:unfetchable` (we asked the origin and could not reach it), then the vouched values. Each document has its own: a group's `Announce`, signed by the group, says nothing about the author's `Create` it carries
    field(:authenticated, Ecto.Enum,
      values: [
        :unverified,
        :unfetchable,
        :embedded,
        :http_signature,
        :ld_signature,
        :integrity_proof,
        :fetched
      ]
    )

    # the actor who vouched for this DELIVERY, for the adapter to act on. A property of the delivery rather than of the row, so never stored: a row loaded from the database has `authenticated` from when it was stored and no `signed_by`
    field(:signed_by, :string, virtual: true)

    # TODO: get the table to reference from config? and maybe the type as well
    belongs_to(:pointer, Needle.Pointer, type: Needle.UID)

    # Attention: the below are fake relations, don't try to join them blindly and expect it to work!
    # The foreign keys are embedded in a jsonb field.
    # You probably want to do an inner join and a preload, as in `Queries.with_object/2`
    has_one(:object, Object, on_delete: :nothing, foreign_key: :id)
    has_one(:activity, Object, on_delete: :nothing, foreign_key: :id)

    # to the microsecond, as the column holds: lists are ordered by `inserted_at`, and rows stored within one second keep their order
    timestamps(type: :naive_datetime_usec)
  end

  def get_cached(id: id) when is_binary(id), do: do_get_cached(:id, id)
  # def get_cached(uuid: id) when is_binary(id), do: do_get_cached(:uuid, id)
  def get_cached(ap_id: id) when is_binary(id), do: do_get_cached(:ap_id, id)
  def get_cached(pointer: id) when is_binary(id), do: do_get_cached(:pointer, Utils.uid(id))

  def get_cached(_: %Object{} = o), do: o

  def get_cached(id: %{id: id}) when is_binary(id), do: get_cached(id: id)
  def get_cached(pointer: %{id: id}) when is_binary(id), do: get_cached(pointer: id)
  def get_cached([{_, %{ap_id: ap_id}}]) when is_binary(ap_id), do: get_cached(ap_id: ap_id)
  def get_cached([{_, %{"id" => ap_id}}]) when is_binary(ap_id), do: get_cached(ap_id: ap_id)

  def get_cached([{_, %{data: %{"id" => ap_id}}}]) when is_binary(ap_id),
    do: get_cached(ap_id: ap_id)

  def get_cached(id) when is_binary(id) do
    {kind, _id} = Utils.classify_ref(id)
    get_cached([{kind, id}])
  end

  # def get_cached(opts) do
  #   error(opts, "Unexpected args")
  #   raise "Unexpected args for get_cached"
  # end
  def get_cached(opts), do: get(opts)

  defp do_get_cached(key, val), do: Utils.get_with_cache(&get/1, :ap_object_cache, key, val)

  def get_cached!(opts) do
    with {:ok, object} <- get_cached(opts) do
      object
    else
      e ->
        warn(e, "No such object found")
        nil
    end
  end

  def get_uncached(opts), do: get(opts)

  @doc """
  Batched sibling of `get_cached/1`: resolves many binary refs (ap_id URIs / pointer ULIDs / uuid
  ids) with **one query per kind** for the cache misses (no N+1), populating the cache the same way
  `get_with_cache` does (so later `get_cached` calls hit), and returning results **in input order**.
  Missing refs are dropped unless `opts[:keep_nil]` is true.
  """
  # the generic batching + per-kind query/key/cache-key handling all live in `Utils.list_with_cache`
  # (overridable defaults); for the `ap_object` schema we only need to point it at our `query/1`.
  def list_cached(refs, opts \\ []) when is_list(refs),
    do:
      Utils.list_with_cache(
        refs,
        :ap_object_cache,
        # fetched through `many/1`, so each row's data comes merged
        %{
          query_module: __MODULE__,
          fetch: fn kind, ids -> many(query([{query_key(kind), ids}])) end
        },
        opts
      )

  defp query_key(:pointer), do: :pointer_id
  defp query_key(:ap_id), do: :ap_id
  defp query_key(:id), do: :id
  defp query_key(:username), do: :username

  defp get(id) when is_binary(id) do
    get(pointer: id)
  end

  defp get(id: id) when is_binary(id) and byte_size(id) == 26 do
    # assume pointer ULID/UID
    get(id)
  end

  defp get(id: id) when is_binary(id) do
    get(uuid: id)
  end

  defp get(uuid: id) when is_binary(id), do: one(query(id: id)) |> Arrows.ok_or(:not_found)

  defp get(pointer: id) when is_binary(id) do
    # TODO: support prefixed UUIDs?
    if Utils.is_ulid?(id) do
      one(query(pointer_id: id)) |> Arrows.ok_or(:not_found)
    else
      debug(id, "Expected a valid UID pointer ID, trying as UUID AP object ID instead")
      get(uuid: id)
    end
  end

  defp get(ap_id: ap_id) when is_binary(ap_id),
    do: one(query(ap_id: ap_id)) |> Arrows.ok_or(:not_found)

  defp get(ap_id: ap_id), do: get(ap_id)

  # unused: actors are looked up by username through `ActivityPub.Actor`, which asks the adapter
  # defp get(username: username) when is_binary(username),
  #   do: one(query(username: username)) |> Arrows.ok_or(:not_found)

  defp get(%{data: %{"id" => ap_id}}) when is_binary(ap_id), do: get(ap_id: ap_id)
  defp get(%{"id" => ap_id}) when is_binary(ap_id), do: get(ap_id: ap_id)

  defp get(%{id: id}) when is_binary(id) do
    get(pointer: id)
  end

  defp get(filters) when is_list(filters), do: one(query(filters)) |> Arrows.ok_or(:not_found)

  defp get(nil) do
    raise "Cannot get an AP object without an ID"
  end

  defp get(opts) do
    err(opts, "Unexpected args when attempting to get an AP object")
  end

  @doc """
  Loads the one row `query` finds, or `nil`, as `repo().one/1` does, with its `data` as callers expect it: a signed document is stored as it arrived (`data_received`), with only what normalisation changed in `data`, as a merge patch (`ActivityPub.Object.MergePatch`), so its `data` here is the two merged. Every load of `ap_object` rows goes through this or `many/1`.
  """
  def one(query), do: query |> repo().one() |> with_merged_data()

  @doc "Loads every row `query` finds, as `repo().all/1` does, each with its `data` merged as `one/1` says."
  def many(query), do: query |> repo().all() |> Enum.map(&with_merged_data/1)

  # a row stored as it arrived: the normalised document is the original with the patch applied, made once per load (cheap: the merge walks the patch only), and an object preloaded with it the same way
  defp with_merged_data(%Object{} = object) do
    object
    |> merge_data()
    |> Map.update!(:object, fn
      %Object{} = preloaded -> merge_data(preloaded)
      other -> other
    end)
  end

  defp with_merged_data(other), do: other

  defp merge_data(%Object{data_received: %{} = received, data: patch} = object),
    do: %{object | data: MergePatch.merge_patch(received, patch || %{})}

  defp merge_data(object), do: object

  # Each lookup key has a single-value head (optimal `=`) and a list head (batched `IN`),
  # pattern-matched — `get_cached/1` uses the former, the batched `list_cached/2` uses the latter.
  def query(ap_id: ap_id) when is_binary(ap_id) do
    # lookup by canonical `id` *or* non-canonical `url` (md5-of-url hash index)
    from(object in Object,
      where:
        fragment("(?)->>'id' = ?", object.data, ^ap_id) or
          fragment("md5(?->>'url') = md5(?)", object.data, ^ap_id)
    )
  end

  def query(ap_id: ap_ids) when is_list(ap_ids) do
    # batch form of the above. The input MD5s are precomputed (same lowercase hex Postgres' `md5()`
    # produces), so the comparison still hits the `md5(url)` hash index — only the *input* hash is
    # computed app-side (a SQL `unnest(?::text[])` subquery does not bind the list correctly here).
    url_md5s = Enum.map(ap_ids, &(:crypto.hash(:md5, &1) |> Base.encode16(case: :lower)))

    from(object in Object,
      where:
        fragment("(?)->>'id'", object.data) in ^ap_ids or
          fragment("md5(?->>'url')", object.data) in ^url_md5s
    )
  end

  # lookup by local pointer id (indexed: `ap_object_pointer_id_index`)
  def query(pointer_id: id) when is_binary(id),
    do: from(object in Object, where: object.pointer_id == ^id)

  def query(pointer_id: ids) when is_list(ids),
    do: from(object in Object, where: object.pointer_id in ^ids)

  # lookup by ap_object uuid PK
  def query(id: id) when is_binary(id), do: from(object in Object, where: object.id == ^id)
  def query(id: ids) when is_list(ids), do: from(object in Object, where: object.id in ^ids)

  # unused: only the commented-out `get(username:)` above used it; the list form below (the actor batch loader) and `query(username:, local:)` stay
  # def query(username: username) when is_binary(username),
  #   do:
  #     from(object in Object,
  #       where: fragment("(?)->>'preferredUsername' = ?", object.data, ^username)
  #     )

  def query(username: usernames) when is_list(usernames),
    do:
      from(object in Object,
        where: fragment("(?)->>'preferredUsername'", object.data) in ^usernames
      )

  def query(username: username, local: local?) when is_binary(username) do
    from(object in Object,
      # support for looking up by non-canonical URL
      where:
        object.local == ^local? and
          fragment("(?)->>'preferredUsername' = ?", object.data, ^username)
    )
  end

  def query(opts) do
    err(opts, "Unexpected args when attempting to query an AP object")
  end

  def get_activity_for_object_ap_id(ap_id, verb \\ "Create")

  def get_activity_for_object_ap_id(%{"id" => ap_id}, verb) when is_binary(ap_id),
    do: get_activity_for_object_ap_id(ap_id, verb)

  def get_activity_for_object_ap_id(ap_id, verb) when is_binary(ap_id) do
    Queries.activity_by_object_ap_id(ap_id, verb)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> one()
  end

  def get_activity_for_object_ap_id(ap_id, _verb) do
    error(ap_id, "object has no ID")
    nil
  end

  @doc false
  def insert(params, local?, pointer \\ nil, opts \\ [])
      when is_map(params) and is_boolean(local?) do
    with activity_id <- Ecto.UUID.generate(),
         params <-
           normalize_params(params, activity_id, pointer) |> drop_json_ld_context(local?),
         :ok <- Actor.check_actor_is_active(params["actor"]),
         # set some healthy boundaries
         {:ok, params} <- MRF.filter(params, opts |> Keyword.put(:is_local, local?)),
         # first insert the object if there is one
         {:ok, activity, object} <-
           do_insert_object(params, local?, pointer, opts),
         # how the delivery was vouched for, if it was: each row has its own value
         {authenticated, _signed_by} <- Safety.authentication(opts),
         # then insert the activity (containing only an ID as object)
         {:ok, activity} <-
           (if not is_nil(activity) do
              # when it happened: its own `published`, else its object's
              inserted_at =
                Utils.published_at(
                  activity["published"] || (object && object.data["published"]),
                  Utils.arrival(local?, opts, authenticated)
                )

              if is_nil(object) do
                # insert activity even without an object
                %{
                  id: activity_id,
                  data: activity,
                  local: local?,
                  public: Utils.public?(activity),
                  pointer_id: Utils.uid(pointer),
                  authenticated: authenticated,
                  inserted_at: inserted_at
                }
                |> keep_received(opts)
                |> do_insert()
              else
                # insert activity (with the object ID as object)
                %{
                  id: activity_id,
                  data: activity,
                  local: local?,
                  public: Utils.public?(activity, object),
                  authenticated: authenticated,
                  inserted_at: inserted_at
                }
                |> keep_received(opts)
                |> do_insert()
              end
            else
              {:ok, nil}
            end) do
      # Splice in the child object if we have one.
      activity =
        if not is_nil(activity) and not is_nil(object) do
          Map.put(activity, :object, object)
        else
          activity || object
        end

      debug(activity, "inserted activity in #{repo()}")

      {:ok, activity}
    else
      %Object{} = object ->
        error("error while trying to insert, return the object instead")
        {:ok, object}

      {:reject, e} when is_binary(e) ->
        error(e)
        {:reject, e}

      {:reject, e} ->
        warn(e, "Cannot federate due to local boundaries and filters")
        {:reject, e}

      :ignore ->
        info(params, "Do not federate due to local boundaries and filters")
        # {:ignore, "Do not federate due to local boundaries and filters"}
        :ignore

      {:error,
       %Ecto.Changeset{
         errors: [
           _data____id: {_, [constraint: :unique, constraint_name: "ap_object__data____id_index"]}
         ]
       } = e} ->
        # The id that violated the unique constraint is the one on the FAILING changeset's data
        # (could be the object's or the activity's insert), so read it from there to recover.
        existing_id =
          case Ecto.Changeset.get_field(e, :data) do
            %{"id" => id} when is_binary(id) -> id
            _ -> params["id"]
          end

        if existing_id do
          error(e, "Object or activity already exists: #{existing_id}")
        else
          error(e, "Object or activity already exists (id unknown)")
        end

      error ->
        info(params, "Error while trying to insert these params")
        err(error, "Error while trying to save the object for federation on repo #{repo()}")
        {:error, "Error while trying to save the object for federation"}
    end
  end

  # a received row is stored without its `@context`, the activity's and its embedded object's: nothing reads it from a stored row, and a signed document, where it counts, is kept as received in `data_received`
  defp drop_json_ld_context(params, true = _local?), do: params

  defp drop_json_ld_context(params, _local?) do
    case Map.delete(params, "@context") do
      %{"object" => %{} = object} = params ->
        Map.put(params, "object", Map.delete(object, "@context"))

      params ->
        params
    end
  end

  @doc """
  Inserts a full object if it is contained in an activity.
  """
  defp do_insert_object(
         activity,
         local \\ false,
         pointer \\ nil,
         opts \\ []
       )

  defp do_insert_object(
         %{"object" => %{"type" => type} = object_data} = activity,
         local,
         pointer,
         opts
       )
       when is_in(type, :supported_actor_types) == false and
              (is_in(type, :supported_activity_types) == false or
                 is_in(type, :supported_intransitive_types) == true) do
    # Store the wrapped thing as its own object (rather than leaving it embedded in the activity).
    # We support two uses of some types (e.g. `Question`): as a bare intransitive *activity* (handled by the intransitive clause below), and, like Mastodon does for polls, as a content *object* wrapped in a `Create`/`Update`. When such a type appears as an activity's `object`, treat it as an object here so it becomes retrievable by its ap_id (e.g. for `Object.normalize`/voting).
    # Other (non-intransitive) activity types stay embedded, so we don't split nested activities like `Announce{Create}` or `Undo{Like}`.
    with {:ok, object} <-
           actually_do_insert_object(activity, object_data, local, pointer, opts) do
      # return an activity that contains the ID as object rather than the actual object
      {:ok, Map.put(activity, "object", object.data["id"]), object}
    end
  end

  defp do_insert_object(
         %{"type" => type} = intransitive_object,
         local,
         pointer,
         opts
       )
       when is_in(type, :supported_intransitive_types) == true do
    # we're taking a shortcut by assuming that any object that isn't a known actor or activity type is an object (which seems a bit better than only supporting a known list of object types)

    with {:ok, object} <-
           actually_do_insert_object(nil, intransitive_object, local, pointer, opts) do
      # return an activity that contains the ID as object rather than the actual object
      {:ok, nil, object}
    end
  end

  # there's no object
  defp do_insert_object(activity, _local, _pointer, _), do: {:ok, activity, nil}

  defp actually_do_insert_object(
         activity,
         object_data,
         local,
         pointer,
         opts
       ) do
    upsert? = opts[:upsert] || false

    # we're taking a shortcut by assuming that any object that isn't a known actor or activity type is an object (which seems a bit better than only supporting a known list of object types)
    debug(object_data, "object to '#{if upsert?, do: "update", else: "insert"}'")

    with maybe_existing_object <-
           normalize(object_data, false, pointer) |> debug("maybe_existing_object"),
         # first check if it already exists
         {:ok, object_params} <- prepare_data(object_data, local, pointer, activity),
         authenticated = row_authentication(activity, object_data, opts),
         object_params =
           object_params
           |> Map.put(:authenticated, authenticated)
           |> Map.put(
             :inserted_at,
             Utils.published_at(
               object_data["published"],
               Utils.arrival(local, opts, authenticated)
             )
           ),
         # its original when its own proof or LD signature held; one replacing a copy we hold drops the original of that copy otherwise
         object_params =
           if(match?(%Object{}, maybe_existing_object),
             do: received_or_none(object_params, opts),
             else: object_params |> keep_received(opts) |> keep_signed_original(local)
           ),
         {:ok, object} <-
           maybe_upsert(upsert?, maybe_existing_object, object_params) |> debug("maybe_upserted") do
      # each `maybe_upsert` branch already caches its result (`do_insert` / `update_and_set_cache` /
      # the "already exists" branch), which invalidates any negative `:not_found` entry from the
      # `normalize`/`get_cached` call above — so no extra `set_cache` is needed here.
      {:ok, object}
    end
  end

  # there's no object
  defp actually_do_insert_object(activity, _local, _pointer, _), do: {:ok, activity, nil}

  # The row of an object carries its own value. An object that IS the activity (intransitive) has the activity's. An object inside an activity has the one judged for it (see `object_authentication/1`) or, when none was, the activity's if the object belongs to the activity's actor, else only what its arrival says.
  defp row_authentication(nil, _object_data, opts), do: elem(Safety.authentication(opts), 0)

  defp row_authentication(activity, object_data, opts) do
    cond do
      authenticated = opts[:object_authenticated] ->
        authenticated

      inherits?(activity, object_data) ->
        elem(Safety.authentication(opts), 0)

      true ->
        Safety.by_arrival(opts)
    end
  end

  # an object takes the activity's value when it belongs to the activity's actor, or to nobody
  defp inherits?(activity, object_data) do
    case actor_id_from_data(object_data) do
      nil -> true
      owner -> owner == actor_id_from_data(activity)
    end
  end

  def do_insert(attrs) do
    with {:ok, %Object{data: %{"id" => _}} = object} <-
           attrs
           |> changeset()
           |> repo().insert() do
      # cache the freshly inserted row to invalidate any negative (`:not_found`) cache entry for its
      # ap_id (otherwise an activity with no child object — e.g. a Follow — keeps a stale entry that
      # later `get_cached(ap_id:)`/`get_cached!` calls in the same request resolve to nil/not_found)
      # merged as a load would give it, as a row stored with its original holds only a patch in `data`
      set_cache(merge_data(object))
    end
  end

  @always_in_patch ~w(id type actor object inReplyTo url preferredUsername to cc bto bcc audience)

  # A received document whose own proof or LD signature held is stored as it arrived (`data_received`), so it still verifies when relayed, forwarded or served, with only what normalisation changed in `data`. An object covered only by its activity's proof has none of its own, so keeps no original: it is relayed inside its activity's.
  defp keep_received(
         %{data: %{"id" => id} = normalised, authenticated: authenticated} = attrs,
         opts
       )
       when authenticated in [:integrity_proof, :ld_signature] do
    # `data` stays whole: `changeset/2` makes it the patch over the original (`patch_over_received/1`)
    case received_original(opts[:data_received], id) do
      %{} = original -> Map.put(attrs, :data_received, original)
      nil -> attrs
    end
  end

  defp keep_received(attrs, _opts), do: attrs

  # A new local object is kept with its signed public form: `data_received` is the document as it is served, with our proof, and `changeset/2` makes `data` the patch over it (`patch_over_received/1`), so the data is not stored twice. `bto` and `bcc` stay in `data`, as the public form has neither. Not for one of ours already stored, whose original an edit or a count must renew (plan step 10.2).
  defp keep_signed_original(%{data: %{"id" => _} = data} = attrs, true = _local) do
    case Safety.IntegrityProofs.Outgoing.sign_stored(data) do
      {:ok, signed} -> attrs |> Map.put(:data_received, signed) |> Map.put(:authenticated, :integrity_proof)
      _ -> attrs
    end
  end

  defp keep_signed_original(attrs, _local), do: attrs

  # A local object's signed original is renewed whenever its data changes, in the same write: an edit, a reply count, a poll vote. Otherwise what is served would be the old document, under a proof that still verifies. Signed again from the whole data, and dropped when it cannot be (the actor has no key), so a stale one is never served. An object stored before it had one gets one the next time it changes. Not for an insert (`keep_signed_original/2` did it) nor for a row that is not ours.
  defp renew_signed_original(changeset) do
    with %{__meta__: %{state: :loaded}} <- changeset.data,
         true <- changed?(changeset, :data),
         false <- changed?(changeset, :data_received),
         true <- get_field(changeset, :local) == true,
         true <- get_field(changeset, :is_object) == true,
         %{"id" => _} = data <- get_field(changeset, :data) do
      case Safety.IntegrityProofs.Outgoing.sign_stored(data) do
        {:ok, signed} ->
          changeset
          |> put_change(:data_received, signed)
          |> put_change(:authenticated, :integrity_proof)

        _ ->
          put_change(changeset, :data_received, nil)
      end
    else
      _ -> changeset
    end
  end

  # the document as it reached us when it is this row's, or the object it embeds when that is
  defp received_original(%{"id" => id} = document, id), do: signed(document)
  defp received_original(%{"object" => %{"id" => id} = object}, id), do: signed(object)
  defp received_original(_received, _id), do: nil

  defp signed(document),
    do: if(is_map_key(document, "proof") or is_map_key(document, "signature"), do: document)

  # the fields queries read are kept in the patch even when unchanged (`config :activity_pub, :received_documents, always_in_patch:`), so a query reading `data` alone finds the row; a `url` equal to the `id` is found by the `id` index already
  defp always_in_patch(normalised) do
    keys = ActivityPub.Config.get([:received_documents, :always_in_patch], @always_in_patch)

    if normalised["url"] == normalised["id"], do: List.delete(keys, "url"), else: keys
  end

  # a row we hold keeps the date it was first given (`inserted_at`) when updated
  def maybe_upsert(:update, %ActivityPub.Object{} = existing_object, attrs) do
    debug(existing_object, "Object to update")

    update_changeset(existing_object, Map.delete(attrs, :inserted_at))
    |> debug("to upsert")
    |> update_and_set_cache()
  end

  def maybe_upsert(true, %ActivityPub.Object{} = existing_object, attrs) do
    debug(existing_object, "Object to upsert")
    debug(attrs, "attrs to upsert")

    changeset(existing_object, Map.delete(attrs, :inserted_at))
    |> update_and_set_cache()
  end

  def maybe_upsert(_, %ActivityPub.Object{} = existing_object, _attrs) do
    warn("Will not insert an object that already exists")
    debug(existing_object)
    {:ok, existing_object}
  end

  def maybe_upsert(_, _, attrs) do
    debug("Insert")
    do_insert(attrs)
  end

  @doc """
  Replaces the data and the `authenticated` value of an object we hold with a copy of it. Whether a copy should is for `ActivityPub.Safety.replaces?/3` to say; this only does it.
  """
  # With the options it arrived with, it keeps the copy as it arrived when the copy's own proof or LD signature held (`keep_received/2`), as a first sighting would; otherwise the row keeps no original, the one it had being of a version it no longer holds.
  def replace(%__MODULE__{} = stored, data, authenticated, opts \\ []) when is_map(data) do
    stored
    |> changeset(received_or_none(%{data: data, authenticated: authenticated}, opts))
    |> update_and_set_cache()
  end

  # what a copy that replaces the one we hold keeps: its original, else none
  defp received_or_none(attrs, opts),
    do: attrs |> keep_received(opts) |> Map.put_new(:data_received, nil)

  # Guarded entry point for explicit write sites (`do_insert`, `update_and_set_cache`, `update_state`):
  # honours `cache_enabled?` so cache-off tests don't pollute the global cache. These run in the
  # originating process, where `ProcessTree` can resolve a test's opt-in flag.
  def set_cache(object) do
    if Utils.cache_enabled?(), do: do_set_cache(object), else: {:ok, object}
  end

  # Unguarded write — used directly by `maybe_multi_cache` (alias population from inside the
  # `get_with_cache` fallback, which runs in the Cachex Courier process where `ProcessTree` can't see
  # the flag; the enable decision was already made upstream by `cachex_fetch`).
  def do_set_cache(%{id: id, data: %{"id" => ap_id}, pointer_id: pointer_id} = object) do
    debug(ap_id, "put_cache")

    # Clear JSON cache entries since we're not setting those
    Cachex.del(:ap_object_cache, Utils.ap_cache_key(:json, id))
    Cachex.del(:ap_object_cache, Utils.ap_cache_key(:json, ap_id))

    if pointer_id = pointer_id || Map.get(object.pointer || %{}, :id) do
      Cachex.del(:ap_object_cache, Utils.ap_cache_key(:json, pointer_id))
    end

    # Set object cache (these will overwrite any existing entries)
    # TODO: store in cache only once, and only IDs for the others
    Cachex.put(:ap_object_cache, Utils.ap_cache_key(:id, id), object)
    Cachex.put(:ap_object_cache, Utils.ap_cache_key(:ap_id, ap_id), object)

    if pointer_id = pointer_id || Map.get(object.pointer || %{}, :id) do
      Cachex.put(:ap_object_cache, Utils.ap_cache_key(:pointer, pointer_id), object)
    end

    {:ok, object}
  end

  def invalidate_cache(%{
        id: id,
        data: %{"id" => ap_id},
        pointer_id: pointer_id,
        pointer: pointer
      }) do
    debug(ap_id, "invalidate_cache")

    Cachex.del(:ap_object_cache, Utils.ap_cache_key(:id, id))
    Cachex.del(:ap_object_cache, Utils.ap_cache_key(:ap_id, ap_id))

    Cachex.del(:ap_object_cache, Utils.ap_cache_key(:json, id))
    Cachex.del(:ap_object_cache, Utils.ap_cache_key(:json, ap_id))

    if pointer_id = pointer_id || Map.get(pointer || %{}, :id) do
      Cachex.del(:ap_object_cache, Utils.ap_cache_key(:pointer, pointer_id))
      Cachex.del(:ap_object_cache, Utils.ap_cache_key(:json, pointer_id))
    end

    :ok
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
  end

  def changeset(object, attrs) do
    object
    |> cast(attrs, [
      :id,
      :data,
      :data_received,
      :local,
      :public,
      :pointer_id,
      :is_object,
      :authenticated,
      # when what the row holds happened (`Utils.published_at/2`); left out, it is when it is stored
      :inserted_at
    ])
    |> common_changeset()
  end

  @doc """
  Sets how a delivery was vouched for on a struct, from the options its handling carried (see `ActivityPub.Safety.authentication/1`). For the adapter, which is handed the struct; `signed_by` is not stored.
  """
  def put_authentication_meta(%__MODULE__{} = object, opts) when is_list(opts) do
    {authenticated, signed_by} = Safety.authentication(opts)
    %{object | authenticated: authenticated, signed_by: signed_by}
  end

  @doc "Like `put_authentication_meta/2`, for the object a `Create` carries."
  def put_object_authentication_meta(%__MODULE__{} = object, opts) when is_list(opts) do
    {authenticated, signed_by} = Safety.object_authentication(opts)
    %{object | authenticated: authenticated, signed_by: signed_by}
  end

  def update_changeset(object, attrs) do
    # Merge the incoming (possibly partial, e.g. a C2S Update) object data ONTO the existing data,
    # so fields not present in the update payload are preserved (e.g. `replies`, `attributedTo`,
    # `published`). Without this a partial Update would replace `data` wholesale. See #1930.
    new_data = Map.get(attrs, :data) || Map.get(attrs, "data") || %{}
    merged = Map.merge(object.data || %{}, new_data)

    # the original the row keeps from now on, when one is given (`nil` drops it, see `keep_received/2`)
    original = Map.take(attrs, [:data_received])

    object
    |> cast(Map.put(original, :data, merged), [:data, :data_received])
    |> common_changeset()
  end

  # A row with an original (`data_received`) holds in `data` only what changed from it, normalisation's and our own (a reply count, poll votes), with the fields queries read (`always_in_patch/1`). Callers write `data` whole and it is made a patch here, so no write leaves a whole `data` beside an original, which a load would merge with it, bringing back what was taken out.
  defp patch_over_received(changeset) do
    changed? = changed?(changeset, :data) or changed?(changeset, :data_received)

    case {changed?, get_field(changeset, :data_received), get_field(changeset, :data)} do
      {true, %{} = original, %{} = data} ->
        put_change(
          changeset,
          :data,
          MergePatch.create_merge_patch(original, data, always_in_patch(data))
        )

      _ ->
        changeset
    end
  end

  def common_changeset(object) do
    object
    |> renew_signed_original()
    |> patch_over_received()
    |> validate_required(:data)
    |> unique_constraint(:pointer_id)
    |> unique_constraint(:_data____id, match: :exact)
  end

  def update_existing(object_id, attrs) when is_binary(object_id) do
    case get_cached(object_id) do
      {:ok, object} ->
        do_update_existing(object, attrs)

      _e ->
        error(object_id, "Could not find the object to update")
    end
  end

  def update_existing(opts, attrs) when is_list(opts) do
    case get_cached(opts) do
      {:ok, object} ->
        do_update_existing(object, attrs)

      _e ->
        error(opts, "Could not find the object to update")
    end
  end

  def do_update_existing(%ActivityPub.Object{} = object, attrs) do
    debug(attrs)

    object
    |> debug("update")
    |> change(attrs)
    |> renew_signed_original()
    |> patch_over_received()
    |> debug("cs")
    |> update_and_set_cache()
  end

  def update_and_set_cache(changeset) do
    with {:ok, object} <- repo().update(changeset) do
      # merged as a load would give it (see `do_insert/1`)
      set_cache(merge_data(object))
    else
      e -> error(e, "Could not update the AP object")
    end
  rescue
    e in Ecto.ConstraintError ->
      error(e, "Could not update the AP object")
  end

  @doc """
  Updates a follow activity's state (for locked accounts).
  """
  def update_state(
        %Object{data: %{"actor" => actor, "object" => object}} = activity,
        type,
        state
      ) do
    Queries.by_type(type)
    |> Queries.by_actor(actor)
    |> Queries.by_object_id(object)
    # |> where(fragment("data->>'state' = 'pending'") or fragment("data->>'state' = 'accept'"))
    |> update(set: [data: fragment("jsonb_set(data, '{state}', ?)", ^state)])
    |> repo().update_all([])

    with {:ok, activity} <- get(id: activity.id) do
      set_cache(activity)
      |> debug()

      {:ok, activity}
    end
  end

  # for debugging
  @doc false
  def all() do
    many(from(object in Object))
  end

  def all(filters) do
    many(query(filters))
  end

  @doc """
  Prepares a struct to be inserted into the objects table
  """
  def prepare_data(data, local \\ false, pointer \\ nil, associated_activity \\ nil) do
    data =
      %{}
      |> Map.put(:data, data)
      |> Map.put(:local, local)
      |> Map.put(:public, Utils.public?(associated_activity, data))
      |> Map.put(:pointer_id, pointer)
      |> Map.put(:is_object, associated_activity != nil)

    {:ok, data}
  end

  defp lazy_put_activity_defaults(map, activity_id, pointer) do
    map =
      map
      # |> debug()
      |> Map.put_new_lazy("id", fn -> map["url"] || object_url(activity_id) end)
      |> Map.put_new_lazy("published", &Utils.make_date/0)

    # |> Map.put_new_lazy("context", &Utils.generate_id("contexts"))

    if is_map(map["object"]) do
      object =
        map["object"]
        |> lazy_put_object_defaults(map["id"], pointer, map["context"])
        |> normalize_actors()

      %{map | "object" => object}
    else
      map
    end
    |> debug
  end

  defp lazy_put_object_defaults(%{data: data}, activity_id, pointer, context),
    do: lazy_put_object_defaults(data, activity_id, pointer, context)

  defp lazy_put_object_defaults(map, _activity_id, pointer, context) do
    map
    |> Map.put_new_lazy("id", fn ->
      map["url"] ||
        object_url(pointer)
    end)
    |> Map.put_new_lazy("published", &Utils.make_date/0)
    # the activity's `context` only fills in for an object with none: a received activity keeps its own, which may differ from its object's
    |> Utils.maybe_put("context", map["context"] || context)
    |> debug
  end

  def normalize(_, fetch_remote? \\ true, pointer \\ nil)

  def normalize(object, opts, pointer) when is_list(opts),
    do:
      normalize(
        object,
        opts[:fetch] || opts[:fetch_remote?] || !opts[:already_fetched],
        pointer || opts[:pointer]
      )

  def normalize({:ok, object}, fetch_remote?, pointer),
    do: normalize(object, fetch_remote?, pointer)

  def normalize(%{__struct__: Object, data: %{"object" => object}}, fetch_remote?, pointer),
    do: normalize(object, fetch_remote?, pointer)

  def normalize(%{__struct__: Object} = object, _, _), do: object

  def normalize(%{"id" => ap_id} = _object, true, pointer)
      when is_binary(ap_id) do
    # if(length(Map.keys(object))==1) do # we only have an ID
    normalize(ap_id, true, pointer)
    # else
    #   %{data: object}
    # end
  end

  def normalize(ap_id, fetch_remote?, pointer) when is_binary(ap_id) and is_binary(pointer),
    do:
      get_cached!(pointer: pointer) || get_cached!(ap_id: ap_id) ||
        maybe_fetch(ap_id, fetch_remote?) || unnormalized(ap_id, "Could not find object")

  def normalize(_ap_id, _fetch_remote?, pointer) when is_binary(pointer),
    do: get_cached!(pointer: pointer) || unnormalized(pointer, "Could not find object by pointer")

  def normalize(ap_id, fetch_remote?, _) when is_binary(ap_id),
    do:
      get_cached!(ap_id: ap_id) || maybe_fetch(ap_id, fetch_remote?) ||
        unnormalized(ap_id, "Could not find object by ap id")

  def normalize(%{"id" => ap_id} = _data, false, pointer)
      when is_binary(ap_id) do
    normalize(ap_id, false, pointer)
  end

  def normalize(ap_id, _, _) do
    unnormalized(ap_id, "Invalid input for normalize object")
  end

  defp unnormalized(obj, msg) do
    debug(obj, msg)
    nil
  end

  defp maybe_fetch(ap_id, true) when is_binary(ap_id) do
    with {:ok, object} <- Fetcher.fetch_object_from_id(ap_id, triggered_by: "Object.normalize") do
      object
    else
      e ->
        error(e)
        nil
    end
  end

  defp maybe_fetch(_, _), do: nil

  def get_ap_id(%{"id" => id} = _), do: id
  def get_ap_id(%{data: data}), do: get_ap_id(data)
  def get_ap_id(id) when is_binary(id), do: id
  def get_ap_id(_), do: nil

  defp get_ap_ids(ids) do
    ids
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&get_ap_id/1)
  end

  def actor_from_data(%{"actor" => actor}) when not is_nil(actor) and actor != [],
    do: actor_from_data(actor)

  def actor_from_data(%{"attributedTo" => actor}) when not is_nil(actor) and actor != [],
    do: actor_from_data(actor)

  def actor_from_data(%{"id" => _, "type" => type} = actor)
      when is_in(type, :supported_actor_types),
      do: actor

  # A Create's object may carry the authorship its activity omitted. Only for Create: the actor of an Announce/Update/Delete is the announcer/editor/deleter, never the wrapped object's author.
  def actor_from_data(%{"type" => "Create", "object" => object}) when is_map(object),
    do: actor_from_data(object)

  def actor_from_data(actors) when is_list(actors) do
    Enum.map(actors, &actor_from_data/1)
    |> Enum.reject(&is_nil/1)
    |> List.first()

    # ignores any secondary actors
  end

  def actor_from_data(%{data: data}), do: actor_from_data(data)

  def actor_from_data(e) when is_binary(e) do
    debug(e, "We got a string, just assume that's the actor...")
    e
  end

  # nil rather than an error tuple: every caller treats the result as an actor reference, and a
  # document with `"actor" => {:error, …}` in it is no longer serialisable (nor is it caught by any
  # `is_nil`/`is_binary` guard downstream)
  def actor_from_data(e) do
    error(e, "No actor found")
    nil
  end

  def actor_id_from_data(id) when is_binary(id) do
    id
  end

  def actor_id_from_data(data) do
    case actor_from_data(data) do
      %{"id" => id} ->
        id

      id when is_binary(id) ->
        id

      e ->
        warn(e, "No actor ID found")
        nil
    end
  end

  def normalize_params(params, activity_id \\ nil, pointer \\ nil)

  def normalize_params(%{data: data} = _params, activity_id, pointer) do
    normalize_params(data, activity_id, pointer)
  end

  def normalize_params(params, activity_id, pointer) do
    normalize_actors(params)
    |> lazy_put_activity_defaults(activity_id, pointer)
  end

  def normalize_actors(%{data: data}), do: normalize_actors(data)

  def normalize_actors(params) do
    # Some implementations include actors as URIs, others inline the entire actor object, this function figures out what the URIs are based on what we have.
    params
    |> Utils.maybe_put("actor", get_ap_id(params["actor"]))
    |> normalise_tos()

    # |> Utils.maybe_put("to", get_ap_ids(params["to"]))
    # |> Utils.maybe_put("bto", get_ap_ids(params["bto"]))
    # |> Utils.maybe_put("cc", get_ap_ids(params["cc"]))
    # |> Utils.maybe_put("bcc", get_ap_ids(params["bcc"]))
    # |> Utils.maybe_put("audience", get_ap_ids(params["audience"]))
  end

  def normalise_tos(object) do
    object
    |> normalise_to()
    |> normalise_addressing_field("cc")
    |> normalise_addressing_field("bto")
    |> normalise_addressing_field("bcc")
  end

  defp normalise_to(map) do
    extra = if Utils.public?(map), do: [ActivityPub.Config.public_uri()], else: []
    debug(extra)
    normalise_addressing_field(map, "to", extra)
  end

  defp normalise_addressing_field(map, field, extra \\ []) do
    addrs = Map.get(map, field)

    cond do
      is_list(addrs) ->
        Enum.filter(addrs, &is_binary/1)

      is_binary(addrs) ->
        [addrs]

      true ->
        []
    end
    |> Enum.reject(&(&1 in ["as:Public", "Public"]))
    |> Kernel.++(extra)
    |> Enum.uniq()
    |> Utils.maybe_put(map, field, ...)
  end

  def make_tombstone(
        %{data: %{"id" => id, "type" => type} = _data},
        deleted \\ DateTime.utc_now()
      ) do
    %{
      "id" => id,
      "formerType" => type,
      "deleted" => deleted,
      "type" => "Tombstone"
    }
  end

  def is_deleted?(%{data: data}), do: is_deleted?(data)

  def is_deleted?(data) do
    case data do
      %{"suspended" => true} -> true
      %{"type" => "Tombstone"} -> true
      %{"type" => "Delete"} -> true
      %{"object" => %{"type" => "Tombstone"}} -> true
      nil -> true
      _ -> false
    end
  end

  def swap_object_with_tombstone(object) do
    tombstone = make_tombstone(object)

    object
    |> changeset(%{data: tombstone})
    |> repo().update()
  end

  def delete(%{} = object) do
    with {:ok, tombstone} <- swap_object_with_tombstone(object),
         :ok <- invalidate_cache(object) do
      {:ok, tombstone}
    end
  end

  # Deleting is idempotent, so a row that another process already removed counts as done. Raising
  # instead abandons whatever the caller still had to do: `unannounce/2` and `unlike/2` delete here
  # and only then tell the adapter to remove the boost or like, which would leave the two sides
  # disagreeing about an undo that the sender considers delivered.
  def hard_delete(%Object{} = object) do
    with :ok <- invalidate_cache(object) do
      case repo().delete(object, stale_error_field: :id, stale_error_message: "already deleted") do
        {:error, %Ecto.Changeset{errors: [id: {"already deleted", _}]}} ->
          info(object.id, "Object was already deleted, nothing left to do")
          {:ok, object}

        other ->
          other
      end
    end
  end

  # TODO: move queries in Queries module

  def get_outbox_for_actor(ap_id, page \\ 1, opts \\ [])

  def get_outbox_for_actor(%{ap_id: ap_id}, page, opts),
    do: get_outbox_for_actor(ap_id, page, opts)

  def get_outbox_for_actor(%{"id" => ap_id}, page, opts),
    do: get_outbox_for_actor(ap_id, page, opts)

  def get_outbox_for_actor(ap_id, page, opts) when is_binary(ap_id) do
    outbox_query(ap_id)
    |> do_list_page(page, opts)
  end

  # ONE definition of what an outbox holds, so a page and its count cannot disagree. They did while
  # the `where` clauses were written out in both places.
  defp outbox_query(ap_id) do
    published_public_activities()
    |> Queries.by_actor(ap_id)
  end

  # not one of our scheduled posts before its time: its `inserted_at` is its `published` (`Utils.published_at/2`)
  defp published_public_activities do
    now = NaiveDateTime.utc_now()

    from(object in Object,
      where:
        object.public == true and
          object.is_object != true and
          object.inserted_at <= ^now
    )
  end

  @doc """
  How many items an actor's outbox holds.

  `totalItems` is otherwise the length of the page just fetched, which reports 10 however much is there, and a truthful count is also what makes a `last` page number computable. Cached briefly, see `ActivityPub.Utils.cached_page_count/2`.
  """
  def count_outbox_for_actor(%{ap_id: ap_id}), do: count_outbox_for_actor(ap_id)

  def count_outbox_for_actor(ap_id) when is_binary(ap_id),
    do: cached_query_count("outbox_count:#{ap_id}", fn -> outbox_query(ap_id) end)

  def count_outbox_for_actor(_), do: 0

  @doc "How many activities the instance's shared outbox holds — see `count_outbox_for_actor/1`."
  def count_outbox_for_instance,
    do: cached_query_count("instance_outbox_count", &instance_outbox_query/0)

  @doc "How many activities the instance's shared inbox holds — see `count_outbox_for_actor/1`."
  def count_inbox_for_instance,
    do: cached_query_count("instance_inbox_count", &instance_inbox_query/0)

  @doc "How many activities an actor's inbox holds — see `count_outbox_for_actor/1`."
  def count_inbox_for_actor(actor_or_ap_id, opts \\ [])

  def count_inbox_for_actor(%{ap_id: ap_id}, opts), do: count_inbox_for_actor(ap_id, opts)
  def count_inbox_for_actor(%{"id" => ap_id}, opts), do: count_inbox_for_actor(ap_id, opts)

  def count_inbox_for_actor(ap_id, opts) when is_binary(ap_id) do
    cached_query_count(
      "inbox_count:#{ap_id}:#{:erlang.phash2({opts[:activity_types], opts[:object_types]})}",
      fn -> inbox_query(ap_id, opts) end
    )
  end

  def count_inbox_for_actor(_, _), do: 0

  @doc "How many MLS messages an actor holds — see `count_inbox_for_actor/2`."
  def count_mls_messages_for_actor(actor_or_ap_id),
    do: count_inbox_for_actor(actor_or_ap_id, mls_message_filters())

  defp cached_query_count(key, query_fun),
    do: ActivityPub.Utils.cached_page_count(key, fn -> repo().aggregate(query_fun.(), :count) end)

  def get_outbox_for_instance(page \\ 1, opts \\ []) do
    instance_outbox_query()
    |> do_list_page(page, opts)
  end

  defp instance_outbox_query do
    from(object in published_public_activities(), where: object.local == true)
  end

  def get_inbox_for_instance(page \\ 1, opts \\ []) do
    instance_inbox_query()
    |> do_list_page(page, opts)
  end

  defp instance_inbox_query do
    from(object in published_public_activities(), where: object.local == false)
  end

  def get_inbox_for_actor(ap_id, page \\ 1, opts \\ [])
  def get_inbox_for_actor(%{ap_id: ap_id}, page, opts), do: get_inbox_for_actor(ap_id, page, opts)

  def get_inbox_for_actor(%{"id" => ap_id}, page, opts),
    do: get_inbox_for_actor(ap_id, page, opts)

  def get_inbox_for_actor(ap_id, page, opts) when is_binary(ap_id) do
    inbox_query(ap_id, opts)
    |> do_list_page(page, opts)
  end

  defp inbox_query(ap_id, opts) do
    from(object in Object,
      where: object.is_object != true,
      # match all addressing fields, including blind ones — MLS messages often address recipients via
      # `bto`/`bcc` to keep the recipient list private (consistent with `all_activity_recipients`)
      where: fragment("? \\? ?", recipients(object.data), ^ap_id)
    )
    |> maybe_filter_types(opts[:activity_types], opts[:object_types])
    |> maybe_published_filter(opts)
  end

  def get_inbox_for_actor(_, _page, _opts), do: []

  @doc """
  An actor's `mls:messages` collection (per the MLS-over-ActivityPub spec): their inbox filtered to
  MLS-related types, so an E2EE client can skip scanning the whole inbox.

  Reuses `get_inbox_for_actor/3` (same addressing/ordering/paging seam). Differs in that it:
  - filters to the configured MLS types — `:mls_message_object_types` matched against the wrapped
    object's type (application messages are a `PrivateMessage`/`PublicMessage` object wrapped in a
    `Create`), and `:mls_message_activity_types` against the activity's own type;
  - skips the draft/scheduled `published <= now()` gate (`only_published: false`) — gating on
    `published` could hide an in-order message and break MLS group/ratchet state.
  """
  def get_mls_messages_for_actor(actor_or_ap_id, page \\ 1, opts \\ []) do
    get_inbox_for_actor(
      actor_or_ap_id,
      page,
      Keyword.merge(mls_message_filters(), opts)
    )
  end

  # Shared by the page and its count, so `totalItems` counts the same messages the page lists.
  defp mls_message_filters do
    [
      activity_types: ActivityPub.Config.get(:mls_message_activity_types, []),
      object_types:
        ActivityPub.Config.get(:mls_message_object_types, ["PrivateMessage", "PublicMessage"]),
      only_published: false
    ]
  end

  # Restrict the inbox to activities of the given `activity_types`, and/or whose wrapped object
  # (embedded or referenced/joined) is of the given `object_types`. Empty/nil lists are no-ops; the
  # object join is only added when filtering by object type.
  defp maybe_filter_types(query, activity_types, object_types) do
    activity_types = List.wrap(activity_types)
    object_types = List.wrap(object_types)

    cond do
      activity_types == [] and object_types == [] ->
        query

      object_types == [] ->
        where(query, [a], fragment("(?)->>'type' = ANY(?)", a.data, ^activity_types))

      true ->
        query
        |> Queries.with_joined_object(:left)
        |> where(
          [a, object: o],
          fragment("(?)->'object'->>'type' = ANY(?)", a.data, ^object_types) or
            fragment("(?)->>'type' = ANY(?)", o.data, ^object_types)
        )
    end
  end

  # The inbox hides future-scheduled/draft posts; MLS messages opt out via `only_published: false`.
  # By `inserted_at`, which is when it happened (`Utils.published_at/2`): only our own scheduled posts are in the future; a remote future `published` was given the time it was stored.
  defp maybe_published_filter(query, opts) do
    if Keyword.get(opts, :only_published, true),
      do:
        (
          now = NaiveDateTime.utc_now()
          where(query, [o], o.inserted_at <= ^now)
        ),
      else: query
  end

  # def get_inbox(instance_or_actor_url, page) do
  #   instance_or_actor_filter = "#{instance_or_actor_url}%"

  #   from(object in Object,
  #     where:
  #       fragment("(?)->>'actor' ilike ?", object.data, ^instance_or_actor_filter) and
  #         object.local != true and
  #         object.public == true and
  #         object.is_object != true
  #   )
  #   |> do_list_page(page)
  # end

  defp do_list_page(query, page, opts \\ []) do
    # a caller can ask for a bigger page: a GROUP outbox is served as one capped collection with its items inline, because Lemmy reads those and never follows pages (see `ObjectView`)
    limit = opts[:limit] || 10
    offset = (page - 1) * limit

    load_object = opts[:load_object] || :cache

    query
    |> Queries.ordered()
    |> limit(^limit)
    |> offset(^offset)
    |> Queries.with_object(:left, load_object)
    |> many()
    |> maybe_load_objects_from_cache(load_object)
  end

  # `load_object: :cache` skips the SQL join (see `Queries.with_object/3`); resolve each activity's
  # object from cache in one batched `list_cached`, then stitch onto `:object`.
  defp maybe_load_objects_from_cache(activities, :cache) do
    by_ap_id =
      activities
      |> Enum.map(&Utils.object_ap_id_of/1)
      |> Enum.reject(&is_nil/1)
      |> list_cached()
      |> Map.new(&{&1.data["id"], &1})

    Enum.map(activities, &%{&1 | object: by_ap_id[Utils.object_ap_id_of(&1)]})
  end

  defp maybe_load_objects_from_cache(activities, _), do: activities

  def object_url(%{pointer_id: id}) when is_binary(id), do: object_url(id)
  def object_url(%{id: id}) when is_binary(id), do: object_url(id)
  def object_url(%{pointer: %{id: id}}) when is_binary(id), do: object_url(id)
  def object_url(%{pointer: id}) when is_binary(id), do: object_url(id)

  def object_url(id) when is_binary(id) do
    if Utils.is_uid?(id) do
      Utils.ap_base_url() <> "/objects/" <> id
    else
      Utils.ap_base_url() <> "/actors/" <> id
    end
  end

  def object_url(_), do: Utils.generate_object_id()

  @doc """
  A second id for the SAME stored announce, under which it is served in its FEP-1b12 shape (wrapping the activity) rather than its compat shape (wrapping the object).

  A group relay goes out as both shapes, since Lemmy and the threadiverse only accept the wrapped one while the Pleroma, Misskey and GoToSocial family only accept the other. Each copy needs its own id, or two different documents claim to be the same activity; but neither needs its own row, because the id decides which shape we render for a single stored activity.

  Derived from the canonical id rather than minted separately, so the pair stays recognisably one thing, and so serving it is a path match rather than a lookup table.
  """
  def activity_object_url(canonical_ap_id) when is_binary(canonical_ap_id),
    do: String.replace(canonical_ap_id, "/objects/", "/activity/")

  def activity_object_url(_), do: nil

  def get_follow_activity(follow_object, followed) do
    with object_id when not is_nil(object_id) <- get_ap_id(follow_object),
         {:ok, activity} <- get_cached(ap_id: object_id) do
      {:ok, activity}
    else
      # Can't find the activity. This might be a Mastodon 2.3 "Accept"
      nil ->
        with %{} = activity <- fetch_latest_activity(follow_object["actor"], followed, "Follow") do
          {:ok, activity}
        end

      e ->
        error(e, "Could not find a matching follow")
    end
  end

  def fetch_latest_activity(actor, object, verb \\ "Follow")

  def fetch_latest_activity(%{data: %{"id" => actor}}, object, verb),
    do: fetch_latest_activity(actor, object, verb)

  def fetch_latest_activity(
        actor,
        %{
          data: %{"id" => object}
        },
        verb
      ),
      do: fetch_latest_activity(actor, object, verb)

  def fetch_latest_activity(actor, object, verb)
      when is_binary(actor) and is_binary(object) and is_binary(verb) do
    from(activity in Object)
    |> Queries.by_actor(actor)
    |> Queries.by_object(object)
    |> Queries.by_type(verb)
    |> Queries.ordered()
    |> limit(1)
    |> one()
  end

  #### Like-related helpers
  @doc """
  Returns an existing like if a user already liked an object
  """
  def get_existing_like(actor, object_id) do
    query =
      from(
        object in Object,
        # this is to use the index
        where: object_id_of(object.data) == ^object_id
      )
      |> Queries.by_type("Like")
      |> Queries.by_actor(actor)
      |> debug()

    one(query)
  end

  @doc "The `Flag`s `actor` sent about `object_id`. A report names what it is about in a list (an account and statuses, Mastodon's shape) or as one id (Lemmy's), so both are matched."
  def get_existing_flags(actor, object_id) do
    from(
      object in Object,
      where:
        fragment("(?)->'object' @> to_jsonb(ARRAY[?]::text[])", object.data, ^object_id) or
          fragment("(?)->>'object' = ?", object.data, ^object_id)
    )
    |> Queries.by_type("Flag")
    |> Queries.by_actor(actor)
    |> many()
  end

  #### Announce-related helpers

  @doc """
  Retruns an existing announce activity if the notice has already been announced
  """
  def get_existing_announce(actor, %{data: %{"id" => id}}) do
    query =
      from(
        object in Object,
        # this is to use the index
        where: object_id_of(object.data) == ^id
      )
      |> Queries.by_type("Announce")
      |> Queries.by_actor(actor)
      # the latest: a reboost leaves more than one
      |> Queries.ordered()
      |> limit(1)

    one(query)
  end

  #### Block-related helpers
  def fetch_latest_block(%{data: %{"id" => blocker_id}}, %{
        data: %{"id" => blocked_id}
      }) do
    query =
      from(
        activity in Object,
        where: object_id_of(activity.data) == ^blocked_id,
        order_by: [fragment("? desc nulls last", activity.inserted_at)],
        limit: 1
      )
      |> Queries.by_type("Block")
      |> Queries.by_actor(blocker_id)

    one(query)
  end

  def hashtags(%{"tag" => tags}) when is_list(tags) and tags != [] do
    tags
    |> Enum.filter(fn
      %{"type" => "Hashtag"} = data -> Map.has_key?(data, "name")
      plain_text when is_binary(plain_text) -> true
      _ -> false
    end)
    |> Enum.map(fn
      %{"name" => "#" <> hashtag} -> hashtag
      %{"name" => hashtag} -> hashtag
      "#" <> hashtag -> hashtag
      hashtag when is_binary(hashtag) -> hashtag
    end)
    |> Enum.uniq()
    # Note: "" elements (plain text) might occur in `data.tag` for incoming objects
    |> Enum.filter(&(&1 not in [nil, ""]))
  end

  def hashtags(%{data: data}), do: hashtags(data)
  def hashtags(_), do: []

  def replies_ids(object, limit, opts \\ []),
    do:
      object
      |> Queries.replies(opts)
      |> select([o], fragment("?->>'id'", o.data))
      |> limit(^limit)
      |> repo().all()

  # unused
  # def self_replies_ids(object, limit),
  #   do: replies_ids(object, limit, self_only: true)

  @doc "The posts up an object's reply chain (its `inReplyTo`, then that one's, and so on), nearest first, as far as we hold them. Nothing is fetched, and a chain that loops back ends there."
  def held_ancestors(%Object{data: data}), do: held_ancestors(data)

  def held_ancestors(%{} = data),
    do: held_ancestors(get_ap_id(data["inReplyTo"]), MapSet.new([data["id"]]), [])

  defp held_ancestors(parent_id, seen, ancestors) when is_binary(parent_id) do
    with false <- MapSet.member?(seen, parent_id),
         {:ok, %Object{data: data} = parent} <- get_cached(ap_id: parent_id) do
      held_ancestors(get_ap_id(data["inReplyTo"]), MapSet.put(seen, parent_id), [
        parent | ancestors
      ])
    else
      _ -> Enum.reverse(ancestors)
    end
  end

  defp held_ancestors(_parent_id, _seen, ancestors), do: Enum.reverse(ancestors)

  def apply_to_object_and_history(object, fun) do
    with history <- object["formerRepresentations"],
         object <- Map.drop(object, ["formerRepresentations"]),
         {_, {:ok, object}} <- {:main_body, fun.(object)},
         {_, {:ok, history}} <- {:history_items, for_each_history_item(history, object, fun)} do
      object =
        if history do
          Map.put(object, "formerRepresentations", history)
        else
          object
        end

      {:ok, object}
    else
      {:main_body, e} -> e
      {:history_items, e} -> e
    end
  end

  defp for_each_history_item(%{"orderedItems" => items} = history, _object, fun) do
    new_items =
      Enum.map(items, fun)
      |> Enum.reduce_while(
        {:ok, []},
        fn
          {:ok, item}, {:ok, acc} -> {:cont, {:ok, acc ++ [item]}}
          e, _acc -> {:halt, e}
        end
      )

    case new_items do
      {:ok, items} -> {:ok, Map.put(history, "orderedItems", items)}
      e -> e
    end
  end

  defp for_each_history_item(history, _, _) do
    {:ok, history}
  end
end
