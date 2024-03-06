# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.UserUpdateHandlingTest do
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Actor
  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Federator.Transformer

  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  test "it works for incoming update activities" do
    user = actor(local: false)

    update_data = file("fixtures/mastodon/mastodon-update.json") |> Jason.decode!()

    update_activity =
      update_data
      |> Map.put("actor", ap_id(user))
      |> Map.put(
        "object",
        update_data["object"]
        |> Map.put("actor", ap_id(user))
        |> Map.put("id", ap_id(user))
      )

    {:ok, %Activity{data: data_updated, local: false}} =
      Transformer.handle_incoming(update_activity)
      |> debug()

    assert data_updated["id"] == update_activity["id"]

    user =
      user_by_ap_id(data_updated["actor"])
      |> repo().maybe_preload(profile: [:icon, :image])
      |> debug()

    assert user.profile.name == "gargle"

    assert Map.get(user.profile.icon, :path) ==
             "https://cdn.mastodon.local/accounts/avatars/000/033/323/original/fd7f8ae0b3ffedc9.jpeg"

    assert Map.get(user.profile.image, :path) ==
             "https://cdn.mastodon.local/accounts/headers/000/033/323/original/850b3448fa5fd477.png"

    assert user.profile.summary =~ "<p>Some bio</p>"
  end

  # FIXME!
  test "update activities for an actor ignores the given object and re-fetches the remote actor instead" do
    original_actor = file("fixtures/mastodon/mastodon-actor.json") |> Jason.decode!()

    assert %Actor{data: original_actor, local: false} =
             ok_unwrap(Transformer.handle_incoming(original_actor))

    update_data = file("fixtures/mastodon/mastodon-update.json") |> Jason.decode!()

    {:ok, actor} = Actor.get_cached_or_fetch(ap_id: original_actor)

    update_object =
      update_data["object"]
      # |> Map.put("actor", original_actor["id"]) 
      |> Map.put("id", original_actor["id"])
      |> Map.put("preferredUsername", actor.data["preferredUsername"])

    update_activity =
      update_data
      |> Map.put("actor", original_actor["id"])
      |> Map.put("object", update_object)
      |> info("update_activity")

    {:ok, %Object{data: data, local: false}} = Transformer.handle_incoming(update_activity)

    {:ok, updated_actor} = Actor.get_cached(ap_id: original_actor["id"])

    assert updated_actor.data == actor.data

    # TODO: test the case where the remote changed and we actually do an update
    # assert updated_actor.data["name"] == "gargle"

    # assert updated_actor.data["icon"]["url"] ==
    #          "https://cdn.mastodon.local/accounts/avatars/000/033/323/original/fd7f8ae0b3ffedc9.jpeg"

    # assert updated_actor.data["image"]["url"] ==
    #          "https://cdn.mastodon.local/accounts/headers/000/033/323/original/850b3448fa5fd477.png"

    # assert updated_actor.data["summary"] == "<p>Some bio</p>"
  end

  # TODO
  # test "it works with custom profile fields" do
  #   user = actor(local: false)

  #   assert user.fields == []

  #   update_data = file("fixtures/mastodon/mastodon-update.json") |> Jason.decode!()

  #   object =
  #     update_data["object"]
  #     |> Map.put("actor", ap_id(user))
  #     |> Map.put("id", ap_id(user))

  #   update_data =
  #     update_data
  #     |> Map.put("actor", ap_id(user))
  #     |> Map.put("object", object)

  #   {:ok, _update_activity} = Transformer.handle_incoming(update_data)

  #   user = user_by_ap_id(ap_id(user))

  #   assert user.fields == [
  #            %{"name" => "foo", "value" => "updated"},
  #            %{"name" => "foo1", "value" => "updated"}
  #          ]

  #   clear_config([:instance, :max_remote_account_fields], 2)

  #   update_data =
  #     update_data
  #     |> put_in(["object", "attachment"], [
  #       %{"name" => "foo", "type" => "PropertyValue", "value" => "bar"},
  #       %{"name" => "foo11", "type" => "PropertyValue", "value" => "bar11"},
  #       %{"name" => "foo22", "type" => "PropertyValue", "value" => "bar22"}
  #     ])
  #     |> Map.put("id", update_data["id"] <> ".")

  #   {:ok, _} = Transformer.handle_incoming(update_data)

  #   user = user_by_ap_id(ap_id(user))

  #   assert user.fields == [
  #            %{"name" => "foo", "value" => "updated"},
  #            %{"name" => "foo1", "value" => "updated"}
  #          ]

  #   update_data =
  #     update_data
  #     |> put_in(["object", "attachment"], [])
  #     |> Map.put("id", update_data["id"] <> ".")

  #   {:ok, _} = Transformer.handle_incoming(update_data)

  #   user = user_by_ap_id(ap_id(user))

  #   assert user.fields == []
  # end

  # TODO
  # test "it works for incoming update activities which lock the account" do
  #   user = actor(local: false)

  #   update_data = file("fixtures/mastodon/mastodon-update.json") |> Jason.decode!()

  #   object =
  #     update_data["object"]
  #     |> Map.put("actor", ap_id(user))
  #     |> Map.put("id", ap_id(user))
  #     |> Map.put("manuallyApprovesFollowers", true)

  #   update_data =
  #     update_data
  #     |> Map.put("actor", ap_id(user))
  #     |> Map.put("object", object)

  #   {:ok, %Activity{local: false}} = Transformer.handle_incoming(update_data)

  #   user = user_by_ap_id(ap_id(user))
  #   assert user.request_before_follow == true
  # end
end
