# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.Transmogrifier.RepliesHandlingTest do
    use ActivityPub.DataCase
use Oban.Testing, repo: repo()

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object
  alias ActivityPubWeb.Transmogrifier
  alias ActivityPub.Utils
  alias ActivityPub.Fetcher
  alias ActivityPub.Test.HttpRequestMock
  alias ActivityPub.Workers

  import Mock
  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  setup do: clear_config([:instance, :max_remote_account_fields])

  describe "handle_incoming" do

    @tag capture_log: true
    test "it fetches reply-to activities if we don't have them" do
      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Jason.decode!()

      object =
        data["object"]
        |> Map.put("inReplyTo", "https://mstdn.local/users/mayuutann/statuses/99568293732299394")

      data = Map.put(data, "object", object)
      {:ok, returned_activity} = Transmogrifier.handle_incoming(data)
      returned_object = Object.normalize(returned_activity, fetch: false)

      assert {:ok, %Object{}} =
               Fetcher.fetch_object_from_id(
                 "https://mstdn.local/users/mayuutann/statuses/99568293732299394"
               )

      assert returned_object.data["inReplyTo"] ==
               "https://mstdn.local/users/mayuutann/statuses/99568293732299394"
    end

    # TODO
    # test "it does not fetch reply-to activities beyond max replies depth limit" do
    #   data =
    #     file("fixtures/mastodon/mastodon-post-activity.json")
    #     |> Jason.decode!()

    #   object =
    #     data["object"]
    #     |> Map.put("inReplyTo", "https://sposter.local/notice/2827873")

    #   data = Map.put(data, "object", object)

    #   with_mock Federator,
    #     allowed_thread_distance?: fn _ -> false end do
    #     {:ok, returned_activity} = Transmogrifier.handle_incoming(data)

    #     returned_object = Object.normalize(returned_activity, fetch: false)

    #     refute Fetcher.fetch_object_from_id(
    #              "tag:shitposter.club,2017-05-05:noticeId=2827873:objectType=comment"
    #            )

    #     assert returned_object.data["inReplyTo"] == "https://sposter.local/notice/2827873"
    #   end
    # end

    test "it does not crash if the object in inReplyTo can't be fetched" do
      data =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Jason.decode!()

      object =
        data["object"]
        |> Map.put("inReplyTo", "https://404.site/whatever")

      data =
        data
        |> Map.put("object", object)

      assert {:ok, _returned_activity} = Transmogrifier.handle_incoming(data)
    end

  end

  describe "`handle_incoming/2`, Mastodon format `replies` handling" do
    setup do: clear_config([:activitypub, :note_replies_output_limit], 5)
    setup do: clear_config([:instance, :federation_incoming_replies_max_depth])

    setup do
      data =
        "fixtures/mastodon/mastodon-post-activity.json"
        |> file()
        |> Jason.decode!()

      items = get_in(data, ["object", "replies", "first", "items"])
      assert is_list(items) and items !=[]

      %{data: data, items: items}
    end

    test "schedules background fetching of `replies` items if max thread depth limit allows", %{
      data: data,
      items: items
    } do
      clear_config([:instance, :federation_incoming_replies_max_depth], 10)

      {:ok, activity} = Transmogrifier.handle_incoming(data)
      object = Object.normalize(activity.data["object"])

      assert object.data["replies"] == items

      for id <- items do
        job_args = %{"op" => "fetch_remote", "id" => id, "depth" => 1}
        assert_enqueued(worker: Workers.RemoteFetcherWorker, args: job_args)
      end
    end

    test "does NOT schedule background fetching of `replies` beyond max thread depth limit allows",
         %{data: data} do
      clear_config([:instance, :federation_incoming_replies_max_depth], 0)

      {:ok, _activity} = Transmogrifier.handle_incoming(data)

      assert all_enqueued(worker: Workers.RemoteFetcherWorker) == []
    end
  end

  describe "`handle_incoming/2`, Pleroma format `replies` handling" do
    setup do: clear_config([:activitypub, :note_replies_output_limit], 5)
    setup do: clear_config([:instance, :federation_incoming_replies_max_depth])

    setup do
      replies = %{
        "type" => "Collection",
        "items" => [Utils.generate_object_id(), Utils.generate_object_id()]
      }

      activity =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Poison.decode!()
        |> Kernel.put_in(["object", "replies"], replies)

      %{activity: activity}
    end

    test "schedules background fetching of `replies` items if max thread depth limit allows", %{
      activity: activity
    } do
      clear_config([:instance, :federation_incoming_replies_max_depth], 1)

      assert {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(activity)
      object = Object.normalize(data["object"])

      for id <- object.data["replies"] do
        debug(id, "id")
        job_args = %{"op" => "fetch_remote", "id" => id, "depth" => 1}
        assert_enqueued(worker: Workers.RemoteFetcherWorker, args: job_args)
      end
    end

    test "does NOT schedule background fetching of `replies` beyond max thread depth limit allows",
         %{activity: activity} do
      clear_config([:instance, :federation_incoming_replies_max_depth], 0)

      {:ok, _activity} = Transmogrifier.handle_incoming(activity)

      assert all_enqueued(worker: Workers.RemoteFetcherWorker) == []
    end
  end

  describe "reserialization" do
    test "successfully reserializes a message with inReplyTo == nil" do
      user = local_actor()

      message = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "type" => "Create",
        "object" => %{
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [],
          "id" => Utils.generate_object_id(),
          "type" => "Note",
          "content" => "Hi",
          "inReplyTo" => nil,
          "attributedTo" => ap_id(user)
        },
        "actor" => ap_id(user)
      }

      {:ok, activity} = Transmogrifier.handle_incoming(message)

      {:ok, _} = Transmogrifier.prepare_outgoing(activity.data)
    end

    test "successfully reserializes a message with AS2 objects in IR" do
      user = local_actor()

      message = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "type" => "Create",
        "object" => %{
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [],
          "id" => Utils.generate_object_id(),
          "type" => "Note",
          "content" => "Hi",
          "inReplyTo" => nil,
          "attributedTo" => ap_id(user),
          "tag" => [
            %{"name" => "#2hu", "href" => "http://example.local/2hu", "type" => "Hashtag"},
            %{"name" => "Bob", "href" => "http://example.local/bob", "type" => "Mention"}
          ]
        },
        "actor" => ap_id(user)
      }

      {:ok, activity} = Transmogrifier.handle_incoming(message)

      {:ok, _} = Transmogrifier.prepare_outgoing(activity.data)
    end
  end

  describe "fix_in_reply_to/2" do
    setup do: clear_config([:instance, :federation_incoming_replies_max_depth])

    setup do
      data = Jason.decode!(file("fixtures/mastodon/mastodon-post-activity.json"))
      [data: data]
    end

    test "returns not modified object when hasn't containts inReplyTo field", %{data: data} do
      assert Transmogrifier.fix_in_reply_to(data) == data
    end

    test "returns object with inReplyTo when denied incoming reply", %{data: data} do
      clear_config([:instance, :federation_incoming_replies_max_depth], 0)

      object_with_reply =
        Map.put(data["object"], "inReplyTo", "https://sposter.local/notice/2827873")

      modified_object = Transmogrifier.fix_in_reply_to(object_with_reply)
      assert modified_object["inReplyTo"] == "https://sposter.local/notice/2827873"

      object_with_reply =
        Map.put(data["object"], "inReplyTo", %{"id" => "https://sposter.local/notice/2827873"})

      modified_object = Transmogrifier.fix_in_reply_to(object_with_reply)
      assert modified_object["inReplyTo"] == %{"id" => "https://sposter.local/notice/2827873"}

      object_with_reply =
        Map.put(data["object"], "inReplyTo", ["https://sposter.local/notice/2827873"])

      modified_object = Transmogrifier.fix_in_reply_to(object_with_reply)
      assert modified_object["inReplyTo"] == ["https://sposter.local/notice/2827873"]

      object_with_reply = Map.put(data["object"], "inReplyTo", [])
      modified_object = Transmogrifier.fix_in_reply_to(object_with_reply)
      assert modified_object["inReplyTo"] == []
    end

    @tag capture_log: true
    test "returns modified object when allowed incoming reply", %{data: data} do
      object_with_reply =
        Map.put(
          data["object"],
          "inReplyTo",
          "https://mstdn.local/users/mayuutann/statuses/99568293732299394"
        )

      clear_config([:instance, :federation_incoming_replies_max_depth], 5)
      modified_object = Transmogrifier.fix_in_reply_to(object_with_reply)

      assert modified_object["inReplyTo"] ==
               "https://mstdn.local/users/mayuutann/statuses/99568293732299394"

      assert modified_object["context"] ==
               "tag:shitposter.club,2018-02-22:objectType=thread:nonce=e5a7c72d60a9c0e4"
    end
  end


  describe "set_replies/1" do
    setup do: clear_config([:activitypub, :note_replies_output_limit], 2)

    test "returns unmodified object if activity doesn't have self-replies" do
      data = Jason.decode!(file("fixtures/mastodon/mastodon-post-activity.json"))
      assert Transmogrifier.set_replies(data) == data
    end

    # FIXME!
    test "sets `replies` collection with a limited number of self-replies" do
      [user, another_user] = insert_list(2, :local_actor)

      %{id: _, data: %{"object"=> id1}} = activity = insert(:note_activity, %{actor: user, status: "1"})

      %{id: _, data: %{"object"=> id2}} = self_reply2 =
        insert(:note_activity, %{"inReplyTo"=> id1, actor: user, status: "self-reply 1"})

      %{id: _, data: %{"object"=> id3}} = self_reply3 =
        insert(:note_activity, %{"inReplyTo"=> id1, actor: user, status: "self-reply 2"})

      # should _not_ be present in `replies` due to :note_replies_output_limit set to 2
      insert(:note_activity, %{"inReplyTo"=> id1, actor: user, status: "self-reply 3", })

      
        insert(:note_activity, %{
          "inReplyTo"=> id2,
          actor: user, 
          status: "self-reply to self-reply"
        })

        insert(:note_activity, %{
          "inReplyTo"=> id1,
          actor: another_user, 
          status: "another user's reply"
        })

      object = Object.normalize(activity, fetch: false)
      |> debug("normalized")

      replies_uris = [id2, id3]

      prepped = Transmogrifier.set_replies(object)
      |> debug("prepped")

      assert %{"type" => "Collection", "items" => ^replies_uris} = prepped["replies"]
               
    end
  end


end
