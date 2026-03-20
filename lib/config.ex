defmodule ActivityPub.Config do
  defmodule Error do
    defexception [:message]
  end

  import Untangle

  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  def public_uri, do: @public_uri

  def public_uris,
    do: [
      public_uri(),
      "as:Public",
      "Public",
      as_local_public()
    ]

  def as_local_public, do: ActivityPub.Web.base_url() <> "/#Public"

  def supported_actor_types,
    do:
      get([:instance, :supported_actor_types]) ||
        [
          "Person",
          "Application",
          "Service",
          "Organization",
          "Group"
        ]

  def supported_activity_types,
    do:
      get([:instance, :supported_activity_types]) ||
        [
          "Create",
          "Update",
          "Delete",
          "Follow",
          "Accept",
          "Reject",
          "Add",
          "Remove",
          "Like",
          "Announce",
          "Undo",
          "Arrive",
          "Block",
          "Flag",
          "Dislike",
          "Ignore",
          "Invite",
          "Join",
          "Leave",
          "Listen",
          "Move",
          "Offer",
          "Question",
          "Read",
          "TentativeReject",
          "TentativeAccept",
          "Travel",
          "View",
          "EmojiReact",
          "IntransitiveActivity"
        ]

  def supported_intransitive_types,
    do:
      get([:instance, :supported_intransitive_types]) ||
        [
          "IntransitiveActivity",
          "Arrive",
          "Travel",
          "Question"
        ]

  def known_object_fetchable_types,
    do:
      get([:instance, :known_object_fetchable_types]) ||
        [
          # standard AS objects:
          "Article",
          # "Audio",
          "Document",
          "Event",
          # "Image",
          "Note",
          "Page",
          "Place",
          "Profile",
          # "Relationship",
          "Tombstone"
          # "Video",
          # "Link",
          # "Mention",
        ]

  # ^ Note: should avoid using this since we want to support any object types, including ones not in ActivityStreams

  def known_object_extra_types,
    do:
      get([:instance, :known_object_extra_types]) ||
        [
          # standard AS objects:
          # "Article",
          "Audio",
          # "Document",
          # "Event",
          # "Image",
          # "Note",
          # "Page",
          # "Place",
          # "Profile",
          "Relationship",
          # "Tombstone",
          "Video",
          "Link",
          "Mention",
          # extras:
          "ChatMessage",
          "Location",
          "geojson:Feature"
        ]

  # ^ Note: should avoid using 

  def collection_types,
    do:
      get([:instance, :supported_collection_types]) ||
        [
          "Collection",
          "OrderedCollection",
          "CollectionPage",
          "OrderedCollectionPage"
        ]

  def actors_and_collections, do: supported_actor_types() ++ collection_types()

  @doc """
  For matching against the above list in guards 

  e.g.: `def handle_incoming(%{"type" => type} = data, opts) when is_in(type, :supported_actor_types)`

  or: `def handle_incoming(%{"type" => ["Object", "Video"]} = data, opts) when is_in(type, :known_object_extra_types)`

  TODO: use runtime config
  """
  defmacro is_in(types, fun_or_list) when is_list(types) do
    # handles a compile-time literal list as the first arg, e.g. is_in(["Create", "Update"], :supported_activity_types)
    in_list =
      if is_atom(fun_or_list), do: apply(ActivityPub.Config, fun_or_list, []), else: fun_or_list

    types
    |> Enum.map(fn type -> quote do: unquote(type) in unquote(in_list) end)
    |> Enum.reduce(fn check, acc -> quote do: unquote(acc) or unquote(check) end)
  end

  defmacro is_in(type, fun) when is_atom(fun) do
    list = apply(ActivityPub.Config, fun, [])
    is_in_guard(type, list)
  end

  defmacro is_in(type, list) when is_list(list) do
    is_in_guard(type, list)
  end

  defp is_in_guard(type, list) do
    # handles list of types privided at runtime (only supports list of 1 or 2 types)
    quote do
      unquote(type) in unquote(list) or
        (is_list(unquote(type)) and
           (hd(unquote(type)) in unquote(list) or
              (length(unquote(type)) > 1 and hd(tl(unquote(type))) in unquote(list))))
    end
  end

  @doc "For matching a type or list of types against configured types (atom fun name) or an explicit list"
  def type_in?(types, fun) when is_list(types) and is_atom(fun) do
    config_list = apply(ActivityPub.Config, fun, [])
    Enum.any?(types, &(&1 in config_list))
  end

  def type_in?(types, list) when is_list(types) and is_list(list),
    do: Enum.any?(types, &(&1 in list))

  def type_in?(type, fun) when is_atom(fun),
    do: type in apply(ActivityPub.Config, fun, [])

  def type_in?(type, list) when is_list(list),
    do: type in list

  @doc """
  Checks if the given type (or any of list of types) is known, i.e. supported by the instance. Does not include collections.
  """
  def known_fetchable_type?(types) do
    config_types =
      supported_actor_types() ++ supported_activity_types() ++ known_object_fetchable_types()

    Enum.any?(List.wrap(types), fn type -> type_in?(type, config_types) end)
  end

  @compile_env Mix.env()
  def env, do: Application.get_env(:activity_pub, :env) || @compile_env

  def federating? do
    case (Application.get_env(:activity_pub, :instance) || %{})
         |> Map.new()
         |> Map.get(:federating, :not_set) do
      :not_set ->
        # this should be handled in test.exs or dev.exs and only here as a fallback
        (System.get_env("FEDERATE") == "yes" or
           (env() == :test and
              (Application.get_env(:tesla, :adapter) == Tesla.Mock or
                 System.get_env("TEST_INSTANCE") == "yes")))
        |> debug("auto-setting because not set")

      "true" ->
        true

      "false" ->
        false

      "manual" ->
        nil

      :manual ->
        nil

      val ->
        val
    end

    # |> debug()
  end

  def get(key), do: get(key, nil)

  def get([key], default), do: get(key, default)

  def get([parent_key | keys], default) do
    case :activity_pub
         |> Application.get_env(parent_key)
         |> get_in(keys) do
      nil -> default
      any -> any
    end
  end

  def get(key, default) do
    Application.get_env(:activity_pub, key, default)
  end

  def get!(key) do
    value = get(key, nil)

    if value == nil do
      raise(Error, message: "Missing configuration value: #{inspect(key)}")
    else
      value
    end
  end

  def put([key], value), do: put(key, value)

  def put([parent_key | keys], value) do
    parent =
      Application.get_env(:activity_pub, parent_key, [])
      |> put_in(keys, value)

    Application.put_env(:activity_pub, parent_key, parent)
  end

  def put(key, value) do
    Application.put_env(:activity_pub, key, value)
  end

  def delete([key]), do: delete(key)

  def delete([parent_key | keys]) do
    {_, parent} =
      Application.get_env(:activity_pub, parent_key)
      |> get_and_update_in(keys, fn _ -> :pop end)

    Application.put_env(:activity_pub, parent_key, parent)
  end

  def delete(key) do
    Application.delete_env(:activity_pub, key)
  end
end
