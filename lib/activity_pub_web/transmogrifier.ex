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
  require Logger

  # TODO: make configurable
  @supported_actor_types ["Person", "Application", "Service", "Organization", "Group"]
  @collection_types ["Collection", "OrderedCollection", "CollectionPage", "OrderedCollectionPage"]

  @doc """
  Modifies an incoming AP object (mastodon format) to our internal format.
  """
  def fix_object(object) do
    object
    |> fix_actor()
  end

  def fix_actor(%{"attributedTo" => actor} = object) do
    Map.put(object, "actor", Fetcher.get_actor(%{"actor" => actor}))
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

  def prepare_outgoing(%{"type" => "Create", "object" => object_id} = data) do
    object =
      object_id
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
    with object_id when not is_nil(object_id) <- Utils.get_ap_id(follow_object),
         {_, %Object{} = activity} <- {:activity, Object.get_cached_by_ap_id(object_id)} do
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
    Logger.info("Checking delete permission for #{ap_id}")

    case Fetcher.fetch_remote_object_from_id(ap_id) do
      {:error, "Object has been deleted"} -> true
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
    with context <- data["context"] || Utils.generate_context_id(),
         content <- data["content"] || "",
         {:ok, actor} <- Actor.get_or_fetch_by_ap_id(actor),

         # Reduce the object list to find the reported user.
         account <-
           Enum.reduce_while(objects, nil, fn ap_id, _ ->
             with {:ok, actor} <- Actor.get_cached_by_ap_id(ap_id) do
               {:halt, actor}
             else
               _ -> {:cont, nil}
             end
           end),

         # Remove the reported user from the object list.
         statuses <- Enum.filter(objects, fn ap_id -> ap_id != account.data["id"] end) do
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
  def handle_incoming(%{"id" => nil}), do: :error
  def handle_incoming(%{"id" => ""}), do: :error
  # length of https:// = 8, should validate better, but good enough for now.
  def handle_incoming(%{"id" => id}) when not (is_binary(id) and byte_size(id) > 8),
    do: :error

  # Incoming actor create, just fetch from source
  def handle_incoming(%{"type" => "Create", "object" => %{"type" => "Group", "id" => ap_id}}),
    do: Actor.get_or_fetch_by_ap_id(ap_id)

  def handle_incoming(%{"type" => "Create", "object" => object} = data) do
    data = Utils.normalize_params(data)
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

  def handle_incoming(%{"type" => "Follow", "object" => followed, "actor" => follower, "id" => id}) do
    with {:ok, followed} <- Actor.get_cached_by_ap_id(followed),
         {:ok, follower} <- Actor.get_or_fetch_by_ap_id(follower) do
      ActivityPub.follow(follower, followed, id, false)
    end
  end

  def handle_incoming(
        %{"type" => "Accept", "object" => follow_object, "actor" => _actor, "id" => _id} = data
      ) do
    with actor <- Fetcher.get_actor(data),
         {:ok, followed} <- Actor.get_or_fetch_by_ap_id(actor),
         {:ok, follow_activity} <- get_follow_activity(follow_object, followed) do
      ActivityPub.accept(%{
        to: follow_activity.data["to"],
        type: "Accept",
        actor: followed,
        object: follow_activity.data["id"],
        local: false
      })
    else
      _e -> :error
    end
  end

  # TODO: add reject

  def handle_incoming(
        %{"type" => "Like", "object" => object_id, "actor" => _actor, "id" => id} = data
      ) do
    with actor <- Fetcher.get_actor(data),
         {:ok, actor} <- Actor.get_or_fetch_by_ap_id(actor),
         {:ok, object} <- get_obj_helper(object_id),
         {:ok, activity, _object} <- ActivityPub.like(actor, object, id, false) do
      {:ok, activity}
    else
      _e -> :error
    end
  end

  def handle_incoming(
        %{"type" => "Announce", "object" => object_id, "actor" => _actor, "id" => id} = data
      ) do
    with actor <- Fetcher.get_actor(data),
         {:ok, actor} <- Actor.get_or_fetch_by_ap_id(actor),
         {:ok, object} <- get_obj_helper(object_id),
         public <- Utils.public?(data),
         {:ok, activity, _object} <- ActivityPub.announce(actor, object, id, false, public) do
      {:ok, activity}
    else
      _e -> :error
    end
  end

  # This feels bad
  def handle_incoming(
        %{"type" => "Update", "object" => %{"type" => object_type} = object, "actor" => actor_id} =
          data
      )
      when object_type in @supported_actor_types do
    with {:ok, _} <- Actor.update_actor_data_by_ap_id(actor_id, object),
         {:ok, actor} <- Actor.get_by_ap_id(actor_id),
         {:ok, _} <- Actor.set_cache(actor) do
      ActivityPub.update(%{
        local: false,
        to: data["to"] || [],
        cc: data["cc"] || [],
        object: object,
        actor: actor
      })
    else
      e ->
        Logger.error(e)
        :error
    end
  end

  def handle_incoming(
        %{"type" => "Block", "object" => blocked, "actor" => blocker, "id" => id} = _data
      ) do
    with {:ok, %{local: true} = blocked} <- Actor.get_cached_by_ap_id(blocked),
         {:ok, blocker} <- Actor.get_or_fetch_by_ap_id(blocker),
         {:ok, activity} <- ActivityPub.block(blocker, blocked, id, false) do
      {:ok, activity}
    else
      _e -> :error
    end
  end

  def handle_incoming(
        %{"type" => "Delete", "object" => object_id, "actor" => _actor, "id" => _id} = _data
      ) do
    object_id = Utils.get_ap_id(object_id)

    with {:ok, object} <- get_obj_helper(object_id),
         {:actor, false} <- {:actor, Utils.actor?(object)},
         true <- can_delete_object?(object_id),
         {:ok, activity} <- ActivityPub.delete(object, false) do
      {:ok, activity}
    else
      {:actor, true} ->
        case Actor.get_cached_by_ap_id(object_id) do
          # FIXME: This is supposed to prevent unauthorized deletes
          # but we currently use delete activities where the activity
          # actor isn't the deleted object so we need to disable it.
          # {:ok, %Actor{data: %{"id" => ^actor}} = actor} ->
          {:ok, %Actor{} = actor} ->
            ActivityPub.delete(actor, false)
            Actor.delete(actor)

          {:error, _} ->
            :error
        end

      _e ->
        :error
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
    with actor <- Fetcher.get_actor(data),
         {:ok, actor} <- Actor.get_or_fetch_by_ap_id(actor),
         {:ok, object} <- get_obj_helper(object_id),
         {:ok, activity, _} <- ActivityPub.unannounce(actor, object, id, false) do
      {:ok, activity}
    else
      _e -> :error
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
    with actor <- Fetcher.get_actor(data),
         {:ok, actor} <- Actor.get_or_fetch_by_ap_id(actor),
         {:ok, object} <- get_obj_helper(object_id),
         {:ok, activity, _, _} <- ActivityPub.unlike(actor, object, id, false) do
      {:ok, activity}
    else
      _e -> :error
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
    with {:ok, follower} <- Actor.get_or_fetch_by_ap_id(follower),
         {:ok, followed} <- Actor.get_or_fetch_by_ap_id(followed) do
      ActivityPub.unfollow(follower, followed, id, false)
    else
      _e -> :error
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
    with {:ok, %{local: true} = blocked} <- Actor.get_or_fetch_by_ap_id(blocked),
         {:ok, blocker} <- Actor.get_or_fetch_by_ap_id(blocker),
         {:ok, activity} <- ActivityPub.unblock(blocker, blocked, id, false) do
      {:ok, activity}
    else
      _e -> :error
    end
  end

  def handle_incoming(data) do
    Logger.warn("ActivityPub library - Unhandled activity - Storing it anyway...")

    {:ok, activity, _object} = Utils.insert_full_object(data)
    {:ok, activity} = handle_object(activity)
    if Application.get_env(:activity_pub, :handle_unknown_activities, false) do
      Adapter.maybe_handle_activity(activity)
    end
  end

  defp get_obj_helper(id) do
    if object = Object.normalize(id, true), do: {:ok, object}, else: nil
  end

  @doc """
  Normalises and inserts an incoming AS2 object. Returns Object.
  """
  def handle_object(%{"type" => type} = data) when type in @collection_types do
    with {:ok, object} <- Utils.prepare_data(data) do
      {:ok, object}
    else
      {:error, e} -> {:error, e}
    end
  end

  def handle_object(data) do
    with {:ok, object} <- Utils.prepare_data(data),
         {:ok, object} <- Object.insert(object) do
      {:ok, object}
    else
      {:error, e} -> {:error, e}
    end
  end
end
