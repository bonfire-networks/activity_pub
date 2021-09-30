defmodule ActivityPub.Adapter do
  @moduledoc """
  Contract for ActivityPub module adapters
  """

  alias ActivityPub.Actor
  alias ActivityPub.Object

  defp adapter,
    do: Application.get_env(:activity_pub, :adapter) || ActivityPub.Common.adapter_fallback()

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
  @callback get_actor_by_username(String.t()) :: {:ok, Actor.t()} | {:error, any()}
  def get_actor_by_username(username) do
    validate_actor(adapter().get_actor_by_username(username))
  end

  @callback get_actor_by_id(String.t()) :: {:ok, Actor.t()} | {:error, any()}
  def get_actor_by_id(id) do
    validate_actor(adapter().get_actor_by_id(id))
  end

  @callback maybe_create_remote_actor(Actor.t()) :: :ok
  def maybe_create_remote_actor(actor) do
    adapter().maybe_create_remote_actor(actor)
  end

  @callback update_local_actor(Actor.t(), Map.t()) :: {:ok, Actor.t()} | {:error, any()}
  def update_local_actor(actor, params) do
    adapter().update_local_actor(actor, params)
  end

  @callback update_remote_actor(Object.t()) :: :ok | {:error, any()}
  def update_remote_actor(actor) do
    adapter().update_remote_actor(actor)
  end

  @doc """
  Passes data to be handled by the host application
  """
  @callback handle_activity(Object.t()) :: :ok | {:ok, any()} | {:error, any()}
  def handle_activity(activity) do
    adapter().handle_activity(activity)
  end

  @callback get_follower_local_ids(Actor.t()) :: [String.t()]
  def get_follower_local_ids(actor) do
    adapter().get_follower_local_ids(actor)
  end

  @callback get_following_local_ids(Actor.t()) :: [String.t()]
  def get_following_local_ids(actor) do
    adapter().get_following_local_ids(actor)
  end

  @callback base_url() :: String.t()
  def base_url() do
    adapter().base_url()
  end

  @doc """
  Gets local url of an AP object to redirect in browser. Can take pointer id or an actor username.
  """
  @callback get_redirect_url(String.t() | Map.t()) :: String.t()
  def get_redirect_url(id_or_username_or_object) do
    adapter().get_redirect_url(id_or_username_or_object)
  end

  # FIXME: implicity returning `:ok` here means we don't know if the worker fails which isn't great
  def maybe_handle_activity(%Object{local: false} = activity) do
    handle_activity(activity)
    :ok
  end

  def maybe_handle_activity(_), do: :ok
end
