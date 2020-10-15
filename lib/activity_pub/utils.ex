defmodule ActivityPub.Utils do
  @moduledoc """
  Misc functions used for federation
  """
  alias ActivityPub.Actor
  alias ActivityPub.Object
  alias Ecto.UUID
  @repo Application.get_env(:activity_pub, :repo)

  import Ecto.Query

  @public_uri "https://www.w3.org/ns/activitystreams#Public"
  @supported_object_types ["Article", "Note", "Video", "Page", "Question", "Answer", "Document"]

  def get_ap_id(%{"id" => id} = _), do: id
  def get_ap_id(id), do: id

  @doc """
  Some implementations send the actor URI as the actor field, others send the entire actor object,
  this function figures out what the actor's URI is based on what we have.
  """
  def normalize_params(params) do
    Map.put(params, "actor", get_ap_id(params["actor"]))
  end

  defp make_date do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  def generate_context_id, do: generate_id("contexts")

  def generate_object_id, do: generate_id("objects")


  def generate_id(type), do: ap_base_url() <> "/#{type}/#{UUID.generate()}"

  def actor_url(%{preferred_username: u}), do: ap_base_url() <> "/actors/" <> u

  def object_url(%{id: id}), do: ap_base_url() <> "/objects/" <> id

  defp ap_base_url() do
    ActivityPubWeb.base_url() <> System.get_env("AP_BASE_PATH", "/pub")
  end

  def make_json_ld_header do
    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://litepub.social/litepub/context.jsonld",
        "http://schema.org/",
        %{
          "collections" => "mn:collections",
          "resources" => "mn:resources"
        },
        %{
          "@language" => "und"
        }
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

    @repo.one(query)
  end

  def make_like_data(
        %{data: %{"id" => ap_id}} = actor,
        %{data: %{"id" => id}} = object,
        activity_id
      ) do
    object_actor_id = ActivityPub.Fetcher.get_actor(object.data)
    {:ok, object_actor} = Actor.get_cached_by_ap_id(object_actor_id)

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
      "cc" => ["https://www.w3.org/ns/activitystreams#Public"],
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

    @repo.one(query)
  end

  @doc """
  Make announce activity data for the given actor and object
  """
  # for relayed messages, we only want to send to subscribers
  def make_announce_data(
        %{data: %{"id" => ap_id}} = actor,
        %Object{data: %{"id" => id}} = object,
        activity_id,
        false
      ) do
    data = %{
      "type" => "Announce",
      "actor" => ap_id,
      "object" => id,
      "to" => [actor.data["followers"]],
      "cc" => [],
      "context" => object.data["context"]
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  def make_announce_data(
        %{data: %{"id" => ap_id}} = actor,
        %Object{data: %{"id" => id}} = object,
        activity_id,
        true
      ) do
    data = %{
      "type" => "Announce",
      "actor" => ap_id,
      "object" => id,
      "to" => [actor.data["followers"], object.data["actor"]],
      "cc" => ["https://www.w3.org/ns/activitystreams#Public"],
      "context" => object.data["context"]
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
      "cc" => ["https://www.w3.org/ns/activitystreams#Public"],
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
  end

  def fetch_latest_follow(%{data: %{"id" => follower_id}}, %{data: %{"id" => followed_id}}) do
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

    @repo.one(query)
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
  def fetch_latest_block(%{data: %{"id" => blocker_id}}, %{data: %{"id" => blocked_id}}) do
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

    @repo.one(query)
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
      "to" => params.to |> Enum.uniq(),
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
  def insert_full_object(map, local \\ false, pointer \\ nil)
  def insert_full_object(%{"object" => %{"type" => type} = object_data} = map, local, pointer)
      when is_map(object_data) and type in @supported_object_types do
    with nil <- Object.normalize(object_data, false),
         {:ok, data} <- prepare_data(object_data, local, pointer),
         {:ok, object} <- Object.insert(data) do
      map =
        map
        |> Map.put("object", object.data["id"])

      {:ok, map, object}
    end
  end

  def insert_full_object(map, _local, _pointer), do: {:ok, map, nil}

  @doc """
  Determines if an object or an activity is public.
  """
  def public?(data) do
    recipients = (data["to"] || []) ++ (data["cc"] || [])

    cond do
      recipients == [] ->
        true

      Enum.member?(recipients, "https://www.w3.org/ns/activitystreams#Public") ->
        true

      true ->
        false
    end
  end

  def actor?(%{data: %{"type" => type}} = _object)
      when type in ["Person", "Application", "Service", "Organization", "Group"],
      do: true

  def actor?(_), do: false

  @doc """
  Prepares a struct to be inserted into the objects table
  """
  def prepare_data(data, local \\ false, pointer \\ nil) do
    data =
      %{}
      |> Map.put(:data, data)
      |> Map.put(:local, local)
      |> Map.put(:public, public?(data))
      |> Map.put(:pointer_id, pointer)

    {:ok, data}
  end

  @doc """
  Enqueues an activity for federation if it's local
  """
  def maybe_federate(%Object{local: true} = activity) do
    if Application.get_env(:activity_pub, :instance)[:federating] do
      ActivityPubWeb.Federator.publish(activity)
    end

    :ok
  end

  def maybe_federate(_), do: :ok

  def lazy_put_activity_defaults(map) do
    context = create_context(map["context"])

    map =
      map
      |> Map.put_new_lazy("id", &generate_object_id/0)
      |> Map.put_new_lazy("published", &make_date/0)
      |> Map.put_new("context", context)

    if is_map(map["object"]) do
      object = lazy_put_object_defaults(map["object"], map)
      %{map | "object" => object}
    else
      map
    end
  end

  def lazy_put_object_defaults(map, activity) do
    map
    |> Map.put_new_lazy("id", &generate_object_id/0)
    |> Map.put_new_lazy("published", &make_date/0)
    |> Map.put_new("context", activity["context"])
  end

  def create_context(context) do
    context || generate_id("contexts")
  end
end
