defmodule ActivityPub.Config do
  defmodule Error do
    defexception [:message]
  end

  import Untangle

  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  def public_uri, do: @public_uri
  def public_uris, do: [public_uri()]

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
          "EmojiReact"
        ]

  # def supported_object_types, do: get([:instance, :supported_object_types]) || ["Article", "Note", "Video", "Page", "Question", "Answer", "Document", "ChatMessage"] # Note: unused since we want to support anything
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

  # defdelegate repo, to: ActivityPub.Utils
  @compile_env Mix.env()
  def env, do: Application.get_env(:activity_pub, :env) || @compile_env

  def federating? do
    case Application.get_env(:activity_pub, :instance)[:federating] do
      nil ->
        # this should be handled in test.exs or dev.exs and only here as a fallback
        System.get_env("FEDERATE") == "yes" or
          (env() == :test and
             (Application.get_env(:tesla, :adapter) == Tesla.Mock or
                System.get_env("TEST_INSTANCE") == "yes"))

      "true" ->
        true

      "false" ->
        false

      val ->
        val
    end
    |> info("Federating?")
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
