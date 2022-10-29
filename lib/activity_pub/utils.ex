defmodule ActivityPub.Utils do
  @moduledoc """
  Misc functions used for federation
  """
  alias ActivityPub.Actor
  alias ActivityPub.Object
  alias Ecto.UUID
  import ActivityPub.Common
  import Untangle
  import Ecto.Query

  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  # TODO: make configurable
  @supported_actor_types Application.compile_env(:activity_pub, :instance)[
                           :supported_actor_types
                         ] ||
                           [
                             "Person",
                             "Application",
                             "Service",
                             "Organization",
                             "Group"
                           ]
  @supported_activity_types Application.compile_env(:activity_pub, :instance)[
                              :supported_activity_types
                            ] ||
                              [
                                "Create",
                                "Update",
                                "Delete",
                                "Follow",
                                "Accept",
                                "Reject",
                                "Add",
                                "Remove",
                                "Like",
                                "Announce",
                                "Undo",
                                "Arrive",
                                "Block",
                                "Flag",
                                "Dislike",
                                "Ignore",
                                "Invite",
                                "Join",
                                "Leave",
                                "Listen",
                                "Move",
                                "Offer",
                                "Question",
                                "Read",
                                "TentativeReject",
                                "TentativeAccept",
                                "Travel",
                                "View"
                              ]

  # @supported_object_types Application.compile_env(:activity_pub, :instance)[:supported_object_types] || ["Article", "Note", "Video", "Page", "Question", "Answer", "Document", "ChatMessage"] # Note: unused since we want to support anything

  def supported_actor_types, do: @supported_actor_types
  def supported_activity_types, do: @supported_activity_types
  # def supported_object_types, do: @supported_object_types


  defp make_date do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  def generate_context_id, do: generate_id("contexts")

  def generate_object_id, do: generate_id("objects")

  def generate_id(type), do: ap_base_url() <> "/#{type}/#{UUID.generate()}"

  def actor_url(%{preferred_username: username}), do: actor_url(username)

  def actor_url(username) when is_binary(username),
    do: ap_base_url() <> "/actors/" <> username

  def object_url(%{pointer_id: id}) when is_binary(id), do: object_url(id)
  def object_url(%{id: id}) when is_binary(id), do: object_url(id)
  def object_url(id) when is_binary(id), do: ap_base_url() <> "/objects/" <> id

  defp ap_base_url() do
    ActivityPubWeb.base_url() <> System.get_env("AP_BASE_PATH", "/pub")
  end

  def make_json_ld_header do
    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        Map.merge(
          %{
            "@language" => Application.get_env(:activity_pub, :default_language, "und")
          },
          Application.get_env(:activity_pub, :json_contexts, %{
            "Hashtag" => "as:Hashtag"
          })
        )
      ]
    }
  end

  #### Like-related helpers
  @doc """
  Returns an existing like if a user already liked an object
  """
  def get_existing_like(actor, %{data: %{"id" => id}}) do
    query =
      from(
        object in Object,
        where: fragment("(?)->>'actor' = ?", object.data, ^actor),
        # this is to use the index
        where:
          fragment(
            "coalesce((?)->'object'->>'id', (?)->>'object') = ?",
            object.data,
            object.data,
            ^id
          ),
        where: fragment("(?)->>'type' = 'Like'", object.data)
      )

    repo().one(query)
  end

  def make_like_data(
        %{data: %{"id" => ap_id}} = actor,
        %{data: %{"id" => id}} = object,
        activity_id
      ) do
    object_actor_id = ActivityPub.Utils.actor_from_data(object.data)
    {:ok, object_actor} = Actor.get_cached(ap_id: object_actor_id)

    to =
      if public?(object.data) do
        [actor.data["followers"], object.data["actor"]]
      else
        [object.data["actor"]]
      end

    cc =
      ((object.data["to"] || []) ++ (object.data["cc"] || []))
      |> List.delete(ap_id)
      |> List.delete(object_actor.data["followers"])

    data = %{
      "type" => "Like",
      "actor" => ap_id,
      "object" => id,
      "to" => to,
      "cc" => cc,
      "context" => object.data["context"]
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  def make_unlike_data(
        %{data: %{"id" => ap_id}} = actor,
        %{data: %{"context" => context}} = activity,
        activity_id
      ) do
    data = %{
      "type" => "Undo",
      "actor" => ap_id,
      "object" => activity.data,
      "to" => [actor.data["followers"], activity.data["actor"]],
      "cc" => [@public_uri],
      "context" => context
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  #### Announce-related helpers

  @doc """
  Retruns an existing announce activity if the notice has already been announced
  """
  def get_existing_announce(actor, %{data: %{"id" => id}}) do
    query =
      from(
        object in Object,
        where: fragment("(?)->>'actor' = ?", object.data, ^actor),
        # this is to use the index
        where:
          fragment(
            "coalesce((?)->'object'->>'id', (?)->>'object') = ?",
            object.data,
            object.data,
            ^id
          ),
        where: fragment("(?)->>'type' = 'Announce'", object.data)
      )

    repo().one(query)
  end

  @doc """
  Make announce activity data for the given actor and object
  """
  # for relayed messages, we only want to send to subscribers
  def make_announce_data(
        actor,
        object,
        activity_id,
        public?,
        summary \\ nil
      )

  def make_announce_data(
        %{data: %{"id" => ap_id}} = actor,
        %Object{data: %{"id" => id}} = object,
        activity_id,
        false,
        summary
      ) do
    data = %{
      "type" => "Announce",
      "actor" => ap_id,
      "object" => id,
      "to" => [actor.data["followers"]],
      "cc" => [],
      "context" => object.data["context"],
      "summary" => summary
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  def make_announce_data(
        %{data: %{"id" => ap_id}} = actor,
        %Object{data: %{"id" => id}} = object,
        activity_id,
        true,
        summary
      ) do
    data = %{
      "type" => "Announce",
      "actor" => ap_id,
      "object" => id,
      "to" => [actor.data["followers"], object.data["actor"]],
      "cc" => [@public_uri],
      "context" => object.data["context"],
      "summary" => summary
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  @doc """
  Make unannounce activity data for the given actor and object
  """
  def make_unannounce_data(
        %{data: %{"id" => ap_id}} = actor,
        %Object{data: %{"context" => context}} = activity,
        activity_id
      ) do
    data = %{
      "type" => "Undo",
      "actor" => ap_id,
      "object" => activity.data,
      "to" => [actor.data["followers"], activity.data["actor"]],
      "cc" => [@public_uri],
      "context" => context
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  #### Follow-related helpers
  def make_follow_data(
        %{data: %{"id" => follower_id}},
        %{data: %{"id" => followed_id}} = _followed,
        activity_id
      ) do
    data = %{
      "type" => "Follow",
      "actor" => follower_id,
      "to" => [followed_id],
      "cc" => [@public_uri],
      "object" => followed_id,
      "state" => "pending"
    }

    data = if activity_id, do: Map.put(data, "id", activity_id), else: data

    data
    |> info()
  end

  def fetch_latest_follow(%{data: %{"id" => follower_id}}, %{
        data: %{"id" => followed_id}
      }) do
    query =
      from(
        activity in Object,
        where:
          fragment(
            "? ->> 'type' = 'Follow'",
            activity.data
          ),
        where:
          fragment(
            "? ->> 'actor' = ?",
            activity.data,
            ^follower_id
          ),
        where:
          fragment(
            "coalesce((?)->'object'->>'id', (?)->>'object') = ?",
            activity.data,
            activity.data,
            ^followed_id
          ),
        order_by: [fragment("? desc nulls last", activity.inserted_at)],
        limit: 1
      )

    repo().one(query)
  end

  def make_unfollow_data(follower, followed, follow_activity, activity_id) do
    data = %{
      "type" => "Undo",
      "actor" => follower.data["id"],
      "to" => [followed.data["id"]],
      "object" => follow_activity.data
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  #### Block-related helpers
  def fetch_latest_block(%{data: %{"id" => blocker_id}}, %{
        data: %{"id" => blocked_id}
      }) do
    query =
      from(
        activity in Object,
        where:
          fragment(
            "? ->> 'type' = 'Block'",
            activity.data
          ),
        where:
          fragment(
            "? ->> 'actor' = ?",
            activity.data,
            ^blocker_id
          ),
        where:
          fragment(
            "coalesce((?)->'object'->>'id', (?)->>'object') = ?",
            activity.data,
            activity.data,
            ^blocked_id
          ),
        order_by: [fragment("? desc nulls last", activity.inserted_at)],
        limit: 1
      )

    repo().one(query)
  end

  def make_block_data(blocker, blocked, activity_id) do
    data = %{
      "type" => "Block",
      "actor" => blocker.data["id"],
      "to" => [blocked.data["id"]],
      "object" => blocked.data["id"]
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  def make_unblock_data(blocker, blocked, block_activity, activity_id) do
    data = %{
      "type" => "Undo",
      "actor" => blocker.data["id"],
      "to" => [blocked.data["id"]],
      "object" => block_activity.data
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  #### Create-related helpers
  def make_create_data(params, additional) do
    published = params.published || make_date()

    %{
      "type" => "Create",
      "to" => params.to,
      "actor" => params.actor.data["id"],
      "object" => params.object,
      "published" => published,
      "context" => params.context
    }
    |> Map.merge(additional)
  end

  #### Flag-related helpers
  def make_flag_data(params, additional) do
    status_ap_ids =
      Enum.map(params.statuses || [], fn
        %Object{} = act -> act.data["id"]
        act when is_map(act) -> act["id"]
        act when is_binary(act) -> act
      end)

    object = [params.account.data["id"]] ++ status_ap_ids

    %{
      "type" => "Flag",
      "actor" => params.actor.data["id"],
      "content" => params.content,
      "object" => object,
      "context" => params.context,
      "state" => "open"
    }
    |> Map.merge(additional)
  end

  @doc """
  Inserts a full object if it is contained in an activity.
  """
  def insert_full_object(
        activity,
        local \\ false,
        pointer \\ nil,
        upsert? \\ false
      )

  def insert_full_object(
        %{"object" => %{"type" => type} = object_data} = activity,
        local,
        pointer,
        upsert?
      )
      when is_map(object_data) and
             type not in @supported_actor_types and
             type not in @supported_activity_types do
    # we're taking a shortcut by assuming that anything that doesn't seem like an actor or activity is an object (which is better than only supporting a specific list of object types)
    # check that it doesn't already exist
    with maybe_existing_object <- Object.normalize(object_data, false) |> info("maybe_existing_object"),
         {:ok, data} <- prepare_data(object_data, local, pointer, activity),
         {:ok, object} <-
           Object.maybe_upsert(upsert?, maybe_existing_object, data) do
      # return an activity that contains the ID as object rather than the actual object
      {:ok, Map.put(activity, "object", object.data["id"]), object}
    end
  end

  def insert_full_object(activity, _local, _pointer, _), do: {:ok, activity, nil}

  @doc """
  Determines if an object or an activity is public.
  """
  def public?(data) do
    recipients = List.wrap(data["to"]) ++ List.wrap(data["cc"])

    cond do
      recipients == [] ->
        # let's NOT assume things are public by default?
        false

      Enum.member?(recipients, @public_uri) or
        Enum.member?(recipients, "Public") or
          Enum.member?(recipients, "as:Public") ->
        # see note at https://www.w3.org/TR/activitypub/#public-addressing
        true

      true ->
        false
    end
  end

  def public?(activity_data, %{data: object_data}) do
    public?(activity_data, object_data)
  end

  def public?(%{data: activity_data}, object_data) do
    public?(activity_data, object_data)
  end

  def public?(%{"to" => _} = activity_data, %{"to" => _} = object_data) do
    public?(activity_data) && public?(object_data)
  end

  def public?(%{"to" => _} = activity_data, _) do
    public?(activity_data)
  end

  def public?(_, %{"to" => _} = object_data) do
    public?(object_data)
  end

  def public?(_, _) do
    false
  end

  def actor?(%{data: %{"type" => type}} = _object)
      when type in @supported_actor_types,
      do: true

  def actor?(_), do: false

  @doc """
  Prepares a struct to be inserted into the objects table
  """
  def prepare_data(data, local \\ false, pointer \\ nil, activity \\ nil) do
    data =
      %{}
      |> Map.put(:data, data)
      |> Map.put(:local, local)
      |> Map.put(:public, public?(data, activity))
      |> Map.put(:pointer_id, pointer)

    {:ok, data}
  end

  @doc """
  Enqueues an activity for federation if it's local
  """
  def maybe_federate(%Object{local: true} = activity) do
    if federating?() do
      with {:ok, job} <- ActivityPubWeb.Federator.publish(activity) do
        info(job,
        "ActivityPub outgoing federation has been queued"
      )

        :ok
      end
    else
      warn(
        "ActivityPub outgoing federation is disabled, skipping (change `:activity_pub, :instance, :federating` to `true` in config to enable)"
      )
      :ok
    end
  end

  def maybe_federate(object) do
    warn(object,
        "Skip outgoing federation of non-local object"
      )
    :ok
  end

  def federating? do
    (
      Application.get_env(:activity_pub, :instance)[:federating] ||
      (Application.get_env(:activity_pub, :env) == :test and Application.get_env(:tesla, :adapter) == Tesla.Mock) ||
       System.get_env("TEST_INSTANCE") == "yes"
    )
    # |> IO.inspect(label: "Federating?")
  end

  def lazy_put_activity_defaults(map, activity_id) do
    context = create_context(map["context"])

    map =
      map
      |> Map.put_new("id", object_url(activity_id))
      |> Map.put_new_lazy("published", &make_date/0)
      |> Map.put_new("context", context)

    if is_map(map["object"]) do
      object = map["object"]
      |> lazy_put_object_defaults(map["context"])
      |> normalize_actors()
      %{map | "object" => object}
    else
      map
    end
  end

  def lazy_put_object_defaults(map, context) do
    map
    |> Map.put_new_lazy("id", &generate_object_id/0)
    |> Map.put_new_lazy("published", &make_date/0)
    |> maybe_put("context", context)
  end

  def create_context(context) do
    context || generate_id("contexts")
  end

  def is_ulid?(str) when is_binary(str) and byte_size(str) == 26 do
    with :error <- Pointers.ULID.cast(str) do
      false
    else
      _ -> true
    end
  end

  def is_ulid?(_), do: false

  # def maybe_forward_activity(
  #       %{data: %{"type" => "Create", "to" => to, "object" => object}} = activity
  #     ) do
  #     to
  #     |> List.delete("https://www.w3.org/ns/activitystreams#Public")
  #     |> Enum.map(&Actor.get_cached_by_ap_id!/1)
  #     |> Enum.filter(fn actor ->
  #       actor.data["type"] == "Group"
  #     end)
  #   |> Enum.map(fn group ->
  #     ActivityPub.create(%{
  #       to: ["https://www.w3.org/ns/activitystreams#Public"],
  #       object: object,
  #       actor: group,
  #       context: activity.data["context"],
  #       additional: %{
  #         "cc" => [group.data["followers"]],
  #         "attributedTo" => activity.data["actor"]
  #       }
  #     })
  #   end)
  # end

  # def maybe_forward_activity(_), do: :ok

  def set_repo(repo) when is_binary(repo) do
    String.to_existing_atom(repo)
    |> set_repo()
  end
  def set_repo(nil), do: nil
  def set_repo(repo) do
    if is_atom(repo) and Code.ensure_loaded?(repo) do
      Process.put(:ecto_repo_module, repo)
      ActivityPub.Config.get!(:repo).put_dynamic_repo(repo)
    else
      error(repo, "invalid module")
  end
  end

  def cachex_fetch(cache, key, fallback, options \\ []) when is_function(fallback) do
    p = Process.get()
    Cachex.fetch(cache, key, fn _ ->
      # Process.put(:phoenix_endpoint_module, p[:phoenix_endpoint_module])
      set_repo(p[:ecto_repo_module])

       fallback.()
      end,
      options)
  end

  # TODO: avoid storing multiple copies of things in cache
  # def get_with_cache(get_fun, cache_bucket, :id, identifier) do
  #   do_get_with_cache(get_fun, cache_bucket, :id, identifier)
  # end
  # def get_with_cache(get_fun, cache_bucket, key, identifier) do
  #   cachex_fetch(cache_bucket, key, fn ->
  #   end)
  # end

  def get_with_cache(get_fun, cache_bucket, key, identifier) when is_function(get_fun) do
    cache_key = "#{key}:#{identifier}"

    case cachex_fetch(cache_bucket, cache_key, fn ->
      case get_fun.([{key, identifier}]) do
        {:ok, object} ->
          info(object, "got with #{key} - #{identifier} :")
          {:commit, object}
      e ->
        info(e, "nothing with #{key} - #{identifier} ")
        {:ignore, e}
      end
    end) do
      {:ok, object} -> {:ok, object}
      {:commit, object} -> {:ok, object}
      {:ignore, _} -> {:error, :not_found}
      {:error, :no_cache} -> get_fun.([{key, identifier}])
      msg -> error(msg)
    end
  catch
    _ ->
      # workaround :nodedown errors
      get_fun.([{key, identifier}])
  rescue
    _ ->
      get_fun.([{key, identifier}])
  end

  def actor_from_data(%{"attributedTo" => actor} = _data), do: actor

  def actor_from_data(%{"actor" => actor} = _data), do: actor

  def actor_from_data(%{"id" => actor, "type" => type} = _data)
      when type in @supported_actor_types,
      do: actor

  def actor_from_data(%{data: data}), do: actor_from_data(data)

  def get_ap_id(%{"id" => id} = _), do: id
  def get_ap_id(%{data: data}), do: get_ap_id(data)
  def get_ap_id(id) when is_binary(id), do: id
  def get_ap_id(_), do: nil


  def normalize_actors(params) do
    # Some implementations include actors as URIs, others inline the entire actor object, this function figures out what the URIs are based on what we have.
    params
    |> maybe_put("actor", get_ap_id(params["actor"]))
    |> maybe_put("to", Enum.map(List.wrap(params["to"]), &get_ap_id/1))
    |> maybe_put("bto", Enum.map(List.wrap(params["bto"]), &get_ap_id/1))
    |> maybe_put("cc", Enum.map(List.wrap(params["cc"]), &get_ap_id/1))
    |> maybe_put("bcc", Enum.map(List.wrap(params["bcc"]), &get_ap_id/1))
    |> maybe_put("audience", Enum.map(List.wrap(params["audience"]), &get_ap_id/1))
  end

  @doc "conditionally update a map"
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, _key, []), do: map
  def maybe_put(map, _key, ""), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

end
