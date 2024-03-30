# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.NoteHandlingTest do
  use ActivityPub.DataCase, async: false
  use Oban.Testing, repo: repo()

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Utils
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Test.HttpRequestMock
  alias ActivityPub.Federator.Workers

  import Mock
  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  # setup do: clear_config([:instance, :max_remote_account_fields])

  describe "handle_incoming" do
    test "it works for incoming create activity" do
      data = file("fixtures/mastodon/mastodon-post-activity.json") |> Jason.decode!()

      assert %Object{data: _, local: false} = ok_unwrap(Transformer.handle_incoming(data))
    end

    test "it works for incoming notices with tag not being an array (kroeg)" do
      data = file("fixtures/kroeg-array-less-emoji.json") |> Jason.decode!()

      {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)
      object = Object.normalize(data["object"], fetch: false)

      assert object.data["emoji"] == %{
               "icon_e_smile" => "https://puckipedia.local/forum/images/smilies/icon_e_smile.png"
             }

      data = file("fixtures/kroeg-array-less-hashtag.json") |> Jason.decode!()

      {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)
      object = Object.normalize(data["object"], fetch: false)

      assert "test" in Object.hashtags(object)
    end

    test "it ignores an incoming notice if we already have it" do
      activity = insert(:note_activity)

      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Jason.decode!()
        |> Map.put("object", Object.normalize(activity, fetch: false).data)

      {:ok, returned_activity} = Transformer.handle_incoming(data)

      assert stripped_object(activity) ==
               stripped_object(returned_activity)
    end

    @tag :todo
    test "it does not work for deactivated users" do
      data = file("fixtures/mastodon/mastodon-post-activity.json") |> Jason.decode!()

      local_actor(ap_id: data["actor"], is_active: false)

      {:error, _} = Transformer.handle_incoming(data)
    end

    test "it works without published" do
      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Jason.decode!()
        |> Map.drop(["published"])

      object =
        data["object"]
        |> Map.drop(["published"])

      data =
        Map.put(data, "object", object)
        |> debug("precreate")

      {:ok, %{data: object_data}} =
        Transformer.handle_incoming(data)
        |> debug("postcreate")
    end

    # see https://codeberg.org/helge/funfedidev/issues/138#issuecomment-1647777
    test "it works without an actor" do
      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Jason.decode!()
        |> Map.drop(["actor", "attributedTo", "signature"])

      object =
        data["object"]
        |> Map.drop(["actor", "attributedTo"])

      data =
        Map.put(data, "object", object)
        |> debug("precreate")

      {:ok, %{data: object_data}} =
        Transformer.handle_incoming(data)
        |> debug("postcreate")

      # FIXME?
      # assert (is_nil(object_data["actor"]) or object_data["actor"] ==  Object.get_ap_id(Utils.service_actor()))
    end

    test "it works for incoming notices" do
      data = file("fixtures/mastodon/mastodon-post-activity.json") |> Jason.decode!()

      {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

      assert data["id"] ==
               "https://mastodon.local/users/admin/statuses/99512778738411822/activity"

      assert data["context"] ==
               "tag:mastodon.local,2018-02-12:objectId=20:objectType=Conversation"

      assert data["to"] == ["https://www.w3.org/ns/activitystreams#Public"]

      assert Enum.sort(data["cc"]) ==
               Enum.sort([
                 "https://testing.local/users/karen",
                 "https://mastodon.local/users/admin/followers"
               ])

      assert data["actor"] == "https://mastodon.local/users/admin"

      object_data = Object.normalize(data["object"], fetch: false).data

      assert object_data["id"] ==
               "https://mastodon.local/users/admin/statuses/99512778738411822"

      assert object_data["to"] == ["https://www.w3.org/ns/activitystreams#Public"]

      assert Enum.sort(object_data["cc"]) ==
               Enum.sort([
                 "https://testing.local/users/karen",
                 "https://mastodon.local/users/admin/followers"
               ])

      assert object_data["actor"] == "https://mastodon.local/users/admin"
      assert object_data["attributedTo"] == "https://mastodon.local/users/admin"

      assert object_data["context"] ==
               "tag:mastodon.local,2018-02-12:objectId=20:objectType=Conversation"

      assert object_data["sensitive"] == true

      user = user_by_ap_id(object_data["actor"])
      # assert user.note_count == 1
    end

    @tag :todo
    test "it works for incoming notices without the sensitive property but an nsfw hashtag" do
      data = file("fixtures/mastodon/mastodon-post-activity-nsfw.json") |> Jason.decode!()

      {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

      object_data = Object.normalize(data["object"], fetch: false).data

      assert object_data["sensitive"] == true
    end

    test "it works for incoming notices with hashtags" do
      data = file("fixtures/mastodon/mastodon-post-activity-hashtag.json") |> Jason.decode!()

      {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)
      object = Object.normalize(data["object"], fetch: false)

      assert match?(
               %{
                 "href" => "https://testing.local/users/karen",
                 "name" => "@karen@testing.local",
                 "type" => "Mention"
               },
               Enum.at(object.data["tag"], 0)
             )

      assert match?(
               %{
                 "href" => "https://mastodon.local/tags/moo",
                 "name" => "#moo",
                 "type" => "Hashtag"
               },
               Enum.at(object.data["tag"], 1)
             )

      assert "moo" == Enum.at(object.data["tag"], 2)
    end

    test "it works for incoming notices with contentMap with multiple languages" do
      data = file("fixtures/mastodon/mastodon-post-activity-contentmaps.json") |> Jason.decode!()

      {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)
      object = Object.normalize(data["object"], fetch: false)

      assert object.data["content"] =~
               "<p><span class=\"h-card\"><a href=\"https://testing.local/users/karen\" class=\"u-url mention\">@<span>karen</span></a></span> testing</p>"

      assert object.data["content"] =~
               "<p><span class=\"h-card\"><a href=\"https://testing.local/users/karen\" class=\"u-url mention\">@<span>karen</span></a></span> probando</p>"
    end

    test "it works for incoming notices with contentMap with single language" do
      data = file("fixtures/mastodon/mastodon-post-activity-contentmap.json") |> Jason.decode!()

      {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)
      object = Object.normalize(data["object"], fetch: false)

      assert object.data["content"] ==
               "<p><span class=\"h-card\"><a href=\"https://testing.local/users/karen\" class=\"u-url mention\">@<span>karen</span></a></span> testing</p>"
    end

    test "it works for incoming notices with to/cc not being an array (kroeg)" do
      data = file("fixtures/kroeg-post-activity.json") |> Jason.decode!()

      {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)
      object = Object.normalize(data["object"], fetch: false)

      assert object.data["content"] ==
               "<p>henlo from my Psion netBook</p><p>message sent from my Psion netBook</p>"
    end

    test "it ensures that https://www.w3.org/ns/activitystreams#Public activities make it to their followers collection" do
      user = local_actor()

      to = "https://www.w3.org/ns/activitystreams#Public"
      cc = []
      actor = ap_id(user)

      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Jason.decode!()
        |> Map.put("actor", actor)
        |> Map.put("to", to)
        |> Map.put("cc", cc)

      object =
        data["object"]
        |> Map.put("attributedTo", actor)
        |> Map.put("to", to)
        |> Map.put("cc", cc)
        |> Map.put("id", actor <> "/objects/12345678")

      data = Map.put(data, "object", object)

      {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

      assert Utils.public?(data)
      assert data["to"] == [to]
      # FIXME?
      # assert data["cc"] == [User.ap_followers(user)]
    end

    test "it ensures that [https://www.w3.org/ns/activitystreams#Public] activities make it to their followers collection" do
      user = local_actor()

      to = ["https://www.w3.org/ns/activitystreams#Public"]
      cc = []
      actor = ap_id(user)

      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Jason.decode!()
        |> Map.put("actor", actor)
        |> Map.put("to", to)
        |> Map.put("cc", cc)

      object =
        data["object"]
        |> Map.put("attributedTo", actor)
        |> Map.put("to", to)
        |> Map.put("cc", cc)
        |> Map.put("id", actor <> "/objects/12345678")

      data = Map.put(data, "object", object)

      {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

      assert Utils.public?(data)
      assert data["to"] == to
      # FIXME?
      # assert data["cc"] == [User.ap_followers(user)]
    end

    test "it ensures that [https://www.w3.org/ns/activitystreams#Public] as CC activities make it to their followers collection" do
      user = local_actor()

      to = []
      cc = ["https://www.w3.org/ns/activitystreams#Public"]
      actor = ap_id(user)

      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Jason.decode!()
        |> Map.put("actor", actor)
        |> Map.put("to", to)
        |> Map.put("cc", cc)

      object =
        data["object"]
        |> Map.put("attributedTo", actor)
        |> Map.put("to", to)
        |> Map.put("cc", cc)
        |> Map.put("id", actor <> "/objects/12345678")

      data = Map.put(data, "object", object)

      {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

      assert Utils.public?(data)
      # assert data["to"] == cc # FIXME?
      assert data["cc"] == cc
      # FIXME?
      # assert data["cc"] == [User.ap_followers(user)]
    end

    test "it ensures that [as:Public] activities make it to their followers collection" do
      user = local_actor()

      to = ["as:Public"]
      cc = []
      actor = ap_id(user)

      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Jason.decode!()
        |> Map.put("actor", actor)
        |> Map.put("to", to)
        |> Map.put("cc", cc)

      object =
        data["object"]
        |> Map.put("attributedTo", actor)
        |> Map.put("to", to)
        |> Map.put("cc", cc)
        |> Map.put("id", actor <> "/objects/12345678")

      data = Map.put(data, "object", object)

      {:ok, %Activity{data: new_data, local: false}} = Transformer.handle_incoming(data)

      assert Utils.public?(new_data)
      assert new_data["to"] == ["https://www.w3.org/ns/activitystreams#Public"]
      # FIXME?
      # assert data["cc"] == [User.ap_followers(user)]
    end

    test "it ensures that [Public] activities make it to their followers collection" do
      user = local_actor()

      to = ["Public"]
      cc = []
      actor = ap_id(user)

      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Jason.decode!()
        |> Map.put("actor", actor)
        |> Map.put("to", to)
        |> Map.put("cc", cc)

      object =
        data["object"]
        |> Map.put("attributedTo", actor)
        |> Map.put("to", to)
        |> Map.put("cc", cc)
        |> Map.put("id", actor <> "/objects/12345678")

      data = Map.put(data, "object", object)

      {:ok, %Activity{data: new_data, local: false}} = Transformer.handle_incoming(data)

      assert Utils.public?(new_data)
      assert new_data["to"] == ["https://www.w3.org/ns/activitystreams#Public"]
      # FIXME?
      # assert data["cc"] == [User.ap_followers(user)]
    end

    test "it ensures that address fields become lists" do
      user = local_actor()

      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Jason.decode!()
        |> Map.put("actor", ap_id(user))
        |> Map.put("cc", ap_id(user))

      object =
        data["object"]
        |> Map.put("attributedTo", ap_id(user))
        |> Map.put("id", ap_id(user) <> "/objects/12345678")

      data = Map.put(data, "object", object)

      {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)
      debug(data, "ccccc")
      assert is_list(data["cc"])
    end

    # TODO?
    # test "it strips internal likes" do
    #   data =
    #     file("fixtures/mastodon/mastodon-post-activity.json")
    #     |> Jason.decode!()

    #   likes = %{
    #     "first" =>
    #       "https://mastodon.local/objects/dbdbc507-52c8-490d-9b7c-1e1d52e5c132/likes?page=1",
    #     "id" => "https://mastodon.local/objects/dbdbc507-52c8-490d-9b7c-1e1d52e5c132/likes",
    #     "totalItems" => 3,
    #     "type" => "OrderedCollection"
    #   }

    #   object = Map.put(data["object"], "likes", likes)
    #   data = Map.put(data, "object", object)

    #   {:ok, %Activity{} = activity} = Transformer.handle_incoming(data)

    #   object = Object.normalize(activity)

    #   assert object.data["likes"] == []
    # end

    test "it correctly processes messages with non-array to field" do
      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Poison.decode!()
        |> Map.put("to", "https://www.w3.org/ns/activitystreams#Public")
        |> put_in(["object", "to"], "https://www.w3.org/ns/activitystreams#Public")

      assert {:ok, activity} = Transformer.handle_incoming(data)

      assert Enum.sort([
               "https://testing.local/users/karen",
               "https://mastodon.local/users/admin/followers"
             ]) == Enum.sort(activity.data["cc"])

      assert ["https://www.w3.org/ns/activitystreams#Public"] == activity.data["to"]
    end

    test "it correctly processes messages with non-array cc field" do
      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Poison.decode!()
        |> Map.put("cc", "https://mastodon.local/users/admin/followers")
        |> put_in(["object", "cc"], "https://mastodon.local/users/admin/followers")

      assert {:ok, activity} = Transformer.handle_incoming(data)

      assert ["https://mastodon.local/users/admin/followers"] == activity.data["cc"]
      assert ["https://www.w3.org/ns/activitystreams#Public"] == activity.data["to"]
    end

    test "it correctly processes messages with weirdness in address fields" do
      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Poison.decode!()
        |> Map.put("cc", ["https://mastodon.local/users/admin/followers", ["¿"]])
        |> put_in(["object", "cc"], ["https://mastodon.local/users/admin/followers", ["¿"]])

      assert {:ok, activity} = Transformer.handle_incoming(data)

      assert ["https://mastodon.local/users/admin/followers"] == activity.data["cc"]
      assert ["https://www.w3.org/ns/activitystreams#Public"] == activity.data["to"]
    end

    test "it correctly processes MFM (with x format)" do
      data =
        file("fixtures/misskey/mfm_x_format.json")
        |> Poison.decode!()

      assert {:ok, activity} = Transformer.handle_incoming(data)

      assert debug(activity.object).data["content"] =~
               "animation: 1s linear 0s infinite normal both running mfm-rubberBand"

      # refute debug(activity)
    end
  end

  describe "fix_attachments/1" do
    test "returns not modified object" do
      data = Jason.decode!(file("fixtures/mastodon/mastodon-post-activity.json"))
      assert Transformer.fix_attachments(data) == data
    end

    test "returns modified object when attachment is map" do
      assert Transformer.fix_attachments(%{
               "attachment" => %{
                 "mediaType" => "video/mp4",
                 "url" => "https://group.local/stat-480.mp4"
               }
             }) == %{
               "attachment" => [
                 %{
                   "mediaType" => "video/mp4",
                   "type" => "Document",
                   "url" => [
                     %{
                       "href" => "https://group.local/stat-480.mp4",
                       "mediaType" => "video/mp4",
                       "type" => "Link"
                     }
                   ]
                 }
               ]
             }
    end

    test "returns modified object when attachment is list" do
      assert Transformer.fix_attachments(%{
               "attachment" => [
                 %{"mediaType" => "video/mp4", "url" => "https://pe.er/stat-480.mp4"},
                 %{"mimeType" => "video/mp4", "href" => "https://pe.er/stat-480.mp4"}
               ]
             }) == %{
               "attachment" => [
                 %{
                   "mediaType" => "video/mp4",
                   "type" => "Document",
                   "url" => [
                     %{
                       "href" => "https://pe.er/stat-480.mp4",
                       "mediaType" => "video/mp4",
                       "type" => "Link"
                     }
                   ]
                 },
                 %{
                   "mediaType" => "video/mp4",
                   "type" => "Document",
                   "url" => [
                     %{
                       "href" => "https://pe.er/stat-480.mp4",
                       "mediaType" => "video/mp4",
                       "type" => "Link"
                     }
                   ]
                 }
               ]
             }
    end

    test "returns modified object when url is list" do
      assert Transformer.fix_attachments(%{
               "attachment" => %{
                 "type" => "Video",
                 "url" => [
                   %{
                     "type" => "Link",
                     "href" => "https://pe.er/stat-480.mp4"
                   }
                   # TODO
                   # %{
                   #   "href"=> "https://pe.er/stat-480.mp4"
                   # }
                 ]
               }
             }) == %{
               "attachment" => [
                 %{
                   #  "mediaType" => "video/mp4",
                   "type" => "Video",
                   "url" => [
                     %{
                       "href" => "https://pe.er/stat-480.mp4",
                       #  "mediaType" => "video/mp4",
                       "type" => "Link"
                     }
                   ]
                 }
                 #  %{
                 #    "mediaType" => "video/mp4",
                 #    "type" => "Video",
                 #    "url" => [
                 #      %{
                 #        "href" => "https://pe.er/stat-480.mp4",
                 #       #  "mediaType" => "video/mp4",
                 #        "type" => "Link"
                 #      }
                 #    ]
                 #  }
               ]
             }
    end

    test "returns modified object when url is link object" do
      assert Transformer.fix_attachments(%{
               "attachment" => %{
                 "type" => "Video",
                 "url" => %{
                   "type" => "Link",
                   "href" => "https://pe.er/stat-480.mp4"
                 }
               }
             }) == %{
               "attachment" => [
                 %{
                   #  "mediaType" => "video/mp4",
                   "type" => "Video",
                   "url" => [
                     %{
                       "href" => "https://pe.er/stat-480.mp4",
                       #  "mediaType" => "video/mp4",
                       "type" => "Link"
                     }
                   ]
                 }
               ]
             }
    end
  end

  describe "fix_emoji/1" do
    test "returns not modified object when object not contains tags" do
      data = Jason.decode!(file("fixtures/mastodon/mastodon-post-activity.json"))
      assert Transformer.fix_emoji(data) == data
    end

    test "returns object with emoji when object contains list tags" do
      assert Transformer.fix_emoji(%{
               "tag" => [
                 %{"type" => "Emoji", "name" => ":bib:", "icon" => %{"url" => "/test"}},
                 %{"type" => "Hashtag"}
               ]
             }) == %{
               "emoji" => %{"bib" => "/test"},
               "tag" => [
                 %{"icon" => %{"url" => "/test"}, "name" => ":bib:", "type" => "Emoji"},
                 %{"type" => "Hashtag"}
               ]
             }
    end

    test "returns object with emoji when object contains map tag" do
      assert Transformer.fix_emoji(%{
               "tag" => %{"type" => "Emoji", "name" => ":bib:", "icon" => %{"url" => "/test"}}
             }) == %{
               "emoji" => %{"bib" => "/test"},
               "tag" => %{"icon" => %{"url" => "/test"}, "name" => ":bib:", "type" => "Emoji"}
             }
    end
  end

  @tag :todo
  test "take_emoji_tags/1" do
    user = local_actor(%{emoji: %{"firefox" => "https://exampleorg.local/firefox.png"}})

    assert Transformer.take_emoji_tags(user) == [
             %{
               "icon" => %{"type" => "Image", "url" => "https://exampleorg.local/firefox.png"},
               "id" => "https://exampleorg.local/firefox.png",
               "name" => ":firefox:",
               "type" => "Emoji",
               "updated" => "1970-01-01T00:00:00Z"
             }
           ]
  end
end
