defmodule ActivityPub do
  @moduledoc """
  ActivityPub API

  In general, the functions in this module take object-like formatted struct as the input for actor parameters.
  Use the functions in the `ActivityPub.Actor` module (`ActivityPub.Actor.get_cached/1` for example) to retrieve those.
  """
  import Untangle
  alias ActivityPub.Actor
  alias ActivityPub.Adapter
  alias ActivityPub.Utils
  alias ActivityPub.Object
  alias ActivityPub.MRF
  import ActivityPub.Common

  @supported_actor_types ActivityPub.Utils.supported_actor_types()

  defp check_actor_is_active(actor) do
    if not is_nil(actor) do
      with {:ok, %{deactivated: true}} <- Actor.get_cached(ap_id: actor) do
        error(actor, "Actor deactivated")
          :reject
      else
        _ ->
          :ok
      end
    else
      :ok
    end
  end

  @doc false
  defp insert(map, local?, pointer \\ nil, upsert? \\ false)
      when is_map(map) and is_boolean(local?) do
    with activity_id <- Ecto.UUID.generate(),
        map <- Utils.normalize_actors(map),
         %{} = map <- Utils.lazy_put_activity_defaults(map, pointer || activity_id),
         :ok <- check_actor_is_active(map["actor"]),
         # set some healthy boundaries
         {:ok, map} <- MRF.filter(map, local?),
         # first insert the object
         {:ok, activity, object} <-
           Utils.insert_full_object(map, local?, pointer, upsert?),
         # then insert the activity (containing only an ID as object)
         # for activities without an object
         {:ok, activity} <-
           (if is_nil(object) do
            Object.insert(%{
              # activities without an object
                id: activity_id,
                data: activity,
                local: local?,
                public: Utils.public?(activity),
                pointer_id: pointer
              })
            else
              # activity containing only an ID as object
              Object.insert(%{
                id: activity_id,
                data: activity,
                local: local?,
                public: Utils.public?(activity, object)
              })
            end) do
      # Splice in the child object if we have one.
      activity =
        if !is_nil(object) do
          Map.put(activity, :object, object)
        else
          activity
        end

        info(activity, "inserted activity in #{repo()}")

      {:ok, activity}
    else
      %Object{} = object ->
        warn("error while trying to insert, return the object instead")
        {:ok, object}

      error ->
        error(error, "Error while trying to save the object for federation")
    end
  end

  @doc """
  Generates and federates a Create activity via the data passed through `params`.
  """
  @spec create(%{
          :to => [any()],
          :actor => Actor.t(),
          :context => binary(),
          :object => map(),
          optional(atom()) => any()
        }) ::
          {:ok, Object.t()} | {:error, any()}
  def create(
        %{to: to, actor: actor, context: context, object: object} = params
      ) do
    additional = params[:additional] || %{}

    with nil <- Object.normalize(additional["id"], false),
         create_data <-
           Utils.make_create_data(
             %{
               to: to,
               actor: actor,
               published: params[:published],
               context: context,
               object: object
             },
             additional
           ),
         {:ok, activity} <- insert(create_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    else
      %Object{} = activity -> {:ok, activity}
      {:error, message} -> {:error, message}
    end
  end


  @doc """
  Generates and federates a Follow activity.

  Note: the follow should be reflected as a Follow on the host database side only after receiving an `Accept` activity in response (though you could register it as a Request if your app has that concept)
  """
    # @spec follow(
    #       follower :: Actor.t(),
    #       follower :: Actor.t(),
    #       activity_id :: binary() | nil,
    #       local :: boolean()
    #     ) :: {:ok, Object.t()} | {:error, any()}
  def follow(%{actor: follower, object: followed} = params) do
    with data <- Utils.make_follow_data(follower, followed, Map.get(params, :activity_id)),
         {:ok, activity} <- insert(data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end


  @doc """
  Generates and federates an Unfollow activity.
  """
    # @spec unfollow(
    #       follower :: Actor.t(),
    #       follower :: Actor.t(),
    #       activity_id :: binary() | nil,
    #       local :: boolean()
    #     ) :: {:ok, Object.t()} | {:error, any()}
  def unfollow(%{actor: actor, object: object} = params) do
    with %Object{} = follow_activity <-
           Utils.fetch_latest_follow(actor, object),
         unfollow_data <-
           Utils.make_unfollow_data(
             actor, object,
             follow_activity,
             Map.get(params, :activity_id)
           ),
         {:ok, activity} <- insert(unfollow_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end

  @doc """
  Generates and federates an Accept activity via the data passed through `params`.
  """
  @spec accept(%{
          :to => [any()],
          :actor => Actor.t(),
          :object => map() | binary(),
          optional(atom()) => any()
        }) ::
          {:ok, Object.t()} | {:error, any()}
  def accept(%{to: to, actor: actor, object: object} = params) do
    with data <- %{
           "to" => to,
           "type" => "Accept",
           "actor" => actor.data["id"],
           "object" => object
         },
         {:ok, activity} <- insert(data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end

  @doc """
  Generates and federates a Reject activity via the data passed through `params`.
  """
  @spec reject(%{to: [any()], actor: Actor.t(), object: binary()}) ::
          {:ok, Object.t()} | {:error, any()}
  def reject(%{to: to, actor: actor, object: object} = params) do

    with data <- %{
           "to" => to,
           "type" => "Reject",
           "actor" => actor.data["id"],
           "object" => object
         },
         {:ok, activity} <- insert(data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end


  @doc """
  Record a Like
  """
    # @spec like(
    #       Actor.t(),
    #       Object.t(),
    #       activity_id :: binary() | nil,
    #       local :: boolean()
    #     ) ::
    #       {:ok, activity :: Object.t(), object :: Object.t()} | {:error, any()}
  def like(%{
       actor: %{data: %{"id" => ap_id}} = actor,
       object: %Object{data: %{"id" => _}} = object
     }=params ) do
    with nil <- Utils.get_existing_like(ap_id, object),
         like_data <- Utils.make_like_data(actor, object, Map.get(params, :activity_id)),
         {:ok, activity} <- insert(like_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity, object}
    else
      %Object{} = activity -> {:ok, activity, object}
      error -> {:error, error}
    end
  end

  # @spec unlike(
  #         Actor.t(),
  #         Object.t(),
  #         activity_id :: binary() | nil,
  #         local :: boolean()
  #       ) ::
  #         {:ok, unlike_activity :: Object.t(), like_activity :: Object.t(), object :: Object.t()}
  #         | {:error, any()}
  def unlike(%{
       actor: %{data: %{"id" => ap_id}} = actor,
       object: %Object{data: %{"id" => _}} = object
     }=params) do
    with %Object{} = like_activity <- Utils.get_existing_like(ap_id, object),
         unlike_data <-
           Utils.make_unlike_data(actor, like_activity, Map.get(params, :activity_id)),
         {:ok, unlike_activity} <- insert(unlike_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         {:ok, _activity} <- repo().delete(like_activity),
         :ok <- Utils.maybe_federate(unlike_activity),
         :ok <- Adapter.maybe_handle_activity(unlike_activity) do
      {:ok, unlike_activity, like_activity, object}
    else
      _e -> {:ok, object}
    end
  end


  # @spec announce(
  #         Actor.t(),
  #         Object.t(),
  #         activity_id :: binary() | nil,
  #         local :: boolean(),
  #         public :: boolean(),
  #         summary :: binary() | nil
  #       ) ::
  #         {:ok, activity :: Object.t(), object :: Object.t()} | {:error, any()}
  def announce(
    %{
       actor: %{data: %{"id" => _}} = actor,
       object: %Object{data: %{"id" => _}} = object
     }=params
      ) do
    with true <- Utils.public?(object.data),
         announce_data <-
           Utils.make_announce_data(actor, object, Map.get(params, :activity_id), Map.get(params, :public, true), Map.get(params, :summary, nil)),
         {:ok, activity} <- insert(announce_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity, object}
    else
      error -> {:error, error}
    end
  end

  # @spec unannounce(
  #         Actor.t(),
  #         Object.t(),
  #         activity_id :: binary() | nil,
  #         local :: boolean
  #       ) ::
  #         {:ok, unannounce_activity :: Object.t(), object :: Object.t()}
  #         | {:error, any()}
  def unannounce(
       %{
       actor: %{data: %{"id" => ap_id}} = actor,
       object: %Object{data: %{"id" => _}} = object
     }=params
      ) do
    with %Object{} = announce_activity <-
           Utils.get_existing_announce(ap_id, object),
         unannounce_data <-
           Utils.make_unannounce_data(actor, announce_activity, Map.get(params, :activity_id)),
         {:ok, unannounce_activity} <- insert(unannounce_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- Utils.maybe_federate(unannounce_activity),
         {:ok, _activity} <- repo().delete(announce_activity),
         :ok <- Adapter.maybe_handle_activity(unannounce_activity) do
      {:ok, unannounce_activity, object}
    else
      _e -> {:ok, object}
    end
  end

  # @spec update(%{
  #         :to => [any()],
  #         :cc => [any()],
  #         :actor => Actor.t(),
  #         :object => map(),
  #         optional(atom()) => any()
  #       }) ::
  #         {:ok, Object.t()} | {:error, any()}
  def update(%{to: to, cc: cc, actor: actor, object: object} = params) do
    with data <- %{
           "to" => to,
           "cc" => cc,
           "type" => "Update",
           "actor" => actor.data["id"],
           "object" => object
         },
         {:ok, activity} <- insert(data, Map.get(params, :local, true), Map.get(params, :pointer), true),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end

  # @spec block(
  #         blocker :: Actor.t(),
  #         blocked :: Actor.t(),
  #         activity_id :: binary() | nil,
  #         local :: boolean
  #       ) :: {:ok, Object.t()} | {:error, any()}
  def block(%{actor: blocker, object: blocked} = params) do
    follow_activity = Utils.fetch_latest_follow(blocker, blocked)
    if follow_activity, do: unfollow(%{actor: blocker, object: blocked, local: Map.get(params, :local, true)})

    with block_data <- Utils.make_block_data(blocker, blocked, Map.get(params, :activity_id)),
         {:ok, activity} <- insert(block_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    else
      _e -> {:ok, nil}
    end
  end

  # @spec unblock(
  #         blocker :: Actor.t(),
  #         blocked :: Actor.t(),
  #         activity_id :: binary() | nil,
  #         local :: boolean
  #       ) :: {:ok, Object.t()} | {:error, any()}
  def unblock(%{actor: blocker, object: blocked} = params) do
    with block_activity <- Utils.fetch_latest_block(blocker, blocked),
         unblock_data <-
           Utils.make_unblock_data(
             blocker,
             blocked,
             block_activity,
             Map.get(params, :activity_id)
           ),
         {:ok, activity} <- insert(unblock_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end

  def delete(object, local \\ true, delete_actor \\ nil)

  @spec delete(Actor.t(), local :: boolean(), delete_actor :: binary() | nil) ::
          {:ok, Object.t()} | {:error, any()}
  def delete(
        %{data: %{"id" => id, "type" => type}} = actor,
        local,
        delete_actor
      )
      when type in @supported_actor_types do
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

  @spec delete(Object.t(), local :: boolean(), delete_actor :: binary()) ::
          {:ok, Object.t()} | {:error, any()}
  def delete(
        %Object{data: %{"id" => id, "actor" => actor}} = object,
        local,
        _delete_actor
      ) do
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

  # Not 100% sure about the types here
  @spec flag(%{
          :actor => Actor.t(),
          :context => binary(),
          :account => Actor.t(),
          :statuses => [any()],
          :content => binary(),
          optional(atom()) => any()
        }) :: {:ok, Object.t()} | {:error, any()}
  def flag(
        %{
          actor: actor,
          context: context,
          account: account,
          statuses: statuses,
          content: content
        } = params
      ) do
    # only accept false as false value
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
         {:ok, activity} <- insert(flag_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- Utils.maybe_federate(activity),
         :ok <- Adapter.maybe_handle_activity(activity) do
      {:ok, activity}
    end
  end
end
