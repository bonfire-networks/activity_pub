# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.ActorView do
  use ActivityPubWeb, :view
  import Untangle
  alias ActivityPub.Actor
  alias ActivityPub.Utils

  def actor_json(username) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      render("actor.json", %{actor: actor})
    end
  end

  def render("actor.json", %{actor: actor}) do
    actor = ActivityPub.Actor.add_public_key(actor)

    type =
      case actor.data["type"] do
        "MN:Community" -> "Group"
        "MN:Collection" -> "Group"
        _ -> actor.data["type"]
      end

    actor.data
    |> Map.put("url", actor.data["id"])
    |> Map.put("type", type)
    |> Map.merge(Utils.make_json_ld_header())
    |> Enum.filter(fn {_k, v} -> v != nil end)
    |> Enum.into(%{})
    |> info
  end

  def render("following.json", %{actor: actor, page: page}) do
    {:ok, followers} = Actor.get_followings(actor)

    total = length(followers)

    collection(followers, "#{actor.ap_id}/following", page, total)
    |> Map.merge(Utils.make_json_ld_header())
  end

  def render("following.json", %{actor: actor}) do
    {:ok, followers} = Actor.get_followings(actor)

    total = length(followers)

    %{
      "id" => "#{actor.ap_id}/following",
      "type" => "Collection",
      "first" => collection(followers, "#{actor.ap_id}/following", 1, total),
      "totalItems" => total
    }
    |> Map.merge(Utils.make_json_ld_header())
  end

  def render("followers.json", %{actor: actor, page: page}) do
    {:ok, followers} = Actor.get_followers(actor)

    total = length(followers)

    collection(followers, "#{actor.ap_id}/followers", page, total)
    |> Map.merge(Utils.make_json_ld_header())
  end

  def render("followers.json", %{actor: actor}) do
    {:ok, followers} = Actor.get_followers(actor)

    total = length(followers)

    %{
      "id" => "#{actor.ap_id}/followers",
      "type" => "Collection",
      "first" => collection(followers, "#{actor.ap_id}/followers", 1, total),
      "totalItems" => total
    }
    |> Map.merge(Utils.make_json_ld_header())
  end

  def collection(collection, iri, page, total \\ nil) do
    offset = (page - 1) * 10
    items = Enum.slice(collection, offset, 10)
    items = Enum.map(items, fn actor -> actor.ap_id end)
    total = total || length(collection)

    map = %{
      "id" => "#{iri}?page=#{page}",
      "type" => "CollectionPage",
      "partOf" => iri,
      "totalItems" => total,
      "orderedItems" => items
    }

    if offset < total do
      Map.put(map, "next", "#{iri}?page=#{page + 1}")
    else
      map
    end
  end
end
