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
    input_actor_data =
      file("fixtures/mastodon/mastodon-actor.json")
      |> Jason.decode!()
      |> Map.put("summary", "Custom bio not coming from the server")

    assert %Actor{data: created_actor_data, local: false} =
             from_ok(Transformer.handle_incoming(input_actor_data))

    {:ok, original_actor} = Actor.get_cached_or_fetch(ap_id: created_actor_data)

    # the actor has been fetched from source, and the custom data handle_incoming was ignored for safety
    refute original_actor.data["summary"] =~ "Custom bio not coming from the server"
    #  original from the server is kept
    assert original_actor.data["summary"] =~ "short bio"
    assert original_actor.data == created_actor_data
    refute original_actor.data == input_actor_data

    update_data = file("fixtures/mastodon/mastodon-update.json") |> Jason.decode!()

    update_actor_data =
      update_data["object"]
      |> Map.put("actor", created_actor_data["id"])
      |> Map.put("id", created_actor_data["id"])

    update_activity =
      update_data
      |> Map.put("actor", created_actor_data["id"])
      |> Map.put(
        "object",
        update_actor_data
      )

    {:ok, %{data: _, local: false}} =
      Transformer.handle_incoming(update_activity)
      |> debug("handled_update")

    # assert data_updated["id"] == update_activity["id"]

    {:ok, updated_actor} = Actor.get_cached(ap_id: created_actor_data["id"])

    # the actor has been fetched from source, and the custom data from the Update activity was ignored for safety
    refute original_actor.data["summary"] =~ "Some updated bio"
    assert updated_actor.data["summary"] =~ "short bio"
    assert original_actor.data == updated_actor.data
    refute updated_actor.data == update_actor_data

    # Now modify the mock to return different data for the actor
    modified_actor_data =
      file("fixtures/mastodon/mastodon-actor.json")
      |> Jason.decode!()
      |> Map.put("summary", "This is the a bio actually updated on the server")

    actor_url = created_actor_data["id"]

    mock(fn
      %{method: :get, url: ^actor_url} ->
        %Tesla.Env{
          status: 200,
          body: Jason.encode!(modified_actor_data),
          headers: [{"content-type", "application/activity+json"}]
        }

      env ->
        HttpRequestMock.request(env)
    end)

    # Run the update activity again
    {:ok, %{data: _, local: false}} =
      Transformer.handle_incoming(update_activity)
      |> debug("handled_update_again")

    # Now the actor should be updated with the new data from the mock
    {:ok, newly_updated_actor} = Actor.get_cached(ap_id: created_actor_data["id"])

    # Verify the actor now contains the new data
    refute original_actor.data["summary"] =~ "Some updated bio"

    assert newly_updated_actor.data["summary"] =~
             "This is the a bio actually updated on the server"

    refute newly_updated_actor.data == update_actor_data
    refute newly_updated_actor.data == original_actor.data
  end

  test "update activities for an actor ignores the given object and re-fetches the remote actor instead" do
    original_actor_data = file("fixtures/mastodon/mastodon-actor.json") |> Jason.decode!()

    assert %Actor{data: original_actor_data, local: false} =
             from_ok(Transformer.handle_incoming(original_actor_data))

    {:ok, original_actor} = Actor.get_cached_or_fetch(ap_id: original_actor_data)

    update_data = file("fixtures/mastodon/mastodon-update.json") |> Jason.decode!()

    update_object =
      update_data["object"]
      # |> Map.put("actor", original_actor["id"]) 
      |> Map.put("id", original_actor_data["id"])
      |> Map.put("preferredUsername", original_actor_data["preferredUsername"])

    update_activity =
      update_data
      |> Map.put("actor", original_actor_data["id"])
      |> Map.put("object", update_object)
      |> info("update_activity")

    {:ok, %{data: _, local: false}} = Transformer.handle_incoming(update_activity)

    {:ok, non_updated_actor} = Actor.get_cached(ap_id: original_actor_data["id"])

    assert non_updated_actor.data == original_actor.data
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
