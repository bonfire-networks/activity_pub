# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Queries do
  @moduledoc """
  Contains queries for Object.
  """

  import Ecto.Query
  alias ActivityPub.Object

  @type query :: Ecto.Queryable.t() | Object.t()

  @spec by_id(query(), String.t()) :: query()
  def by_id(query \\ Object, id) do
    where(query, [a], a.id == ^id)
  end

  @spec by_ap_id(query, String.t()) :: query
  def by_ap_id(query \\ Object, ap_id) do
    where(
      query,
      [a],
      fragment("(?)->>'id' = ?", a.data, ^to_string(ap_id))
    )
  end

  def by_actor(query \\ Object, ap_id) do
    where(
      query,
      [a],
      fragment("(?)->>'actor' = ?", a.data, ^ap_id)
    )
  end

  def find_by_object_ap_id(activities, object_ap_id) do
    Enum.find(
      activities,
      &(object_ap_id in [is_map(&1.data["object"]) && &1.data["object"]["id"], &1.data["object"]])
    )
  end

  @spec by_object_id(query, String.t() | [String.t()]) :: query
  def by_object_id(query \\ Object, object_id)

  def by_object_id(query, object_ids) when is_list(object_ids) do
    where(
      query,
      [a],
      fragment(
        "coalesce((?)->'object'->>'id', (?)->>'object') = ANY(?)",
        a.data,
        a.data,
        ^object_ids
      )
    )
  end

  def by_object_id(query, object_id) when is_binary(object_id) do
    where(
      query,
      [a],
      fragment(
        "coalesce((?)->'object'->>'id', (?)->>'object') = ?",
        a.data,
        a.data,
        ^object_id
      )
    )
  end

  def activity_by_object_ap_id(ap_id, verb \\ "Create") do
    ap_id
    |> by_object_id()
    |> by_type(verb)
  end

  @spec by_object_in_reply_to_id(query, String.t(), keyword()) :: query
  def by_object_in_reply_to_id(query, in_reply_to_id, opts \\ []) do
    query =
      if opts[:skip_preloading] do
        with_joined_object(query)
      else
        with_preloaded_object(query)
      end

    where(
      query,
      [a, object: o],
      fragment("(?)->>'inReplyTo' = ?", o.data, ^to_string(in_reply_to_id))
    )
  end

  @spec by_type(query, String.t() | List.t()) :: query
  def by_type(query \\ Object, activity_type)

  def by_type(query, types) when is_list(types) do
    where(
      query,
      [a],
      fragment("(?)->>'type' = ?", a.data, ^types)
    )
  end

  def by_type(query, type) do
    where(
      query,
      [a],
      fragment("(?)->>'type' = ?", a.data, ^type)
    )
  end

  @spec exclude_type(query, String.t()) :: query
  def exclude_type(query \\ Object, type) do
    where(
      query,
      [a],
      fragment("(?)->>'type' != ?", a.data, ^type)
    )
  end

  def with_preloaded_object(query, join_type \\ :left) do
    query
    |> has_named_binding?(:object)
    |> if(do: query, else: with_joined_object(query, join_type))
    |> preload([activity, object: object], object: object)
  end

  def with_joined_object(query, join_type \\ :inner) do
    join(query, join_type, [a], o in Object,
      on:
        fragment(
          "(?->>'id') = COALESCE(?->'object'->>'id', ?->>'object')",
          o.data,
          a.data,
          a.data
        ),
      as: :object
    )
  end

  def with_joined_activity(query, activity_type \\ "Create", join_type \\ :left) do
    object_position = Map.get(query.aliases, :object, 0)

    join(query, join_type, [{object, object_position}], a in Object,
      on:
        fragment(
          "COALESCE(?->'object'->>'id', ?->>'object') = (? ->> 'id') AND (?->>'type' = ?) ",
          a.data,
          a.data,
          object.data,
          a.data,
          ^activity_type
        ),
      as: :activity
    )
  end

  def last_follow(query, followed_id) do
    from(
      activity in query,
      where:
        fragment(
          "coalesce((?)->'object'->>'id', (?)->>'object') = ?",
          activity.data,
          activity.data,
          ^followed_id
        ),
      order_by: [fragment("? desc nulls last", activity.inserted_at)],
      limit: 1
    )
  end

  def replies(%{} = object, opts \\ []) do
    # object = normalize(object, fetch: false)

    query =
      Object
      |> where(
        [o],
        fragment("(?)->>'inReplyTo' = ?", o.data, ^object.data["id"])
      )
      |> order_by([o], asc: o.id)

    if opts[:self_only] do
      by_actor(query, object.data["actor"])
    else
      query
    end
  end

  def self_replies(object),
    do: replies(object, self_only: true)
end
