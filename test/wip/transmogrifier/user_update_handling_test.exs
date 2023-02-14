# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.Transmogrifier.UserUpdateHandlingTest do
  use ActivityPub.DataCase

  alias ActivityPub.Object, as: Activity
  alias ActivityPubWeb.Transmogrifier

  import ActivityPub.Factory
  import Tesla.Mock

    setup_all do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  test "it works for incoming update activities" do
    user = local_actor(local: false)

    update_data = file("fixtures/mastodon/mastodon-update.json") |> Jason.decode!()

    object =
      update_data["object"]
      |> Map.put("actor", ap_id(user))
      |> Map.put("id", ap_id(user))

    update_data =
      update_data
      |> Map.put("actor", ap_id(user))
      |> Map.put("object", object)

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(update_data)

    assert data["id"] == update_data["id"]

    user = user_by_ap_id(data["actor"])
    assert user.name == "gargle"

    assert user.avatar["url"] == [
             %{
               "href" =>
                 "https://cd.niu.moe/accounts/avatars/000/033/323/original/fd7f8ae0b3ffedc9.jpeg"
             }
           ]

    assert user.banner["url"] == [
             %{
               "href" =>
                 "https://cd.niu.moe/accounts/headers/000/033/323/original/850b3448fa5fd477.png"
             }
           ]

    assert user.bio == "<p>Some bio</p>"
  end

  test "it works with alsoKnownAs" do
    user = local_actor(local: false)
    actor = ap_id(user)

    # assert user_by_ap_id(actor).also_known_as == []

    {:ok, _activity} =
      "fixtures/mastodon/mastodon-update.json"
      |> file()
      |> Jason.decode!()
      |> Map.put("actor", actor)
      |> Map.update!("object", fn object ->
        object
        |> Map.put("actor", actor)
        |> Map.put("id", actor)
        |> Map.put("alsoKnownAs", [
          "https://mastodon.local/users/foo",
          "http://exampleorg.local/users/bar"
        ])
      end)
      |> Transmogrifier.handle_incoming()

    # TODO
    # assert user_by_ap_id(actor).also_known_as == [
    #          "https://mastodon.local/users/foo",
    #          "http://exampleorg.local/users/bar"
    #        ]
  end

  # TODO
  # test "it works with custom profile fields" do
  #   user = local_actor(local: false)

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

  #   {:ok, _update_activity} = Transmogrifier.handle_incoming(update_data)

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

  #   {:ok, _} = Transmogrifier.handle_incoming(update_data)

  #   user = user_by_ap_id(ap_id(user))

  #   assert user.fields == [
  #            %{"name" => "foo", "value" => "updated"},
  #            %{"name" => "foo1", "value" => "updated"}
  #          ]

  #   update_data =
  #     update_data
  #     |> put_in(["object", "attachment"], [])
  #     |> Map.put("id", update_data["id"] <> ".")

  #   {:ok, _} = Transmogrifier.handle_incoming(update_data)

  #   user = user_by_ap_id(ap_id(user))

  #   assert user.fields == []
  # end

  # TODO
  # test "it works for incoming update activities which lock the account" do
  #   user = local_actor(local: false)

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

  #   {:ok, %Activity{local: false}} = Transmogrifier.handle_incoming(update_data)

  #   user = user_by_ap_id(ap_id(user))
  #   assert user.request_before_follow == true
  # end
end
