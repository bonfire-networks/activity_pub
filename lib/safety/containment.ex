# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Safety.Containment do
  @moduledoc """
  This module contains some useful functions for containing objects to specific
  origins and determining those origins.  They previously lived in the
  ActivityPub `Transformer` module.

  Object containment is an important step in validating remote objects to prevent
  spoofing, therefore removal of object containment functions is NOT recommended.
  """
  import Untangle
  require ActivityPub.Config
  alias ActivityPub.Object
  alias ActivityPub.Config
  alias ActivityPub.Utils

  def get_object(%{"object" => %{"id" => id}}) when is_binary(id) do
    id
  end

  def get_object(_) do
    nil
  end

  defp compare_uris(%URI{host: host} = _id_uri, %URI{host: host} = _other_uri), do: true

  defp compare_uris(id_uri, other_uri) do
    error(
      other_uri,
      "The object doesn't seem to come from the same instance as the actor: #{inspect(id_uri)}"
    )

    false
  end

  @doc """
  Checks that an imported AP object's actor matches the host it came from.
  """

  def contain_origin(_id, %{"type" => type} = _params)
      when ActivityPub.Config.is_in(type, :supported_actor_types) or
             ActivityPub.Config.is_in(type, :collection_types) or
             type in ["Author", "Tombstone", "Place"],
      do: true

  def contain_origin(id, %{"type" => types} = params) when is_list(types),
    do: Enum.any?(types, &contain_origin(id, Map.put(params, "type", &1)))

  def contain_origin(id, %{"actor" => _actor} = params) when is_binary(id) do
    id_uri = URI.parse(id)
    actor_uri = URI.parse(Object.actor_id_from_data(params))

    compare_uris(actor_uri, id_uri)
  end

  def contain_origin(id, %{"object" => %{"actor" => actor}} = params),
    do: contain_origin(id, Map.put(params, "actor", actor))

  def contain_origin(id, %{"attributedTo" => actor} = params),
    do: contain_origin(id, Map.put(params, "actor", actor))

  def contain_origin(id, %{"object" => %{"attributedTo" => actor}} = params),
    do: contain_origin(id, Map.put(params, "actor", actor))

  #  for bookwyrm books which don't (always?) have actor
  def contain_origin(id, %{"authors" => authors} = params),
    do: contain_origin(id, Map.put(params, "actor", List.first(authors)))

  def contain_origin(id, data) do
    error(data, "Missing an actor or attributedTo for #{inspect(id)}")
    false
  end

  # defp contain_origin(%{"id" => id} = data) do
  #   if data["type"] in @skipped_types do
  #     {:ok, data}
  #   else
  #     actor = Object.actor_from_data(data)
  #     actor_uri = URI.parse(actor)
  #     id_uri = URI.parse(id)

  #     if id_uri.host == actor_uri.host do
  #       {:ok, data}
  #     else
  #       {:error, "Object containment error"}
  #     end
  #   end
  # end

  # def contain_origin_from_id(id, %{"id" => other_id} = _params) when is_binary(other_id) do
  #   id_uri = URI.parse(id)
  #   other_uri = URI.parse(other_id)

  #   compare_uris(id_uri, other_uri)
  # end

  # # Mastodon pin activities don't have an id, so we check the object field, which will be pinned.
  # def contain_origin_from_id(id, %{"object" => object}) when is_binary(object) do
  #   id_uri = URI.parse(id)
  #   object_uri = URI.parse(object)

  #   compare_uris(id_uri, object_uri)
  # end

  # def contain_origin_from_id(_id, _data), do: false

  # def contain_child(%{"object" => %{"id" => id, "attributedTo" => _} = object}),
  #   do: contain_origin(id, object)

  # def contain_child(_), do: true

  # def contain_uri(_id, data) when data == %{} or is_nil(data), do: true

  # def contain_uri(id, %{"id" => json_id} = _data) do
  #   id_uri = URI.parse(id)
  #   json_id_uri = URI.parse(json_id)

  #   if id_uri.host == json_id_uri.host do
  #     true
  #   else
  #     error(json_id, "URI containment error: #{inspect id}")
  #     false
  #   end
  # end

  @spec visible_for_user?(Object.t() | nil, User.t() | nil) :: boolean()
  def visible_for_user?(%Object{data: %{"type" => "Tombstone"}}, _), do: true

  # def visible_for_user?(%Object{data: %{"actor" => ap_id}}, %User{ap_id: user_ap_id}) when ap_id==user_ap_id, do: true # TODO
  def visible_for_user?(nil, _), do: false
  # def visible_for_user?(%Activity{data: %{"listMessage" => _}}, nil), do: false

  # def visible_for_user?(
  #       %Activity{data: %{"listMessage" => list_ap_id}} = activity,
  #       %User{} = user
  #     ) do
  #   user.ap_id in activity.data["to"] ||
  #     list_ap_id
  #     |> Pleroma.List.get_by_ap_id()
  #     |> Pleroma.List.member?(user)
  # end

  def visible_for_user?(%{__struct__: module} = object, nil)
      when module in [Object] do
    if restrict_unauthenticated_access?(object),
      do: false,
      else: Utils.public?(object)
  end

  def visible_for_user?(object, %{actor: actor}), do: visible_for_user?(object, actor)

  def visible_for_user?(%{__struct__: module} = object, actor)
      when module in [Object] do
    user_ap_id = actor.data["id"]

    x =
      [user_ap_id, "#{user_ap_id}/followers"]
      |> debug("me")

    y =
      [
        object.data["actor"],
        object.data["to"],
        object.data["cc"],
        object.data["bto"],
        object.data["bcc"],
        object.data["audience"]
      ]
      |> List.flatten()
      |> debug("audiences")

    (Utils.public?(object) || Enum.any?(x, &(&1 in y))) and actor.local
  end

  def restrict_unauthenticated_access?(%Object{} = object) do
    object
    |> Map.get(:local)
    |> restrict_unauthenticated_access_to_activity?()
  end

  defp restrict_unauthenticated_access_to_activity?(local?) when is_boolean(local?) do
    cfg_key = if local?, do: :local, else: :remote

    restrict_unauthenticated_access?(:activities, cfg_key)
  end

  def restrict_unauthenticated_access?(resource, kind) do
    setting = Config.get([:restrict_unauthenticated, resource, kind])

    if setting in [nil, :if_instance_is_private] do
      !Config.get([:instance, :public], false)
    else
      setting
    end
  end
end
