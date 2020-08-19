defmodule ActivityPub.Adapter do
  @moduledoc """
  Contract for ActivityPub module adapters
  """

  alias ActivityPub.Actor
  alias ActivityPub.Object

  @adapter Application.get_env(:activity_pub, :adapter)

  defp validate_actor({:ok, %Actor{local: false} = actor}) do
    actor_object = Object.get_cached_by_pointer_id(actor.id)
    {:ok, Actor.format_remote_actor(actor_object)}
  end

  defp validate_actor({:ok, %Actor{} = actor}), do: {:ok, actor}
  defp validate_actor({:ok, _}), do: {:error, "Improperly formatted actor struct"}
  defp validate_actor(_), do: {:error, "not found"}

  @doc """
  Fetch an actor given its preferred username
  """
  @callback get_actor_by_username(String.t()) :: {:ok, any()} | {:error, any()}
  def get_actor_by_username(username), do: validate_actor(@adapter.get_actor_by_username(username))

  @callback get_actor_by_id(String.t()) :: {:ok, any()} | {:error, any()}
  def get_actor_by_id(id), do: validate_actor(@adapter.get_actor_by_id(id))

  @callback maybe_create_remote_actor(Actor.t()) :: :ok
  defdelegate maybe_create_remote_actor(actor), to: @adapter

  @callback update_local_actor(Actor.t(), Map.t()) :: {:ok, any()} | {:error, any()}
  defdelegate update_local_actor(actor, params), to: @adapter

  @callback update_remote_actor(Object.t()) :: :ok | {:error, any()}
  defdelegate update_remote_actor(actor), to: @adapter

  @doc """
  Passes data to be handled by the host application
  """
  @callback handle_activity(Object.t()) :: :ok | {:ok, any()} | {:error, any()}
  defdelegate handle_activity(activity), to: @adapter

  @callback get_follower_local_ids(Actor.t()) :: [String.t()]
  defdelegate get_follower_local_ids(actor), to: @adapter

  @callback get_following_local_ids(Actor.t()) :: [String.t()]
  defdelegate get_following_local_ids(actor), to: @adapter

  # FIXME: implicity returning `:ok` here means we don't know if the worker fails which isn't great
  def maybe_handle_activity(%Object{local: false} = activity) do
    handle_activity(activity)
    :ok
  end

  def maybe_handle_activity(_), do: :ok
end
