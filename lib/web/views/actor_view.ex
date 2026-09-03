# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.Web.ActorView do
  use ActivityPub.Web, :view

  import Untangle
  alias ActivityPub.Actor
  alias ActivityPub.Config
  alias ActivityPub.Utils
  alias ActivityPub.Safety.Keys
  alias ActivityPub.Web.Collections
  alias ActivityPub.Federator.Adapter

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

  def render("following.json", %{actor: actor} = params) do
    follow_collection(actor, "following", params[:page])
    |> Map.merge(Utils.make_json_ld_header(:actor))
  end

  def render("followers.json", %{actor: actor} = params) do
    follow_collection(actor, "followers", params[:page])
    |> Map.merge(Utils.make_json_ld_header(:actor))
  end

  #  TODO: load based on current_actor so we can show non-public ones
  defp follow_collection(actor, which, page) do
    {fetch, count} =
      case which do
        "followers" ->
          {&Actor.follower_ap_ids(actor, &1, &2), fn -> Adapter.count_followers(actor) end}

        "following" ->
          {&Actor.following_ap_ids(actor, &1, &2), fn -> Adapter.count_following(actor) end}
      end

    Collections.collection("#{actor.ap_id}/#{which}",
      page: page,
      fetch: fetch,
      count: count,
      ordered?: false,
      items_key: "orderedItems"
    )
  end
end
