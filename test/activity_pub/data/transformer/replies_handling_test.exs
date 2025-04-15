# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.RepliesHandlingTest do
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
    # clear_config([:instance, :max_remote_account_fields])
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

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
      {:ok, returned_activity} = Transformer.handle_incoming(data)
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
    #     allowed_recursion?: fn _ -> false end do
    #     {:ok, returned_activity} = Transformer.handle_incoming(data)

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

      assert {:ok, _returned_activity} = Transformer.handle_incoming(data)
    end
  end

  describe "`handle_incoming/2`, Mastodon format `replies` handling" do
    setup do
      clear_config([:activity_pub, :note_replies_output_limit], 5)
      clear_config([:instance, :federation_incoming_max_recursion])

      data =
        "fixtures/mastodon/mastodon-post-activity.json"
        |> file()
        |> Jason.decode!()

      items = get_in(data, ["object", "replies", "first", "items"])
      assert is_list(items) and items != []

      %{data: data, items: items}
    end

    test "schedules background fetching of `replies` items if max thread depth limit allows", %{
      data: data,
      items: items
    } do
      clear_config([:instance, :federation_incoming_max_recursion], 10)

      {:ok, activity} = Transformer.handle_incoming(data)
      object = Object.normalize(activity.data["object"])

      assert object.data["replies"] == items

      _jobs =
        for {id, i} <- Enum.with_index(items) do
          job_args = %{"op" => "fetch_remote", "id" => id, "depth" => i + 1, "repo" => repo()}
          assert_enqueued(worker: Workers.RemoteFetcherWorker, args: job_args)
        end
    end

    test "does NOT schedule background fetching of `replies` beyond max thread depth limit allows",
         %{data: data} do
      clear_config([:instance, :federation_incoming_max_recursion], 0)

      {:ok, _activity} = Transformer.handle_incoming(data)

      assert all_enqueued(worker: Workers.RemoteFetcherWorker) == []
    end
  end

  describe "`handle_incoming/2`, Akomma/Pleroma format `replies` handling" do
    setup do
      clear_config([:activity_pub, :note_replies_output_limit], 5)
      clear_config([:instance, :federation_incoming_max_recursion])

      replies = %{
        "type" => "Collection",
        "items" => [
          "https://mstdn.local/users/mayuutann/statuses/99568293732299394",
          "https://mocked.local/users/emelie/statuses/101849165031453009"
        ]
      }

      activity =
        file("fixtures/mastodon/mastodon-post-activity.json")
        |> Poison.decode!()
        |> Kernel.put_in(["object", "replies"], replies)

      %{activity: activity}
    end

    @tag :fixme
    test "schedules background fetching of `replies` items if max thread depth limit allows", %{
      activity: activity
    } do
      clear_config([:instance, :federation_incoming_max_recursion], 3)

      assert {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(activity)
      object = Object.normalize(data["object"])

      for {id, i} <- Enum.with_index(object.data["replies"]) do
        job_args = %{"op" => "fetch_remote", "id" => id, "depth" => i + 1, "repo" => repo()}
        assert_enqueued(worker: Workers.RemoteFetcherWorker, args: job_args)
      end

      assert length(all_enqueued(worker: Workers.RemoteFetcherWorker)) == 2
    end

    @tag :fixme
    test "schedules *recursive* background fetching of replies if limit allows", %{
      activity: activity
    } do
      clear_config([:instance, :federation_incoming_max_recursion], 2)

      assert {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(activity)
      object = Object.normalize(data["object"])

      for {id, i} <- Enum.with_index(object.data["replies"]) do
        job_args = %{"op" => "fetch_remote", "id" => id, "depth" => i + 1, "repo" => repo()}
        assert_enqueued(worker: Workers.RemoteFetcherWorker, args: job_args)
        perform_job(Workers.RemoteFetcherWorker, job_args)
      end

      assert length(all_enqueued(worker: Workers.RemoteFetcherWorker)) == 3
    end

    test "does NOT schedule background fetching of `replies` beyond max thread depth limit allows",
         %{activity: activity} do
      clear_config([:instance, :federation_incoming_max_recursion], 0)

      {:ok, _activity} = Transformer.handle_incoming(activity)

      assert all_enqueued(worker: Workers.RemoteFetcherWorker) == []
    end

    test "does NOT schedule *recursive* background fetching of `replies` beyond what the max items limit allows",
         %{activity: activity} do
      limit = 1
      # clear_config([:instance, :federation_incoming_max_recursion], limit)
      clear_config([:instance, :federation_incoming_max_items], limit)

      already_enqueued =
        length(all_enqueued(worker: Workers.RemoteFetcherWorker))
        |> debug("already_enqueued")

      {:ok, %Activity{data: data}} = Transformer.handle_incoming(activity)
      object = Object.normalize(data["object"])

      replies = object.data["replies"]
      replies_length = length(replies)

      all_enqueued =
        all_enqueued(worker: Workers.RemoteFetcherWorker)
        |> debug("all_enqueued")

      assert length(all_enqueued) == already_enqueued + limit
    end

    test "does NOT execute scheduled *recursive* background fetching of `replies` beyond what the max recursion limit allows",
         %{activity: activity} do
      clear_config([:instance, :federation_incoming_max_recursion], 0)
      clear_config([:instance, :federation_incoming_max_items], 0)

      already_enqueued =
        length(all_enqueued(worker: Workers.RemoteFetcherWorker))
        |> debug("already_enqueued")

      {:ok, %Activity{data: data}} = Transformer.handle_incoming(activity)
      object = Object.normalize(data["object"])

      replies = object.data["replies"]
      replies_length = length(replies)

      limit = 1
      clear_config([:instance, :federation_incoming_max_recursion], limit)

      for {id, i} <- Enum.with_index(replies) do
        # check enqueued jobs
        job_args = %{"op" => "fetch_remote", "id" => id, "depth" => i + 1, "repo" => repo()}

        ActivityPub.Federator.Fetcher.enqueue_fetch(
          id,
          job_args
        )

        if i == 0 do
          assert {:ok, _} =
                   perform_job(Workers.RemoteFetcherWorker, job_args) |> debug("performed #{i}")
        else
          assert {:error, _} =
                   perform_job(Workers.RemoteFetcherWorker, job_args)
                   |> debug("not performed #{i}")
        end
      end
    end
  end

  describe "re-serialization" do
    test "successfully re-serializes a message with inReplyTo == nil" do
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

      {:ok, activity} = Transformer.handle_incoming(message)

      {:ok, _} = Transformer.prepare_outgoing(activity.data)
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
            %{"name" => "#2hu", "href" => "http://mastodon.local/2hu", "type" => "Hashtag"},
            %{"name" => "Bob", "href" => "https://testing.local/users/karen", "type" => "Mention"}
          ]
        },
        "actor" => ap_id(user)
      }

      {:ok, activity} = Transformer.handle_incoming(message)

      {:ok, _} = Transformer.prepare_outgoing(activity.data)
    end
  end

  describe "fix_in_reply_to/2" do
    setup do
      clear_config([:instance, :federation_incoming_max_recursion])
      data = Jason.decode!(file("fixtures/mastodon/mastodon-post-activity.json"))
      [data: data]
    end

    test "returns not modified object when hasn't containts inReplyTo field", %{data: data} do
      assert Transformer.fix_in_reply_to(data) == data
    end

    test "returns object with inReplyTo when denied incoming reply", %{data: data} do
      clear_config([:instance, :federation_incoming_max_recursion], 0)

      object_with_reply =
        Map.put(data["object"], "inReplyTo", "https://sposter.local/notice/2827873")

      modified_object = Transformer.fix_in_reply_to(object_with_reply)
      assert modified_object["inReplyTo"] == "https://sposter.local/notice/2827873"

      object_with_reply =
        Map.put(data["object"], "inReplyTo", %{"id" => "https://sposter.local/notice/2827873"})

      modified_object = Transformer.fix_in_reply_to(object_with_reply)
      assert modified_object["inReplyTo"] == "https://sposter.local/notice/2827873"

      object_with_reply =
        Map.put(data["object"], "inReplyTo", ["https://sposter.local/notice/2827873"])

      modified_object = Transformer.fix_in_reply_to(object_with_reply)
      assert modified_object["inReplyTo"] == "https://sposter.local/notice/2827873"

      object_with_reply = Map.put(data["object"], "inReplyTo", [])
      modified_object = Transformer.fix_in_reply_to(object_with_reply)
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

      clear_config([:instance, :federation_incoming_max_recursion], 5)
      modified_object = Transformer.fix_in_reply_to(object_with_reply)

      assert modified_object["inReplyTo"] ==
               "https://mstdn.local/users/mayuutann/statuses/99568293732299394"
    end
  end

  describe "set_replies/1" do
    setup do: clear_config([:activity_pub, :note_replies_output_limit], 2)

    test "returns unmodified object if activity doesn't have self-replies" do
      data = Jason.decode!(file("fixtures/mastodon/mastodon-post-activity.json"))
      assert Transformer.set_replies(data) == data
    end

    test "sets `replies` collection with a limited number of self-replies" do
      [user, another_user] = insert_list(2, :local_actor)

      activity =
        %{data: %{"id" => id1_activity, "object" => id1_object}} =
        insert(:note_activity, %{actor: user, status: "1"})

      # |> debug("aaaa")

      insert(:note_activity, %{
        "inReplyTo" => id1_object,
        actor: another_user,
        status: "another user's reply"
      })

      # should _not_ be present in `replies` due to :note_replies_output_limit set to 2
      insert(:note_activity, %{"inReplyTo" => id1_object, actor: user, status: "self-reply 3"})

      %{data: %{"id" => id2_activity, "object" => id2_object}} =
        self_reply2 =
        insert(:note_activity, %{"inReplyTo" => id1_object, actor: user, status: "self-reply 1"})
        |> debug("self-reply 1")

      object =
        Object.normalize(activity, fetch: false)
        |> debug("self-reply 1 obj")

      %{data: %{"id" => id3_activity, "object" => id3_object}} =
        self_reply3 =
        insert(:note_activity, %{"inReplyTo" => id1_object, actor: user, status: "self-reply 2"})

      insert(:note_activity, %{
        "inReplyTo" => id2_object,
        actor: user,
        status: "self-reply to self-reply"
      })

      object =
        Object.normalize(activity, fetch: false)
        |> debug("normalized")

      prepped =
        Transformer.set_replies(object)
        |> debug("prepped")

      # FIXME
      assert Enum.sort([id2_activity, id3_activity]) == Enum.sort(prepped["replies"]["items"])
      # assert Enum.sort([id2_object, id3_object]) == Enum.sort(prepped["replies"]["items"])
    end
  end
end
