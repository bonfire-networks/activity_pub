# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.Web.ActorView do
  use ActivityPub.Web, :view

  import Untangle
  alias ActivityPub.Actor
  alias ActivityPub.Config
  alias ActivityPub.Utils
  alias ActivityPub.Safety.Keys

  def actor_json(username) do
    with {:ok, actor} <- Actor.get_cached(username: username) do
      render("actor.json", %{actor: actor})
    end
  end

  def render("actor.json", %{actor: actor}) do
    actor = Keys.add_public_key(actor)

    type =
      case actor.data["type"] do
        "MN:Community" -> "Group"
        "MN:Collection" -> "Group"
        _ -> actor.data["type"]
      end

    actor.data
    |> Map.put("url", actor.data["id"])
    |> Map.put("type", type)
    |> maybe_put_generator()
    |> Map.merge(Utils.make_json_ld_header(:actor))
    |> Enum.filter(fn {_k, v} -> v != nil end)
    |> Enum.into(%{})
    |> debug
  end

  # FEP-844e: Capability discovery via generator/implements properties
  defp maybe_put_generator(data) do
    implements = Config.get(:implements, [])

    if implements != [] do
      case Utils.service_actor() do
        {:ok, service_actor} ->
          if data["id"] == service_actor.ap_id do
            # The service actor IS the Application: put implements directly, and change the type from Person to Application
            data
            |> Map.put("type", "Application")
            |> Map.put("implements", implements)
          else
            # User actors get a generator pointing to the service actor
            Map.put(data, "generator", %{
              "type" => "Application",
              "id" => service_actor.ap_id,
              "name" => service_actor.data["name"] || service_actor.username,
              "implements" => implements
            })
          end

        _ ->
          # Fallback: anonymous generator without id
          Map.put(data, "generator", %{
            "type" => "Application",
            "implements" => implements
          })
      end
    else
      data
    end
  end

  def render("following.json", %{actor: actor, page: page}) when is_integer(page) do
    #  TODO: avoid querying full list
    #  TODO: load based on current_actor so we can show non-public ones
    {:ok, followers} = Actor.get_followings(actor)

    total = length(followers)

    collection(followers, "#{actor.ap_id}/following", page, total)
    |> Map.merge(Utils.make_json_ld_header(:actor))
    |> debug("json")
  end

  def render("following.json", %{actor: actor}) do
    #  TODO: avoid querying full list
    #  TODO: load based on current_actor so we can show non-public ones
    {:ok, followers} = Actor.get_followings(actor)

    total = length(followers)

    %{
      "id" => "#{actor.ap_id}/following",
      "type" => "Collection",
      "first" => collection(followers, "#{actor.ap_id}/following", 1, total),
      "totalItems" => total
    }
    |> Map.merge(Utils.make_json_ld_header(:actor))
    |> debug("json")
  end

  def render("followers.json", %{actor: actor, page: page}) when is_integer(page) do
    #  TODO: avoid querying full list
    #  TODO: load based on current_actor so we can show non-public ones
    followers = Actor.get_followers(actor)

    total = length(followers)

    collection(followers, "#{actor.ap_id}/followers", page, total)
    |> Map.merge(Utils.make_json_ld_header(:actor))
  end

  def render("followers.json", %{actor: actor}) do
    #  TODO: avoid querying full list 
    #  TODO: load based on current_actor so we can show non-public ones
    followers = Actor.get_followers(actor)

    total = length(followers)

    %{
      "id" => "#{actor.ap_id}/followers",
      "type" => "Collection",
      "first" => collection(followers, "#{actor.ap_id}/followers", 1, total),
      "totalItems" => total
    }
    |> Map.merge(Utils.make_json_ld_header(:actor))
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
