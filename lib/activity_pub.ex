defmodule ActivityPub do
  @moduledoc """
  ActivityPub API

  In general, the functions in this module take object-like formatted struct as the input for actor parameters.
  Use the functions in the `ActivityPub.Actor` module (`ActivityPub.Actor.get_by_ap_id/1` for example) to retrieve those.

  Legacy: Delegates some functions to related ActivityPub submodules
  """
  alias ActivityPub.Actor
  alias ActivityPub.Adapter
  alias ActivityPub.Utils
  alias ActivityPub.Object
  alias ActivityPub.MRF
  @repo Application.get_env(:activity_pub, :repo)

  def maybe_forward_activity(
        %{data: %{"type" => "Create", "to" => to, "object" => object}} = activity
      ) do
    groups =
      to
      |> List.delete("https://www.w3.org/ns/activitystreams#Public")
      |> Enum.map(&Actor.get_by_ap_id!/1)
      |> Enum.filter(fn actor ->
        actor.data["type"] == "MN:Collection" or actor.data["type"] == "Group"
      end)

    groups
    |> Enum.map(fn group ->
      ActivityPub.create(%{
        to: ["https://www.w3.org/ns/activitystreams#Public"],
        object: object,
        actor: group,
        context: activity.data["context"],
        additional: %{
          "cc" => [group.data["followers"]],
          "attributedTo" => activity.data["actor"]
        }
      })
    end)
  end

  def maybe_forward_activity(_), do: :ok

  defp check_actor_is_active(actor) do
    if not is_nil(actor) do
      with {:ok, actor} <- Actor.get_cached_by_ap_id(actor),
           false <- actor.deactivated do
        :ok
      else
        _e -> :reject
      end
    else
      :ok
    end
  end

  @doc false
  def insert(map, local, pointer \\ nil) when is_map(map) and is_boolean(local) do
    with map <- Utils.lazy_put_activity_defaults(map),
         :ok <- check_actor_is_active(map["actor"]),
         # set some healthy boundaries
         {:ok, map} <- MRF.filter(map),
         # insert the object
         {:ok, map, object} <- Utils.insert_full_object(map, local, pointer) do

      # insert the activity (containing only an ID as object)
      {:ok, activity} =
        if is_nil(object) do
          Object.insert(%{
            data: map,
            local: local,
            public: Utils.public?(map),
            pointer_id: pointer
          })
        else
          Object.insert(%{
            data: map,
            local: local,
            public: Utils.public?(map)
          })
        end

      # Splice in the child object if we have one.
      activity =
        if !is_nil(object) do
          Map.put(activity, :object, object)
        else
          activity
        end

      {:ok, activity}
    else
      %Object{} = object -> object
      error -> {:error, error}
    end
  end

  @doc """
  Generates and federates a Create activity via the data passed through `params`.

  Requires `to`, `actor`, `context` and `object` fields to be present in the input map.

  `to` must be a list.</br>
  `actor` must be an `ActivityPub.Object`-like struct.</br>
  `context` must be a string. Use `ActivityPub.Utils.generate_context_id/0` to generate a default context.</br>
  `object` must be a map.
  """
  def create(%{to: to, actor: actor, context: context, object: object} = params, pointer \\ nil) do
    additional = params[:additional] || %{}
    # only accept false as false value
    local = !(params[:local] == false)
    published = params[:published]

    with nil <- Object.normalize(additional["id"], false),
         create_data <-
           Utils.make_create_data(
             %{to: to, actor: actor, published: published, context: context, object: object},
             additional
           ),
         {:ok, activity} <- insert(create_data, local, pointer),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    else
      %Object{} = activity -> {:ok, activity}
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Generates and federates an Accept activity via the data passed through `params`.

  Requires `to`, `actor` and `object` fields to be present in the input map.

  `to` must be a list.</br>
  `actor` must be an `ActivityPub.Object`-like struct.</br>
  `object` should be the URI of the object that is being accepted.
  """
  def accept(%{to: to, actor: actor, object: object} = params) do
    # only accept false as false value
    local = !(params[:local] == false)

    with data <- %{
           "to" => to,
           "type" => "Accept",
           "actor" => actor.data["id"],
           "object" => object
         },
         {:ok, activity} <- insert(data, local),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end

  @doc """
  Generates and federates a Reject activity via the data passed through `params`.

  Requires `to`, `actor` and `object` fields to be present in the input map.

  `to` must be a list.<br/>
  `actor` must be an `ActivityPub.Object`-like struct.<br/>
  `object` should be the URI of the object that is being rejected
  """
  def reject(%{to: to, actor: actor, object: object} = params) do
    # only accept false as false value
    local = !(params[:local] == false)

    with data <- %{
           "to" => to,
           "type" => "Reject",
           "actor" => actor.data["id"],
           "object" => object
         },
         {:ok, activity} <- insert(data, local),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end

  @doc """
  Generates and federates a Follow activity.

  Note: the follow should be reflected on the host database side only after receiving an `Accept` activity in response!
  """
  def follow(follower, followed, activity_id \\ nil, local \\ true) do
    with data <- Utils.make_follow_data(follower, followed, activity_id),
         {:ok, activity} <- insert(data, local),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end

  @doc """
  Generates and federates an Unfollow activity.
  """
  def unfollow(follower, followed, activity_id \\ nil, local \\ true) do
    with %Object{} = follow_activity <- Utils.fetch_latest_follow(follower, followed),
         unfollow_data <-
           Utils.make_unfollow_data(follower, followed, follow_activity, activity_id),
         {:ok, activity} <- insert(unfollow_data, local),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end

  def like(
        %{data: %{"id" => ap_id}} = actor,
        %Object{data: %{"id" => _}} = object,
        activity_id \\ nil,
        local \\ true
      ) do
    with nil <- Utils.get_existing_like(ap_id, object),
         like_data <- Utils.make_like_data(actor, object, activity_id),
         {:ok, activity} <- insert(like_data, local),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity, object}
    else
      %Object{} = activity -> {:ok, activity, object}
      error -> {:error, error}
    end
  end

  def unlike(
        %{data: %{"id" => ap_id}} = actor,
        %Object{} = object,
        activity_id \\ nil,
        local \\ true
      ) do
    with %Object{} = like_activity <- Utils.get_existing_like(ap_id, object),
         unlike_data <- Utils.make_unlike_data(actor, like_activity, activity_id),
         {:ok, unlike_activity} <- insert(unlike_data, local),
         {:ok, _activity} <- @repo.delete(like_activity),
         :ok <- Utils.maybe_federate(unlike_activity),
         :ok <- Adapter.maybe_handle_activity(unlike_activity) do
      {:ok, unlike_activity, like_activity, object}
    else
      _e -> {:ok, object}
    end
  end

  def announce(
        %{data: %{"id" => _}} = actor,
        %Object{data: %{"id" => _}} = object,
        activity_id \\ nil,
        local \\ true,
        public \\ true
      ) do
    with true <- Utils.public?(object.data),
         announce_data <- Utils.make_announce_data(actor, object, activity_id, public),
         {:ok, activity} <- insert(announce_data, local),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity, object}
    else
      error -> {:error, error}
    end
  end

  def unannounce(
        %{data: %{"id" => ap_id}} = actor,
        %Object{} = object,
        activity_id \\ nil,
        local \\ true
      ) do
    with %Object{} = announce_activity <- Utils.get_existing_announce(ap_id, object),
         unannounce_data <- Utils.make_unannounce_data(actor, announce_activity, activity_id),
         {:ok, unannounce_activity} <- insert(unannounce_data, local),
         :ok <- Utils.maybe_federate(unannounce_activity),
         {:ok, _activity} <- @repo.delete(announce_activity),
         :ok <- Adapter.maybe_handle_activity(unannounce_activity) do
      {:ok, unannounce_activity, object}
    else
      _e -> {:ok, object}
    end
  end

  def update(%{to: to, cc: cc, actor: actor, object: object} = params) do
    # only accept false as false value
    local = !(params[:local] == false)

    with data <- %{
           "to" => to,
           "cc" => cc,
           "type" => "Update",
           "actor" => actor,
           "object" => object
         },
         {:ok, activity} <- insert(data, local),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end

  def block(blocker, blocked, activity_id \\ nil, local \\ true) do
    follow_activity = Utils.fetch_latest_follow(blocker, blocked)
    if follow_activity, do: unfollow(blocker, blocked, nil, local)

    with block_data <- Utils.make_block_data(blocker, blocked, activity_id),
         {:ok, activity} <- insert(block_data, local),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    else
      _e -> {:ok, nil}
    end
  end

  def unblock(blocker, blocked, activity_id \\ nil, local \\ true) do
    with block_activity <- Utils.fetch_latest_block(blocker, blocked),
         unblock_data <- Utils.make_unblock_data(blocker, blocked, block_activity, activity_id),
         {:ok, activity} <- insert(unblock_data, local),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end

  def delete(object, local \\ true, delete_actor \\ nil)

  def delete(%{data: %{"id" => id, "type" => type}} = actor, local, delete_actor)
      when type in [
             "Person",
             "Application",
             "Service",
             "Organization",
             "Group",
             "MN:Community",
             "MN:Collection"
           ] do
    to = [actor.data["followers"]]

    with data <- %{
           "type" => "Delete",
           "actor" => delete_actor || id,
           "object" => id,
           "to" => to
         },
         {:ok, activity} <- insert(data, local),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end

  def delete(%Object{data: %{"id" => id, "actor" => actor}} = object, local, _delete_actor) do
    to = (object.data["to"] || []) ++ (object.data["cc"] || [])

    with {:ok, _object} <- Object.delete(object),
         data <- %{
           "type" => "Delete",
           "actor" => actor,
           "object" => id,
           "to" => to
         },
         {:ok, activity} <- insert(data, local),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end

  def flag(
        %{
          actor: actor,
          context: context,
          account: account,
          statuses: statuses,
          content: content
        } = params,
        pointer \\ nil
      ) do
    # only accept false as false value
    local = !(params[:local] == false)
    forward = !(params[:forward] == false)

    additional = params[:additional] || %{}

    params = %{
      actor: actor,
      context: context,
      account: account,
      statuses: statuses,
      content: content
    }

    additional =
      if forward do
        Map.merge(additional, %{"to" => [], "cc" => [account.data["id"]]})
      else
        Map.merge(additional, %{"to" => [], "cc" => []})
      end

    with flag_data <- Utils.make_flag_data(params, additional),
         {:ok, activity} <- insert(flag_data, local, pointer),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end
end
