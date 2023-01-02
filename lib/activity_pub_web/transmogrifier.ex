defmodule ActivityPubWeb.Transmogrifier do
  @moduledoc """
  This module normalises outgoing data to conform with AS2/AP specs
  and handles incoming objects and activities
  """

  alias ActivityPub.Actor
  alias ActivityPub.Adapter
  alias ActivityPub.Fetcher
  alias ActivityPub.Object
  alias ActivityPub.Utils
  import Untangle
  use Arrows

  @supported_activity_types ActivityPub.Config.supported_activity_types()
  @supported_actor_types ActivityPub.Config.supported_actor_types()
  @collection_types ActivityPub.Config.collection_types()
  @actors_and_collections @supported_actor_types ++ @collection_types

  @doc """
  Modifies an incoming AP object (mastodon format) to our internal format.
  """
  def fix_object(object) do
    object
    |> fix_actor()
  end

  def fix_actor(%{"attributedTo" => actor} = object) do
    Map.put(object, "actor", Object.actor_from_data(%{"actor" => actor}))
  end

  def fix_actor(object) do
    object
  end

  @doc """
  Translates MN Entity to an AP compatible format
  """
  def prepare_outgoing(%{"type" => "Create", "object" => %{"type" => "Group"}} = data) do
    data =
      data
      |> Map.merge(Utils.make_json_ld_header())
      |> Map.delete("bcc")

    {:ok, data}
  end

  def prepare_outgoing(%{"type" => "Create", "object" => %{data: _} = object} = data) do
    object =
      object
      |> Object.normalize()
      |> Map.get(:data)
      |> prepare_object

    data =
      data
      |> Map.put("object", object)
      |> Map.merge(Utils.make_json_ld_header())
      |> Map.delete("bcc")

    {:ok, data}
  end

  def prepare_outgoing(%{"type" => "Create", "object" => object} = data)
      when is_binary(object) do
    object =
      object
      |> Object.normalize()
      |> Map.get(:data)
      |> prepare_object

    data =
      data
      |> Map.put("object", object)
      |> Map.merge(Utils.make_json_ld_header())
      |> Map.delete("bcc")

    {:ok, data}
  end

  def prepare_outgoing(%{"type" => "Create", "object" => object} = data) do
    object =
      object
      |> prepare_object

    data =
      data
      |> Map.put("object", object)
      |> Map.merge(Utils.make_json_ld_header())
      |> Map.delete("bcc")

    {:ok, data}
  end

  # TODO hack for mastodon accept and reject type activity formats
  def prepare_outgoing(%{"type" => _type} = data) do
    data =
      data
      |> Map.merge(Utils.make_json_ld_header())

    {:ok, data}
  end

  # We currently do not perform any transformations on objects
  def prepare_object(object), do: object

  # incoming activities

  # TODO
  defp mastodon_follow_hack(_, _), do: {:error, nil}

  defp get_follow_activity(follow_object, followed) do
    info(follow_object)

    with object_id when not is_nil(object_id) <- Object.get_ap_id(follow_object) |> info,
         %Object{} = activity <- Object.get_cached!(ap_id: object_id) |> info do
      {:ok, activity}
    else
      # Can't find the activity. This might a Mastodon 2.3 "Accept"
      {:activity, nil} ->
        mastodon_follow_hack(follow_object, followed)

      _ ->
        {:error, nil}
    end
  end

  defp can_delete_object?(ap_id) do
    debug(ap_id, "Checking delete permission for")

    case Fetcher.fetch_remote_object_from_id(ap_id) do
      {:error, "Object not found or deleted"} -> true
      {:ok, %{"type" => "Tombstone"}} -> true
      _ -> false
    end
  end

  @doc """
  Handles incoming data, inserts it into the database and triggers side effects if the data is a supported activity type.
  """
  def handle_incoming(data)

  # Flag objects are placed ahead of the ID check because Mastodon 2.8 and earlier send them
  # with nil ID.
  def handle_incoming(%{"type" => "Flag", "object" => objects, "actor" => actor} = data) do
    with context <- data["context"],
         content <- data["content"] || "",
         {:ok, actor} <- Actor.get_or_fetch_by_ap_id(actor),

         # Reduce the object list to find the reported user.
         account <-
           Enum.reduce_while(objects, nil, fn ap_id, _ ->
             with {:ok, actor} <- Actor.get_cached(ap_id: ap_id) do
               {:halt, actor}
             else
               _ -> {:cont, nil}
             end
           end),

         # Remove the reported user from the object list.
         statuses <-
           Enum.filter(objects, fn ap_id -> ap_id != account.data["id"] end) do
      params = %{
        actor: actor,
        context: context,
        account: account,
        statuses: statuses,
        content: content,
        additional: %{
          "cc" => [account.data["id"]]
        }
      }

      ActivityPub.flag(params)
    end
  end

  # disallow objects with bogus IDs
  def handle_incoming(%{"id" => nil}), do: {:error, "No object ID"}
  def handle_incoming(%{"id" => ""}), do: {:error, "No object ID"}
  # length of https:// = 8, should validate better, but good enough for now.
  def handle_incoming(%{"id" => id}) when is_binary(id) and byte_size(id) < 8,
    do: {:error, "No object ID"}

  # Incoming actor create, just fetch from source
  def handle_incoming(%{
        "type" => "Create",
        "object" => %{"type" => "Group", "id" => ap_id}
      }),
      do: Actor.get_or_fetch_by_ap_id(ap_id)

  def handle_incoming(%{"type" => "Create", "object" => object} = data) do
    info("Handle incoming creation of an object")
    data = Object.normalize_actors(data)
    {:ok, actor} = Actor.get_or_fetch_by_ap_id(data["actor"])
    object = fix_object(object)

    params = %{
      to: data["to"],
      object: object,
      actor: actor,
      context: object["context"] || object["conversation"],
      local: false,
      published: data["published"],
      additional:
        Map.take(data, [
          "cc",
          "directMessage",
          "id"
        ])
    }

    ActivityPub.create(params)
  end

  def handle_incoming(%{
        "type" => "Follow",
        "object" => followed,
        "actor" => follower,
        "id" => id
      }) do
    info("Handle incoming follow")

    with {:ok, follower} <- Actor.get_or_fetch_by_ap_id(follower) |> info(follower),
         {:ok, followed} <- Actor.get_cached(ap_id: followed) |> info(followed) do
      ActivityPub.follow(%{actor: follower, object: followed, activity_id: id, local: false})
    end
  end

  def handle_incoming(
        %{
          "type" => "Accept",
          "object" => follow_object,
          "actor" => _actor,
          "id" => _id
        } = data
      ) do
    info("Handle incoming Accept")

    with followed_actor <- Object.actor_from_data(data) |> info(),
         {:ok, followed} <- Actor.get_or_fetch_by_ap_id(followed_actor) |> info(),
         {:ok, follow_activity} <- get_follow_activity(follow_object, followed) |> info() do
      ActivityPub.accept(%{
        to: follow_activity.data["to"],
        type: "Accept",
        actor: followed,
        object: follow_activity.data["id"],
        local: false
      })
      |> info()
    else
      e ->
        error(e, "Could not handle incoming Accept")
    end
  end

  # TODO: add reject

  def handle_incoming(
        %{
          "type" => "Like",
          "object" => object_id,
          "actor" => _actor,
          "id" => id
        } = data
      ) do
    info("Handle incoming like")

    with actor <- Object.actor_from_data(data),
         {:ok, actor} <- Actor.get_or_fetch_by_ap_id(actor),
         {:ok, object} <- get_obj_helper(object_id),
         {:ok, activity} <-
           ActivityPub.like(%{actor: actor, object: object, activity_id: id, local: false}) do
      {:ok, activity}
    else
      e -> error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Announce",
          "object" => object_id,
          "actor" => _actor,
          "id" => id
        } = data
      ) do
    info("Handle incoming boost")

    with actor <- Object.actor_from_data(data),
         {:ok, actor} <- Actor.get_or_fetch_by_ap_id(actor),
         {:ok, object} <- get_obj_helper(object_id),
         public <- Utils.public?(data, object),
         {:ok, activity} <-
           ActivityPub.announce(%{
             actor: actor,
             object: object,
             activity_id: id,
             local: false,
             public: public
           }) do
      {:ok, activity}
    else
      e -> error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Update",
          "object" => %{"type" => object_type, "id" => update_actor_id} = object,
          "actor" => actor_id
        } = data
      )
      when object_type in @supported_actor_types and actor_id == update_actor_id do
    info("Handle incoming update an Actor")

    with {:ok, actor} <- Actor.update_actor_data_by_ap_id(actor_id, object) do
        #  {:ok, actor} <- Actor.get_cached(ap_id: actor_id),
        #  {:ok, _} <- Actor.set_cache(actor) do
      ActivityPub.update(%{
        local: false,
        to: data["to"] || [],
        cc: data["cc"] || [],
        object: object,
        actor: actor
      })
    else
      e ->
        error(e, "could not update")
    end
  end

  def handle_incoming(
        %{
          "type" => "Update",
          "object" => %{"type" => object_type} = object,
          "actor" => actor
        } = data
      ) do
    info("Handle incoming update of an Object")

    with {:ok, actor} <- Actor.get_or_fetch_by_ap_id(actor) do
        #  {:ok, actor} <- Actor.get_cached(ap_id: actor_id),
        #  {:ok, _} <- Actor.set_cache(actor) do
      ActivityPub.update(%{
        local: false,
        to: data["to"] || [],
        cc: data["cc"] || [],
        object: object,
        actor: actor
      })
    else
      e ->
        error(e, "could not update")
    end
  end

  def handle_incoming(
        %{
          "type" => "Block",
          "object" => blocked,
          "actor" => blocker,
          "id" => id
        } = _data
      ) do
    info("Handle incoming block")

    with {:ok, %{local: true} = blocked} <- Actor.get_cached(ap_id: blocked),
         {:ok, blocker} <- Actor.get_or_fetch_by_ap_id(blocker),
         {:ok, activity} <-
           ActivityPub.block(%{actor: blocker, object: blocked, activity_id: id, local: false}) do
      {:ok, activity}
    else
      e -> error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Delete",
          "object" => object_id,
          "actor" => _actor,
          "id" => _id
        } = _data
      ) do
    info("Handle incoming deletion")

    object_id = Object.get_ap_id(object_id)

    with {:ok, object} <- get_obj_helper(object_id),
         {:actor, false} <- {:actor, Actor.actor?(object)},
         true <- can_delete_object?(object_id),
         {:ok, activity} <- ActivityPub.delete(object, false) do
      {:ok, activity}
    else
      {:actor, true} ->
        case Actor.get_cached(ap_id: object_id) do
          # FIXME: This is supposed to prevent unauthorized deletes
          # but we currently use delete activities where the activity
          # actor isn't the deleted object so we need to disable it.
          # {:ok, %Actor{data: %{"id" => ^actor}} = actor} ->
          {:ok, %Actor{} = actor} ->
            ActivityPub.delete(actor, false)
            Actor.delete(actor)

          e ->
            error(e)
        end

      e ->
        error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Undo",
          "object" => %{"type" => "Announce", "object" => object_id},
          "actor" => _actor,
          "id" => id
        } = data
      ) do
    info("Handle incoming unboost")

    with actor <- Object.actor_from_data(data),
         {:ok, actor} <- Actor.get_or_fetch_by_ap_id(actor),
         {:ok, object} <- get_obj_helper(object_id),
         {:ok, activity} <-
           ActivityPub.unannounce(%{actor: actor, object: object, activity_id: id, local: false}) do
      {:ok, activity}
    else
      e -> error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Undo",
          "object" => %{"type" => "Like", "object" => object_id},
          "actor" => _actor,
          "id" => id
        } = data
      ) do
    info("Handle incoming unlike")

    with actor <- Object.actor_from_data(data),
         {:ok, actor} <- Actor.get_or_fetch_by_ap_id(actor),
         {:ok, object} <- get_obj_helper(object_id),
         {:ok, activity} <-
           ActivityPub.unlike(%{actor: actor, object: object, activity_id: id, local: false}) do
      {:ok, activity}
    else
      e -> error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Undo",
          "object" => %{"type" => "Follow", "object" => followed},
          "actor" => follower,
          "id" => id
        } = _data
      ) do
    info("Handle incoming unfollow")

    with {:ok, follower} <- Actor.get_or_fetch_by_ap_id(follower),
         {:ok, followed} <- Actor.get_or_fetch_by_ap_id(followed) do
      ActivityPub.unfollow(%{actor: follower, object: followed, activity_id: id, local: false})
    else
      e -> error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Undo",
          "object" => %{"type" => "Block", "object" => blocked},
          "actor" => blocker,
          "id" => id
        } = _data
      ) do
    info("Handle incoming unblock")

    with {:ok, %{local: true} = blocked} <-
           Actor.get_or_fetch_by_ap_id(blocked),
         {:ok, blocker} <- Actor.get_or_fetch_by_ap_id(blocker),
         {:ok, activity} <-
           ActivityPub.unblock(%{actor: blocker, object: blocked, activity_id: id, local: false}) do
      {:ok, activity}
    else
      e -> error(e)
    end
  end

  # Handle other activity types (and their object)
  def handle_incoming(%{"type" => type} = data) when type in @supported_activity_types do
    info("ActivityPub - some other Activity - store it and pass to adapter anyway...")

    {:ok, activity, _object} = Object.insert_full_object(data)
    {:ok, activity} = handle_object(activity)

    if Keyword.get(
         Application.get_env(:activity_pub, :instance),
         :handle_unknown_activities
       ) do
      with {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
           activity <- Map.put(activity, :pointer, adapter_object) do
        {:ok, activity}
      end
    else
      {:ok, activity}
    end
  end

  # Save actors and collections without an activity
  def handle_incoming(%{"type" => type} = data) when type in @actors_and_collections do
    handle_object(data)
    ~> ActivityPub.Actor.maybe_create_actor_from_object()
  end

  # Wrap standalone non-actor objects in a create activity, returns the Object
  def handle_incoming(data) do
    handle_incoming(%{
      "type" => "Create",
      "to" => data["to"],
      "cc" => data["cc"],
      "actor" => Object.actor_from_data(data),
      "object" => data
    })
  end

  defp get_obj_helper(id) do
    if object = Object.normalize(id, true), do: {:ok, object}, else: nil
  end

  @doc """
  Normalises and inserts an incoming AS2 object. Returns Object.
  """
  def handle_object(%{"type" => type} = data) when type in @collection_types do
    # don't store Collections
    with {:ok, object} <- Object.prepare_data(data) do
      {:ok, object}
    end
  end

  def handle_object(data) do
    with {:ok, object} <- Object.prepare_data(data),
         {:ok, object} <- Object.do_insert(object) do
      {:ok, object}
    end
  end
end
