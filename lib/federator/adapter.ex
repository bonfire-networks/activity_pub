defmodule ActivityPub.Federator.Adapter do
  @moduledoc """
  Contract for ActivityPub module adapters
  """
  import Untangle
  import ActivityPub.Config
  alias ActivityPub.Actor
  alias ActivityPub.Object

  # When enabled (e.g. in `:test`), `federation_allowed?`/`federate_actor?` *also* apply the lib's
  # own config-based `SimplePolicy` (`:mrf_simple`) reject on top of the host adapter's decision.
  @also_apply_simple_policy Application.compile_env(
                              :activity_pub,
                              :also_apply_simple_policy,
                              false
                            )

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

  def maybe_handle_activity(%Object{local: false} = activity, opts) do
    if opts[:skip_adapter] == true do
      debug("skipping adapter for remote activity as requested")
      {:ok, :skipped}
    else
      # remote activities should always go to adapter
      handle_activity(activity)
    end
  end

  def maybe_handle_activity(%{data: %{"type" => verb}} = activity, opts)
      when is_in(verb, ["Move"]) do
    if opts[:skip_adapter] == true do
      debug("skipping adapter for remote activity as requested")
      {:ok, :skipped}
    else
      debug(verb, "looks like a local activity which we handle as incoming anyway")
      handle_activity(activity)
    end
  end

  def maybe_handle_activity(%Object{local: true} = activity, opts) do
    if opts[:from_c2s] do
      if opts[:skip_adapter] == true do
        debug("skipping adapter for remote activity as requested")
        {:ok, :skipped}
      else
        # C2S activities should go to adapter
        handle_activity(activity)
      end
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
  Read API for a collection's membership, returning a list of member **ap_ids (URIs)** (wire format).

  `collection` is a Collection `%Object{}`. When the host adapter implements `collection_items/2`
  it is used (so an extension that owns the data — e.g. a future Pins — supplies items without
  duplication); otherwise it falls back to the lib's `ActivityPub.GenericCollectionStore`.

  Note this is distinct from `get_follower_local_ids/2` / `get_following_local_ids/2`, which return
  local host *pointer ids* for delivery targeting — a different shape and purpose.

  The host adapter's `collection_items/2` only returns a list of items for collections **it** owns (e.g. a Pins extension serving `featured`); for any collection it doesn't own it returns nil, so this **defers per-collection** to the lib's `ActivityPub.GenericCollectionStore` fallback (eg. used by keyPackages). So an adapter implementing this never has to reimplement the store path.

  TODO: FEP-6606 — pass query-param filters (type=, maxItems=, after/before) through `opts`.
  """
  @callback collection_items(Object.t(), keyword()) :: [binary()] | nil
  def collection_items(collection, opts \\ []) do
    case function_exported?(adapter(), :collection_items, 2) &&
           adapter().collection_items(collection, opts) do
      items when is_list(items) -> items
      # adapter doesn't own this collection (nil/:default) → lib store fallback
      _ -> default_collection_items(collection, opts)
    end
  end

  # only a *persisted* Collection object (with an id) is store-backed; a synthesized envelope (no id)
  # that no adapter claimed means nobody owns it → `nil` (so serving can 404)
  defp default_collection_items(%Object{id: id} = collection, opts) when is_binary(id) do
    case opts[:return] do
      :ap_objects -> ActivityPub.GenericCollectionStore.member_objects(collection, opts)
      _ -> ActivityPub.GenericCollectionStore.member_ap_ids(collection, opts)
    end
  end

  defp default_collection_items(_collection, _opts), do: nil

  @doc """
  `totalItems` companion to `collection_items/2`: the host adapter returns an integer for a
  collection it owns, or `nil` to defer to the lib's `GenericCollectionStore.member_count/1`.
  """
  @callback collection_total(Object.t(), keyword()) :: non_neg_integer() | nil
  def collection_total(collection, opts \\ []) do
    case function_exported?(adapter(), :collection_total, 2) &&
           adapter().collection_total(collection, opts) do
      n when is_integer(n) -> n
      _ -> default_collection_total(collection)
    end
  end

  defp default_collection_total(%Object{} = collection),
    do: ActivityPub.GenericCollectionStore.member_count(collection)

  defp default_collection_total(_collection), do: 0

  @doc """
  Whether the host adapter has a handler registered for the given `query` — a cheap registry lookup
  (no fetching). `query` can be a verb/object type string, a `{verb, object_type}` tuple, a
  `{:collection, type}` tuple, etc. Lets the lib infer routing without querying members — e.g.
  store-backed collections are those *no* adapter handles (`not adapter_handles?({:collection, type})`).
  """
  @callback adapter_handles?(term()) :: boolean()
  def adapter_handles?(query), do: call_or(:adapter_handles?, [query], false) == true

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
    if function_exported?(adapter(), :federate_actor?, 3) do
      adapter_allows? = adapter().federate_actor?(actor, direction, by_actor)

      # when enabled (e.g. in `:test`), *also* apply the lib's own config-based `SimplePolicy` reject
      if @also_apply_simple_policy,
        do: adapter_allows? and simple_policy_allows?(ActivityPub.Utils.ap_id(actor)),
        else: adapter_allows?
    else
      # adapter doesn't implement `federate_actor?/3`: derive from `federation_allowed?/2`
      # (which already applies `SimplePolicy` itself, so no double-check here)
      actor
      |> ActivityPub.Utils.ap_id()
      |> federation_allowed?(direction: direction, by_actor: by_actor)
    end
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

  @doc """
  Checks whether federation with a given URI is allowed.
  Called before fetching remote objects/actors to prevent HTTP requests to disallowed hosts.
  Subsumes the config-based `SimplePolicy.check_reject/1` check.
  Return `true` to allow, `false` to deny.
  """
  @callback federation_allowed?(URI.t() | term(), opts :: keyword()) :: boolean()
  def federation_allowed?(uri, opts \\ []) do
    if function_exported?(adapter(), :federation_allowed?, 2) do
      adapter_allows? = adapter().federation_allowed?(uri, opts)

      # when enabled (e.g. in `:test`), *also* apply the lib's own config-based `SimplePolicy`
      # reject on top of the adapter's decision (whose gating doesn't include SimplePolicy)
      if @also_apply_simple_policy,
        do: adapter_allows? and simple_policy_allows?(uri),
        else: adapter_allows?
    else
      # adapter has no gating of its own: the lib's `SimplePolicy` is the only gate
      simple_policy_allows?(uri)
    end
  end

  defp simple_policy_allows?(subject) do
    # `SimplePolicy.check_reject/2` matches on a `%URI{}` (`%{host: ...}`), so normalise the subject
    # (URI, ap_id string, or actor/object struct) first; allow when no host can be determined
    case ActivityPub.Utils.ap_uri(subject) do
      %URI{host: host} = uri when is_binary(host) ->
        match?({:ok, _}, ActivityPub.MRF.SimplePolicy.check_reject(uri))

      _ ->
        true
    end
  end

  @optional_callbacks external_followers_for_activity: 2,
                      external_followers_for_activity: 3,
                      get_multi_tenant_context: 0,
                      set_multi_tenant_context: 1,
                      federation_allowed?: 2,
                      collection_items: 2,
                      collection_total: 2,
                      adapter_handles?: 1
end
