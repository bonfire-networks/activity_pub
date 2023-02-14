defmodule ActivityPub.Test.Helpers do
    alias ActivityPub.Config
    alias ActivityPub.Utils
    alias ActivityPub.Common
  require Logger

  @mod_path __DIR__
  def file(path), do: File.read!(@mod_path <> "/../" <> path)

  def endpoint,
    do:
      Process.get(:phoenix_endpoint_module) ||
        Application.get_env(
          :activity_pub,
          :endpoint_module,
          ActivityPubWeb.Endpoint
        )

  def test_path, do: Path.expand("../", __DIR__)

  def ap_object_from_outgoing(%{federate_activity_pub: object}), do: object
  def ap_object_from_outgoing(%{activity: %{federate_activity_pub: object}}), do: object
  def ap_object_from_outgoing(object), do: object

  def follow(actor_1, actor_2) do
    # TODO: make into a generic adapter callback?
    if ActivityPub.Adapter.adapter() == Bonfire.Federate.ActivityPub.Adapter do
      Bonfire.Social.Follows.follow(user_by_ap_id(actor_1), user_by_ap_id(actor_2))
    else
      ActivityPub.LocalActor.follow(actor_1, actor_2)
    end
  end

  def following?(actor_1, actor_2) do
    if ActivityPub.Adapter.adapter() == Bonfire.Federate.ActivityPub.Adapter do
      Bonfire.Social.Follows.following?(user_by_ap_id(actor_1), user_by_ap_id(actor_2))
    else
      # TODO
      # ActivityPub.LocalActor.following?(actor_1, actor_2)
    end
  end

  def block(actor_1, actor_2) do
    # TODO: make into a generic adapter callback?
    if ActivityPub.Adapter.adapter() == Bonfire.Federate.ActivityPub.Adapter do
      Bonfire.Boundaries.Blocks.block(user_by_ap_id(actor_2), :all, current_user: user_by_ap_id(actor_1))
    else
      # TODO
    end
  end

  def is_blocked?(actor_1, actor_2) do
    if ActivityPub.Adapter.adapter() == Bonfire.Federate.ActivityPub.Adapter do
      Bonfire.Boundaries.Blocks.is_blocked?(user_by_ap_id(actor_2), :any, current_user: user_by_ap_id(actor_1))
    else
      # TODO
    end
  end

  

   def user_by_ap_id(%{user: %{} = user, actor: actor} = map), do: user |> Map.put(:actor, actor)
   def user_by_ap_id(id) when is_binary(id) do
    if ActivityPub.Adapter.adapter() == Bonfire.Federate.ActivityPub.Adapter do
      Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(id)
    else
      ActivityPub.LocalActor.get(ap_id: id)
    end
    |> Common.ok_unwrap()
  end
   def user_by_ap_id(%{"id"=>id}), do: user_by_ap_id(id)
   def user_by_ap_id(user), do: user

  def ap_id(%{data: %{"id"=>id}}), do: id
  def ap_id(%{data: %{"id"=>id}}), do: id
  def ap_id(%{ap_id: id}), do: id


      def refresh_record(%{id: id, __struct__: model} = _),
        do: refresh_record(model, id)

      def refresh_record(model, id) do
        Common.repo().get_by(model, id: id)
      end

  defmacro clear_config(config_path) do
    quote do
      clear_config(unquote(config_path)) do
      end
    end
  end

  defmacro clear_config(config_path, do: yield) do
    quote do
      initial_setting = Config.get(unquote(config_path))

      unquote(yield)

      on_exit(fn ->
        case initial_setting do
          nil ->
            Config.delete(unquote(config_path))

          value ->
            Config.put(unquote(config_path), value)
        end
      end)

      :ok
    end
  end

  defmacro clear_config(config_path, temp_setting) do
    # NOTE: `clear_config([section, key], value)` != `clear_config([section], key: value)` (!)
    # Displaying a warning to prevent unintentional clearing of all but one keys in section
    if Keyword.keyword?(temp_setting) and length(temp_setting) == 1 do
      Logger.warn(
        "Please change `clear_config([section], key: value)` to `clear_config([section, key], value) (#{inspect(config_path)} = #{inspect(temp_setting)})`"
      )
    end

    quote do
      clear_config(unquote(config_path)) do
        Config.put(unquote(config_path), unquote(temp_setting))
      end
    end
  end
end
