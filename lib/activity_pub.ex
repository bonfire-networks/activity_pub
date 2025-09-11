defmodule ActivityPub do
  @moduledoc """
  #{"./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()}

  This module is the entrypoint to the ActivityPub API for processing incoming and outgoing federated objects (normalising, saving the the Object storage, passing them to the adapter, and queueing outgoing activities to be pushed out).

  In general, the functions in this module take object-like map.
  That includes a struct as the input for actor parameters.  Use the functions in the `ActivityPub.Actor` module (`ActivityPub.Actor.get_cached/1` for example) to retrieve those.
  """
  use Arrows
  import Untangle
  require ActivityPub.Config

  alias ActivityPub.Utils
  alias ActivityPub.Config
  alias ActivityPub.Actor
  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Federator.Transformer
  # alias ActivityPub.Utils
  alias ActivityPub.Object
  # alias ActivityPub.MRF

  @doc """
  Enqueues an activity for federation if it's local
  """
  defp maybe_federate(object, opts \\ [])

  defp maybe_federate(%Object{local: true} = activity, opts) do
    # debug(opts, "maybe_federate oopts")

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
    debug(
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
           make_create_data(params) |> debug("create_data"),
         {:ok, activity} <-
           Object.insert(create_data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- maybe_federate(activity),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
      # Clear cache for the object we're replying to so its replies collection gets regenerated
      Transformer.maybe_invalidate_reply_to_cache(create_data["object"])

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
           Object.fetch_latest_activity(actor, object, "Follow") |> debug("latest") ||
             basic_follow_data(actor, object),
         unfollow_data <-
           make_unfollow_data(
             actor,
             object,
             follow_activity,
             Map.get(params, :activity_id)
           ),
         {:ok, activity} <-
           Object.insert(unfollow_data, Map.get(params, :local, true), Map.get(params, :pointer))
           |> debug("insert"),
         :ok <- maybe_federate(activity) |> debug("adapt"),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity) |> debug("incoming"),
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

  defp accept_activity(
         %{
           to: to,
           actor: actor,
           object: %Object{data: %{"type" => type} = activity_data} = activity_to_accept
         } = params
       ) do
    with actor_id <- actor.data["id"],
         {:ok, accepted_activity} <- Object.update_state(activity_to_accept, type, "accept"),
         data <- %{
           "id" => params[:activity_id] || Object.object_url(Map.get(params, :pointer)),
           "to" => to,
           "type" => "Accept",
           "actor" => actor_id,
           "object" => accepted_activity.data
         },
         # Check if this is a QuoteRequest and create QuoteAuthorization
         data <-
           if(type == "QuoteRequest",
             do:
               case params[:result] ||
                      (params[:local] && quote_authorization(actor, activity_data)) do
                 id when is_binary(id) ->
                   Map.put(data, "result", id)
                   |> debug("added provided quote auth from params or local")

                 {:ok, %{data: %{"id" => id}}} ->
                   Map.put(data, "result", id)
                   |> debug("added found or created quote auth from params or local")

                 e ->
                   err(e, "Error finding or creating QuoteAuthorization")
                   nil
               end
           ) || data,
         {:ok, accept_activity} <-
           Object.insert(data, Map.get(params, :local, true), Map.get(params, :pointer)),
         :ok <- maybe_federate(accept_activity),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(accept_activity) do
      {:ok, accept_activity, adapter_object, accepted_activity}
    end
  end

  defp accept_activity(%{object: activity_to_accept} = params) do
    with %Object{} = activity_to_accept <-
           Object.get_cached!(ap_id: activity_to_accept) do
      accept_activity(Map.put(params, :object, activity_to_accept))
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
           Object.get_cached!(ap_id: object) |> debug("activity_to_reject"),
         {:ok, activity} <-
           Object.insert(data, Map.get(params, :local, true), Map.get(params, :pointer))
           |> debug("inserted rejection on repo #{Utils.repo()}"),
         :ok <- maybe_federate(activity) |> debug("federated"),
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
             Map.get(params, :summary, nil),
             Map.get(params, :published, nil)
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
    follow_activity = Object.fetch_latest_activity(blocker, blocked, "Follow")

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

  def delete(object, is_local? \\ nil, opts \\ [])

  def delete(%{local: is_local?} = object, nil, []) do
    delete(object, is_local?, [])
  end

  def delete(%{local: is_local?} = object, opts, []) when is_list(opts) do
    delete(object, is_local?, opts)
  end

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
        %{data: %{"id" => id, "attributedTo" => actor}} = object,
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
         :ok <- maybe_federate(activity, opts) |> debug("maybe_federated"),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
      {:ok, activity}
    end
  end

  def delete(
        %{data: %{"id" => id, "actor" => actor} = data} = object,
        is_local?,
        opts
      ) do
    delete(
      %{object | data: data |> Map.put("attributedTo", actor)},
      is_local?,
      opts
    )
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
         summary \\ nil,
         published \\ nil
       )

  defp make_announce_data(
         %{data: %{"id" => ap_id}} = actor,
         %Object{data: %{"id" => id}} = object,
         activity_id,
         false,
         summary,
         published
       ) do
    data = %{
      "type" => "Announce",
      "actor" => ap_id,
      "object" => id,
      "to" => [actor.data["followers"]],
      "cc" => [],
      "context" => object.data["context"],
      "summary" => summary,
      "published" => published || Utils.make_date()
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  defp make_announce_data(
         %{data: %{"id" => ap_id}} = actor,
         %Object{data: %{"id" => id}} = object,
         activity_id,
         true,
         summary,
         published
       ) do
    data = %{
      "type" => "Announce",
      "actor" => ap_id,
      "object" => id,
      "to" => [actor.data["followers"], object.data["actor"]],
      "cc" => [ActivityPub.Config.public_uri()],
      "context" => object.data["context"],
      "summary" => summary,
      "published" => published || Utils.make_date()
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
    published = params[:published] || Utils.make_date()

    # Ensure the object also has the published date
    object =
      case params.object do
        %{} = obj -> Map.put_new(obj, "published", published)
        other -> other
      end

    Enum.into(params[:additional] || %{}, %{
      "type" => "Create",
      "to" => params.to,
      "actor" => params.actor.data["id"],
      "object" => object,
      "published" => published,
      "context" => params[:context]
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

  @doc """
  Generates and federates a QuoteRequest activity.
  """
  @spec quote_request(%{
          :actor => Actor.t(),
          :object => Actor.t() | Object.t(),
          :instrument => map(),
          optional(atom()) => any()
        }) ::
          {:ok, Object.t()} | {:error, any()}
  def quote_request(%{actor: actor, object: object, instrument: instrument} = params) do
    with quote_request_data <-
           make_quote_request_data(actor, object, instrument, Map.get(params, :activity_id)),
         {:ok, activity} <-
           Object.insert(
             quote_request_data,
             Map.get(params, :local, true),
             Map.get(params, :pointer),
             true
           )
           |> debug("inserted quote request"),
         :ok <- maybe_federate(activity) |> debug("federated quote request"),
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
      {:ok, activity}
    end
  end

  defp make_quote_request_data(
         %{data: %{"id" => actor_id}} = _actor,
         object,
         instrument,
         activity_id
       ) do
    object_id = extract_object_id(object)

    object_actor =
      case object do
        %{data: %{"attributedTo" => id}} -> id
        %{"attributedTo" => id} -> id
        %{data: %{"actor" => id}} -> id
        %{"actor" => id} -> id
        _ -> nil
      end

    instrument_data =
      case instrument do
        %{data: data} -> data
        # data when is_map(data) -> data
        other -> other
      end

    data = %{
      "type" => "QuoteRequest",
      "actor" => actor_id,
      "to" => [object_actor],
      "object" => object_id,
      "instrument" => instrument_data
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  def quote_authorization(
        actor,
        %{"type" => "QuoteRequest", "object" => quoted_object, "instrument" => instrument} =
          _quote_request_activity_data
      ) do
    quote_authorization(actor, quoted_object, instrument)
  end

  def quote_authorization(_actor, _activity_data) do
    error("Invalid activity data for quote authorization")
  end

  def quote_authorization(actor, quoted_object, quote_object) do
    quote_post_ap_id = extract_object_id(quote_object)
    quoted_object_id = extract_object_id(quoted_object)

    if quote_post_ap_id && quoted_object_id do
      activity_id =
        "#{quoted_object_id}_authorization_#{Utils.hash(quote_post_ap_id)}"
        |> debug("quote authorization activity_id")

      # Check if authorization already exists
      case Object.get_cached(ap_id: activity_id) do
        {:ok, existing_auth} ->
          debug(existing_auth, "Existing quote authorization found")
          {:ok, existing_auth}

        {:error, :not_found} ->
          debug("Create new authorization")

          authorize_quote(%{
            actor: actor,
            quote_post_ap_id: quote_post_ap_id,
            quoted_object_ap_id: quoted_object_id,
            activity_id: activity_id
          })
      end
    else
      err("Invalid object IDs for quote authorization")
    end
  end

  @doc """
  Generates a QuoteAuthorization stamp for an approved quote post.
  """
  @spec authorize_quote(%{
          :actor => Actor.t(),
          :quote_post_ap_id => binary(),
          :quoted_object_ap_id => binary(),
          optional(atom()) => any()
        }) ::
          {:ok, Object.t()} | {:error, any()}
  def authorize_quote(
        %{
          actor: actor,
          quote_post_ap_id: quote_post_ap_id,
          quoted_object_ap_id: quoted_object_ap_id
        } = params
      ) do
    with authorization_data <-
           make_quote_authorization_data(
             actor,
             quote_post_ap_id,
             quoted_object_ap_id,
             Map.get(params, :activity_id)
           )
           |> debug("authorization_data"),
         {:ok, authorization} <-
           Object.insert(
             authorization_data,
             Map.get(params, :local, true),
             Map.get(params, :pointer)
           )
           |> debug("inserted quote authorization") do
      {:ok, authorization}
    end
  end

  defp make_quote_authorization_data(
         %{data: %{"id" => actor_id}} = _actor,
         quote_post_ap_id,
         quoted_object_ap_id,
         activity_id
       ) do
    data = %{
      "type" => "QuoteAuthorization",
      "attributedTo" => actor_id,
      "interactingObject" => quote_post_ap_id,
      "interactionTarget" => quoted_object_ap_id
    }

    if activity_id, do: Map.put(data, "id", activity_id), else: data
  end

  #  TODO: put somewhere better
  defp extract_object_id(object) do
    case object do
      %{data: %{"id" => id}} -> id
      %{"id" => id} -> id
      %{ap_id: id} -> id
      other when is_binary(other) -> other
    end
  end
end
