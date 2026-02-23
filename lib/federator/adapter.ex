defmodule ActivityPub.Federator.Adapter do
  @moduledoc """
  Contract for ActivityPub module adapters
  """
  import Untangle
  alias ActivityPub.Actor
  alias ActivityPub.Object

  def adapter,
    do:
      Application.get_env(:activity_pub, :adapter) ||
        ActivityPub.Utils.adapter_fallback()

  @doc """
  Run function from adapter if defined, otherwise return fallback value
  """
  def call_or(fun, args \\ [], fallback \\ nil) do
    if Kernel.function_exported?(adapter(), fun, length(args)) do
      apply(adapter(), fun, args)
    else
      fallback
    end
  end

  defp validate_actor({:ok, %Actor{local: false} = actor}) do
    {:ok, actor_object} = Object.get_cached(actor.id)
    {:ok, Actor.format_remote_actor(actor_object)}
  end

  defp validate_actor({:ok, %Actor{} = actor}), do: {:ok, actor}
  defp validate_actor(%Actor{} = actor), do: {:ok, actor}

  defp validate_actor({:ok, _}),
    do: {:error, "Improperly formatted actor struct"}

  defp validate_actor(_), do: {:error, :not_found}

  @doc """
  Fetch an `Actor` given its preferred username
  """
  @callback get_actor_by_username(Actor.username()) ::
              {:ok, Actor.t()} | {:error, any()}
  def get_actor_by_username(username) do
    # debug(self())
    validate_actor(adapter().get_actor_by_username(username))
  end

  @doc """
  Fetch an `Actor` by its full ActivityPub ID.
  """
  @callback get_actor_by_ap_id(Actor.ap_id()) :: {:ok, Actor.t()} | {:error, any()}
  def get_actor_by_ap_id(id) do
    validate_actor(adapter().get_actor_by_ap_id(id))
  end

  @doc """
  Fetch an `Actor` by its ID in the host application database.
  """
  @callback get_actor_by_id(String.t()) :: {:ok, Actor.t()} | {:error, any()}
  def get_actor_by_id(id) do
    validate_actor(adapter().get_actor_by_id(id))
  end

  @callback maybe_create_remote_actor(Actor.t()) :: :ok
  def maybe_create_remote_actor(actor) do
    adapter().maybe_create_remote_actor(actor)
  end

  @doc """
  Commit new fields to the host application database for the given `Actor`.
  """
  @callback update_local_actor(Actor.t(), Map.t()) ::
              {:ok, Actor.t()} | {:error, any()}
  def update_local_actor(actor, params) do
    adapter().update_local_actor(actor, params)
  end

  @callback update_remote_actor(Object.t()) :: :ok | {:error, any()}
  def update_remote_actor(actor) do
    adapter().update_remote_actor(actor)
  end

  def update_remote_actor(actor, data) do
    adapter().update_remote_actor(actor, data)
  end

  @doc """
  Passes data to be handled by the host application
  """
  @callback handle_activity(Object.t()) :: :ok | {:ok, any()} | {:error, any()}
  def handle_activity(activity) do
    adapter().handle_activity(activity)
  end

  def maybe_handle_activity(activity, opts \\ [])

  def maybe_handle_activity(%Object{local: false} = activity, _opts) do
    # remote activities should always go to adapter
    handle_activity(activity)
  end

  def maybe_handle_activity(%{data: %{"type" => verb}} = activity, _opts) when verb in ["Move"] do
    debug(verb, "looks like a local activity which we handle as incoming anyway")
    handle_activity(activity)
  end

  def maybe_handle_activity(%Object{local: true} = activity, opts) do
    if opts[:from_c2s] do
      # C2S activities should go to adapter
      handle_activity(activity)
    else
      # Regular local activities skip adapter (they originated from there)
      {:ok, :local}
    end
  end

  def maybe_handle_activity(activity, _opts) do
    error(activity, "unrecognized activity structure")
  end

  @doc """
  Get the host application IDs for all `Actor`s following the given `Actor`.
  """
  @callback get_follower_local_ids(Actor.t(), boolean()) :: [Actor.id()]
  def get_follower_local_ids(actor, purpose_or_current_actor \\ nil) do
    adapter().get_follower_local_ids(actor, purpose_or_current_actor)
  end

  @doc """
  Get the host application IDs for all `Actor`s that the given `Actor` is following.
  """
  @callback get_following_local_ids(Actor.t(), boolean()) :: [Actor.id()]
  def get_following_local_ids(actor, purpose_or_current_actor \\ nil) do
    adapter().get_following_local_ids(actor, purpose_or_current_actor)
  end

  @doc """
  The base URL of the application serving `ActivityPub.Web.Endpoint`.
  """
  @callback base_url() :: String.t()
  def base_url() do
    adapter().base_url()
  end

  @callback maybe_publish_object(String.t(), Keyword.t()) :: {:ok, any()} | {:error, any()}
  def maybe_publish_object(object, opts \\ []) do
    adapter().maybe_publish_object(object, opts)
  end

  @doc """
  Gets local url of an AP object to redirect in browser. Can take pointer id or an actor username.
  """
  @callback get_redirect_url(Actor.username() | Map.t()) :: String.t()
  def get_redirect_url(id_or_username_or_object) do
    adapter().get_redirect_url(id_or_username_or_object)
  end

  @doc """
  Creates an internal service actor by username, if missing.

  # TODO: make the application actor discoverable with https://codeberg.org/fediverse/fep/src/branch/main/fep/d556/fep-d556.md and https://codeberg.org/fediverse/fep/src/branch/main/fep/2677/fep-2677.md
  """
  @callback get_or_create_service_actor() :: Actor.t() | nil
  def get_or_create_service_actor() do
    adapter().get_or_create_service_actor()
  end

  @doc """
  Compute and return a subset of followers that should receive a specific activity (optional).
  Accepts an optional `addressed_pointer_ids` list to exclude already-addressed recipients from lookups.
  """
  @callback external_followers_for_activity(List.t(), Map.t()) :: List.t()
  @callback external_followers_for_activity(List.t(), Map.t(), list()) :: List.t()
  def external_followers_for_activity(actor, activity, addressed_pointer_ids \\ []) do
    adapter = adapter()

    cond do
      function_exported?(adapter, :external_followers_for_activity, 3) ->
        adapter.external_followers_for_activity(actor, activity, addressed_pointer_ids)

      function_exported?(adapter, :external_followers_for_activity, 2) ->
        adapter.external_followers_for_activity(actor, activity)

      true ->
        {:ok, []}
    end
  end

  @doc """
  Get the default locale of the host application.
  """
  @callback get_locale() :: String.t()
  def get_locale() do
    to_string(
      adapter().get_locale() || Application.get_env(:activity_pub, :default_language, "und")
    )
  end

  @doc """
  Whether this (local or remote) actor has federation enabled and/or is blocked on this instance

  actor: the actor to check (eg. Alice)
  direction: :in or :out - whether we're dealing with incoming federation or outgoing (optional)
  by_actor: optionally another actor (eg. if Alice is sending something to Bob, this would be Bob) 
  """
  def federate_actor?(
        actor,
        direction \\ nil,
        by_actor \\ nil
      ) do
    adapter().federate_actor?(actor, direction, by_actor)
  end

  def transform_outgoing(data, target_host \\ nil, target_actor_ids \\ nil) do
    if function_exported?(adapter(), :transform_outgoing, 3) do
      adapter().transform_outgoing(data, target_host, target_actor_ids)
    else
      data
    end
  end

  @doc """
  Captures multi-tenancy context from the current process for propagation into other processes (e.g. Cachex workers, Oban jobs).
  Returns an opaque map that can be passed to `set_multi_tenant_context/1`.
  """
  @callback get_multi_tenant_context() :: map()
  def get_multi_tenant_context() do
    if function_exported?(adapter(), :get_multi_tenant_context, 0) do
      adapter().get_multi_tenant_context()
    else
      %{
        tesla_mock: ProcessTree.get(Tesla.Mock)
      }
    end
  end

  @doc """
  Restores multi-tenancy context (captured by `get_multi_tenant_context/0`) into the current process.
  """
  @callback set_multi_tenant_context(term()) :: any()
  def set_multi_tenant_context(context) do
    if function_exported?(adapter(), :set_multi_tenant_context, 1) do
      adapter().set_multi_tenant_context(context)
    else
      if is_map(context) and is_function(context[:tesla_mock]) do
        Process.put(Tesla.Mock, context[:tesla_mock])
      end
    end
  end

  @optional_callbacks external_followers_for_activity: 2,
                      external_followers_for_activity: 3,
                      get_multi_tenant_context: 0,
                      set_multi_tenant_context: 1
end
