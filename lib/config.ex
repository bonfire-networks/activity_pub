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

  @doc "For matching against the above list in guards TODO: use runtime config"
  defmacro is_in(type, fun) do
    quote do: unquote(type) in unquote(apply(ActivityPub.Config, fun, []))
  end

  @doc "For matching a type or list of types against configured types"
  def type_in?(type, fun) when is_binary(type) do
    type in apply(ActivityPub.Config, fun, [])
  end

  def type_in?(types, fun) when is_list(types) do
    config_types = apply(ActivityPub.Config, fun, [])
    Enum.any?(types, fn type -> type in config_types end)
  end

  @doc """
  Checks if the given type (or any of list of types) is known, i.e. supported by the instance. Does not include collections.
  """
  def known_fetchable_type?(types) do
    config_types =
      supported_actor_types() ++ supported_activity_types() ++ known_object_fetchable_types()

    Enum.any?(List.wrap(types), fn type -> type in config_types end)
  end

  # defdelegate repo, to: ActivityPub.Utils
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
