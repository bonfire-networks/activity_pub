defmodule ActivityPub do
  @moduledoc """
  #{"./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()}

  This module is the entrypoint to the ActivityPub API for processing incoming and outgoing federated objects (normalising, saving the the Object storage, passing them to the adapter, and queueing outgoing activities to be pushed out).

  In general, the functions in this module take object-like map.
  That includes a struct as the input for actor parameters.  Use the functions in the `ActivityPub.Actor` module (`ActivityPub.Actor.get_cached/1` for example) to retrieve those.
  """
  import Untangle
  require ActivityPub.Config

  alias ActivityPub.Utils
  alias ActivityPub.Config
  alias ActivityPub.Actor
  alias ActivityPub.Federator.Adapter
  # alias ActivityPub.Utils
  alias ActivityPub.Object
  # alias ActivityPub.MRF

  @doc """
  Enqueues an activity for federation if it's local
  """
  defp maybe_federate(object, opts \\ [])

  defp maybe_federate(%Object{local: true} = activity, opts) do
    debug(opts, "oopts")

    if Config.federating?() do
      with {:ok, job} <- ActivityPub.Federator.publish(activity, opts) do
        if job.state == "completed" do
          info(
            job,
            "ActivityPub outgoing federation has been completed"
          )
        else
          info(
            job,
            "ActivityPub outgoing federation has been queued"
          )
        end

        :ok
      end
    else
      warn(
        "ActivityPub outgoing federation is disabled, skipping (change `:activity_pub, :instance, :federating` to `true` in config to enable)"
      )

      :ok
    end
  end

  defp maybe_federate(object, _) do
    warn(
      object,
      "Skip outgoing federation of non-local object"
    )

    :ok
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
  def create(%{to: _, actor: _, object: _} = params) do
    with nil <- Object.normalize(params[:additional]["id"], false),
         create_data <-
           make_create_data(params) |> debug(),
         {:ok, activity} <-
           Object.insert(create_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- maybe_federate(activity),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
      {:ok, activity}
    else
      {:ok, %Object{} = object} -> {:ok, object}
      %Object{} = object -> {:ok, object}
      {:error, error} when is_binary(error) -> error(error)
      :ignore -> :ignore
      other -> error(other, "Error with the Create Activity")
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
    with data <- make_follow_data(follower, followed, Map.get(params, :activity_id)),
         {:ok, activity} <-
           Object.insert(data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- maybe_federate(activity),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         {:ok, activity} <- Object.get_cached(ap_id: activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
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
           Object.fetch_latest_follow(actor, object) || basic_follow_data(actor, object),
         unfollow_data <-
           make_unfollow_data(
             actor,
             object,
             follow_activity,
             Map.get(params, :activity_id)
           ),
         {:ok, activity} <-
           Object.insert(unfollow_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- maybe_federate(activity),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
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
  def accept(params) do
    with {:ok, accept_activity, adapter_object, _accepted_activity} <- accept_activity(params) do
      {:ok, Map.put(accept_activity, :pointer, adapter_object)}
    end
  end

  def accept_activity(%{to: to, actor: actor, object: activity_to_accept_id} = params) do
    with actor_id <- actor.data["id"],
         %Object{data: %{"type" => type}} = activity_to_accept <-
           Object.get_cached!(ap_id: activity_to_accept_id),
         {:ok, accepted_activity} <- Object.update_state(activity_to_accept, type, "accept"),
         data <- %{
           "id" => params[:activity_id] || Object.object_url(Map.get(params, :pointer)),
           "to" => to,
           "type" => "Accept",
           "actor" => actor_id,
           "object" => accepted_activity.data
         },
         {:ok, accept_activity} <-
           Object.insert(data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- maybe_federate(accept_activity),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(accept_activity) do
      {:ok, accept_activity, adapter_object, accepted_activity}
    end
  end

  @doc """
  Generates and federates a Reject activity via the data passed through `params`.
  """
  @spec reject(%{to: [any()], actor: Actor.t(), object: binary()}) ::
          {:ok, Object.t()} | {:error, any()}
  def reject(%{to: to, actor: actor, object: object} = params) do
    with data <- %{
           "id" => params[:activity_id] || Object.object_url(Map.get(params, :pointer)),
           "to" => to,
           "type" => "Reject",
           "actor" => actor.data["id"],
           "object" => object
         },
         %Object{data: %{"type" => type}} = activity_to_reject <-
           Object.get_cached!(ap_id: object),
         {:ok, activity} <-
           Object.insert(data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- maybe_federate(activity),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity) |> debug("handled"),
         {:ok, _rejected_activity} <-
           Object.update_state(activity_to_reject, type, "reject") |> debug("rejected_activity"),
         #  {:ok, activity} <- Object.get_cached(ap_id: activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
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
  def like(
        %{
          actor: %{data: %{"id" => ap_id}} = actor,
          object: %Object{data: %{"id" => object_id}} = object
        } = params
      ) do
    with nil <- Object.get_existing_like(ap_id, object_id),
         like_data <- make_like_data(actor, object, Map.get(params, :activity_id)),
         {:ok, activity} <-
           Object.insert(like_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- maybe_federate(activity),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
      {:ok, activity}
    else
      {:ok, %Object{} = object} -> {:ok, object}
      %Object{} = object -> {:ok, object}
      error -> error(error)
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
  def unlike(
        %{
          actor: %{data: %{"id" => ap_id}} = actor,
          object: %Object{data: %{"id" => object_id}} = _object
        } = params
      ) do
    with %Object{} = like_activity <- Object.get_existing_like(ap_id, object_id) |> info(),
         unlike_data <-
           make_unlike_data(actor, like_activity, Map.get(params, :activity_id)),
         {:ok, activity} <-
           Object.insert(unlike_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         {:ok, _activity} <- Object.hard_delete(like_activity),
         :ok <- maybe_federate(activity),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
      {:ok, activity}
    else
      error -> error(error)
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
        } = params
      ) do
    with true <- Utils.public?(object.data),
         announce_data <-
           make_announce_data(
             actor,
             object,
             Map.get(params, :activity_id),
             Map.get(params, :public, true),
             Map.get(params, :summary, nil)
           ),
         {:ok, activity} <-
           Object.insert(announce_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- maybe_federate(activity),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
      {:ok, activity}
    else
      {:ok, %Object{} = object} -> {:ok, object}
      %Object{} = object -> {:ok, object}
      error -> error(error)
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
        } = params
      ) do
    with %Object{} = announce_activity <-
           Object.get_existing_announce(ap_id, object),
         unannounce_data <-
           make_unannounce_data(actor, announce_activity, Map.get(params, :activity_id)),
         {:ok, activity} <-
           Object.insert(
             unannounce_data,
             Map.get(params, :local, true),
             Map.get(params, :pointer)
           ),
         :ok <- maybe_federate(activity),
         {:ok, _activity} <- Object.hard_delete(announce_activity) |> info("deleted?"),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
      {:ok, activity}
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
  def update(%{to: to, actor: actor, object: object} = params) do
    additional = params[:additional] || %{}

    with activity_data <-
           Map.merge(
             %{
               "id" => params[:id] || params[:activity_id] || Utils.generate_object_id(),
               "to" => to,
               "type" => "Update",
               "actor" => Map.get(actor, :data, actor)["id"],
               "object" =>
                 object
                 |> Map.put_new_lazy("id", fn ->
                   Map.get(params, :pointer) |> Object.object_url()
                 end)
             },
             additional
           ),
         {:ok, activity} <-
           Object.insert(
             activity_data,
             Map.get(params, :local, true),
             Map.get(params, :pointer),
             :update
           ),
         :ok <- maybe_federate(activity),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
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
    follow_activity = Object.fetch_latest_follow(blocker, blocked)

    if follow_activity,
      do: unfollow(%{actor: blocker, object: blocked, local: Map.get(params, :local, true)})

    with block_data <- make_block_data(blocker, blocked, Map.get(params, :activity_id)),
         {:ok, activity} <-
           Object.insert(block_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- maybe_federate(activity),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
      {:ok, activity}
    else
      {:ok, %Object{} = object} -> {:ok, object}
      %Object{} = object -> {:ok, object}
      error -> error(error)
    end
  end

  # @spec unblock(
  #         blocker :: Actor.t(),
  #         blocked :: Actor.t(),
  #         activity_id :: binary() | nil,
  #         local :: boolean
  #       ) :: {:ok, Object.t()} | {:error, any()}
  def unblock(%{actor: blocker, object: blocked} = params) do
    with block_activity <- Object.fetch_latest_block(blocker, blocked),
         unblock_data <-
           make_unblock_data(
             blocker,
             blocked,
             block_activity,
             Map.get(params, :activity_id)
           ),
         {:ok, activity} <-
           Object.insert(unblock_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- maybe_federate(activity),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
      {:ok, activity}
    end
  end

  def delete(object, is_local?, opts \\ [])

  def delete(
        %{data: %{"id" => id, "type" => type}} = delete_actor,
        is_local?,
        opts
      )
      when ActivityPub.Config.is_in(type, :supported_actor_types) do
    subject = opts[:subject]

    to = [
      delete_actor.data["followers"],
      if(is_map(subject), do: Map.get(subject, :data, %{})["followers"], else: nil),
      ActivityPub.Config.public_uri()
    ]

    with {:ok, _} <-
           delete_actor
           |> debug("actor")
           |> Actor.delete(is_local?)
           |> debug("deleeeted"),
         params <-
           %{
             "type" => "Delete",
             "actor" => subject || id,
             "object" => id,
             "to" => to,
             "bcc" => opts[:bcc]
           }
           |> debug("delete params"),
         {:ok, activity} <- Object.insert(params, is_local?),
         :ok <- maybe_federate(activity, opts),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
      {:ok, activity}
    end
  end

  def delete(
        %{data: %{"id" => _id, "formerType" => type}} = delete_actor,
        is_local?,
        opts
      )
      when ActivityPub.Config.is_in(type, :supported_actor_types) do
    delete(
      Map.update(delete_actor, :data, %{}, fn data -> Map.merge(data, %{"type" => type}) end),
      is_local?,
      opts
    )
  end

  def delete(
        %Object{data: %{"id" => id, "actor" => actor}} = object,
        is_local?,
        opts
      ) do
    to =
      (object.data["to"] || []) ++ (object.data["cc"] || []) ++ [ActivityPub.Config.public_uri()]

    with {:ok, _object} <- Object.delete(object) |> debug("dellll"),
         data <- %{
           "type" => "Delete",
           "actor" => opts[:subject] || actor,
           "object" => id,
           "to" => to,
           "bcc" => opts[:bcc]
         },
         {:ok, activity} <- Object.insert(data, is_local?),
         :ok <- maybe_federate(activity, opts),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
      {:ok, activity}
    end
  end

  # Not sure about the types here
  @spec flag(%{
          :actor => Actor.t(),
          :context => binary(),
          :account => Actor.t(),
          :statuses => [any()],
          :content => binary(),
          optional(atom()) => any()
        }) :: {:ok, Object.t()} | {:error, any()}
  def flag(%{} = params) do
    additional = params[:additional] || %{}

    additional =
      if is_map(params[:account]) and params[:forward] == true do
        Map.merge(additional, %{"to" => [], "bcc" => [params[:account].data["id"]]})
      else
        Map.merge(additional, %{"to" => [], "cc" => []})
      end

    with {:ok, activity} <-
           make_flag_data(params, [params[:account]] ++ (params[:statuses] || []), additional)
           |> Object.insert(Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- maybe_federate(activity),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
      {:ok, activity}
    end
  end

  @spec move(Actor.t(), Actor.t(), boolean()) :: {:ok, Object.t()} | {:error, any()}
  def move(
        %{ap_id: origin_ap_id, data: origin_data} = _origin,
        %{ap_id: _} = target,
        local \\ true,
        recursing \\ false
      ) do
    params = %{
      "type" => "Move",
      "actor" => origin_ap_id,
      "object" => origin_ap_id,
      "target" => target.ap_id,
      "to" => Map.get(origin_data, "followers", [])
    }

    with true <- Actor.also_known_as?(origin_ap_id, target.data),
         {:ok, activity} <- Object.insert(params, local),
         :ok <- maybe_federate(activity),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
      {:ok, activity}
    else
      false ->
        if recursing != true do
          debug("fetch a fresh actor in case they just added alsoKnownAs")

          with {:ok, refetched} <-
                 ActivityPub.Federator.Fetcher.fetch_fresh_object_from_id(target.ap_id) do
            move(%{ap_id: origin_ap_id, data: origin_data}, refetched, local, true)
          end
        else
          error("Target account must have the origin in `alsoKnownAs`")
          {:error, :not_in_also_known_as}
        end

      err ->
        err
    end
  end

  defp make_like_data(
         %{data: %{"id" => ap_id}} = actor,
         %{data: %{"id" => id}} = object,
         activity_id
       ) do
    object_actor_id = ActivityPub.Object.actor_from_data(object.data)

    object_actor_followers =
      with {:ok, object_actor} <- Actor.get_cached(ap_id: object_actor_id) do
        object_actor.data["followers"]
      else
        e ->
          warn(e)
          nil
      end

    to =
      if Utils.public?(object.data) do
        [actor.data["followers"], object.data["actor"]]
      else
        [object.data["actor"]]
      end

    cc =
      ((object.data["to"] || []) ++ (object.data["cc"] || []))
      |> List.delete(ap_id)
      |> List.delete(object_actor_followers)

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

  defp make_unlike_data(
         %{data: %{"id" => ap_id}} = actor,
         %{data: %{"context" => context}} = activity,
         activity_id
       ) do
    data = %{
      "type" => "Undo",
      "actor" => ap_id,
      "object" => activity.data,
      "to" => [actor.data["followers"], activity.data["actor"]],
      "cc" => [ActivityPub.Config.public_uri()],
      "context" => context
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  @doc """
  Make announce activity data for the given actor and object
  """
  # for relayed messages, we only want to send to subscribers
  defp make_announce_data(
         actor,
         object,
         activity_id,
         public?,
         summary \\ nil
       )

  defp make_announce_data(
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

  defp make_announce_data(
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
      "cc" => [ActivityPub.Config.public_uri()],
      "context" => object.data["context"],
      "summary" => summary
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  @doc """
  Make unannounce activity data for the given actor and object
  """
  defp make_unannounce_data(
         %{data: %{"id" => ap_id}} = actor,
         %Object{data: %{"context" => context}} = activity,
         activity_id
       ) do
    data = %{
      "type" => "Undo",
      "actor" => ap_id,
      "object" => activity.data,
      "to" => [actor.data["followers"], activity.data["actor"]],
      "cc" => [ActivityPub.Config.public_uri()],
      "context" => context
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  #### Follow-related helpers
  defp make_follow_data(
         %{data: %{"id" => follower_id}},
         %{data: %{"id" => followed_id}} = _followed,
         activity_id
       ) do
    data =
      basic_follow_data(follower_id, followed_id)
      |> Map.put("state", "pending")

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  defp make_unfollow_data(
         %{data: %{"id" => follower_id}},
         %{data: %{"id" => followed_id}},
         follow_activity,
         activity_id
       ) do
    data = %{
      "type" => "Undo",
      "actor" => follower_id,
      "to" => [followed_id],
      "object" => follow_activity.data
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  defp basic_follow_data(%{data: %{"id" => follower_id}}, %{data: %{"id" => followed_id}}) do
    basic_follow_data(follower_id, followed_id)
  end

  defp basic_follow_data(follower_id, followed_id) do
    %{
      "type" => "Follow",
      "actor" => follower_id,
      "to" => [followed_id],
      "cc" => [ActivityPub.Config.public_uri()],
      "object" => followed_id
    }
  end

  defp make_block_data(blocker, blocked, activity_id) do
    data = %{
      "type" => "Block",
      "actor" => blocker.data["id"],
      "to" => [blocked.data["id"]],
      "object" => blocked.data["id"]
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  defp make_unblock_data(blocker, blocked, block_activity, activity_id) do
    data = %{
      "type" => "Undo",
      "actor" => blocker.data["id"],
      "to" => [blocked.data["id"]],
      "object" => block_activity.data
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  #### Create-related helpers
  defp make_create_data(params) do
    Enum.into(params[:additional] || %{}, %{
      "type" => "Create",
      "to" => params.to,
      "actor" => params.actor.data["id"],
      "object" => params.object,
      "published" => params[:published] || Utils.make_date(),
      "context" => params.context
    })
  end

  #### Flag-related helpers
  defp make_flag_data(params, objects, additional) do
    objects =
      Enum.map(objects || [], fn
        %Actor{} = act ->
          act.data["id"]

        %Object{} = act ->
          act.data["id"]

        act when is_map(act) ->
          act["id"]

        act when is_binary(act) ->
          act

        other ->
          error(other, "dunno how to flag this")
          nil
      end)
      |> Enum.reject(&is_nil/1)

    data =
      %{
        "type" => "Flag",
        "actor" =>
          if(is_struct(params[:actor]),
            do: params[:actor].data["id"],
            else: params[:actor] || Utils.service_actor!()
          ),
        "content" => params[:content],
        "object" => objects,
        "context" => params[:context],
        "state" => "open"
      }
      |> Map.merge(additional)

    if params[:activity_id], do: Map.put(data, "id", params[:activity_id]), else: data

    # |> debug()
  end
end
