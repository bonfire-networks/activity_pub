# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.FetcherTest do
  use ActivityPub.DataCase

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Instances
  alias ActivityPub.Object
  alias ActivityPub.Fetcher

  alias ActivityPub.Test.HttpRequestMock

  import Mock
  import Tesla.Mock

  @public_uri "https://www.w3.org/ns/activitystreams#Public"
  @sample_object "{\"actor\": \"https://mocked.local/users/karen\", \"id\": \"https://mocked.local/2\", \"to\": \"#{@public_uri}\"}"

  setup do
    mock(fn
      %{method: :get, url: "https://mastodon.local/users/userisgone"} ->
        %Tesla.Env{status: 410}

      %{method: :get, url: "https://mastodon.local/users/userisgone404"} ->
        %Tesla.Env{status: 404}

      %{
        method: :get,
        url:
          "https://patch.local/media/03ca3c8b4ac3ddd08bf0f84be7885f2f88de0f709112131a22d83650819e36c2.json"
      } ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "application/json"}],
          body: file("fixtures/spoofed-object.json")
        }

      env ->
        apply(HttpRequestMock, :request, [env])
    end)

    :ok
  end

  describe "error cases" do
    setup do
      mock(fn
        %{method: :get, url: "https://sakamoto.local/notice/9wTkLEnuq47B25EehM"} ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/fetch_mocks/9wTkLEnuq47B25EehM.json"),
            headers: HttpRequestMock.activitypub_object_headers()
          }

        %{method: :get, url: "https://sakamoto.local/users/eal"} ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/fetch_mocks/eal.json"),
            headers: HttpRequestMock.activitypub_object_headers()
          }

        %{method: :get, url: "https://busshi.local/users/tuxcrafting/statuses/104410921027210069"} ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/fetch_mocks/104410921027210069.json"),
            headers: HttpRequestMock.activitypub_object_headers()
          }

        %{method: :get, url: "https://busshi.local/users/tuxcrafting"} ->
          %Tesla.Env{
            status: 500
          }

        %{
          method: :get,
          url: "https://stereophonic.space/objects/02997b83-3ea7-4b63-94af-ef3aa2d4ed17"
        } ->
          %Tesla.Env{
            status: 500
          }

          env ->
          apply(HttpRequestMock, :request, [env])
      end)

      :ok
    end

    @tag capture_log: true
    test "it works when fetching the OP actor errors out" do
      # Here we simulate a case where the author of the OP can't be read
      assert {:ok, _} =
               Fetcher.fetch_object_from_id(
                 "https://sakamoto.local/notice/9wTkLEnuq47B25EehM"
               )
    end
  end

  describe "actor origin containment" do
    test "it rejects objects with a bogus origin" do
      {:error, _} = Fetcher.fetch_object_from_id("https://akkoma.local/activity.json")
    end

    test "it rejects objects when attributedTo is wrong (variant 1)" do
      {:error, _} = Fetcher.fetch_object_from_id("https://akkoma.local/activity2.json")
    end

    test "it rejects objects when attributedTo is wrong (variant 2)" do
      {:error, _} = Fetcher.fetch_object_from_id("https://akkoma.local/activity3.json")
    end
  end

  describe "fetching an object" do
    test "it fetches an object by URL or canonical ID" do
      {:ok, object} =
        Fetcher.fetch_object_from_id("https://mastodon.local/@admin/99541947525187367")

      assert _activity = Activity.get_cached(ap_id: object.data["id"])

      # TODO?
      # assert [attachment] = object.data["attachment"]
      # assert is_list(attachment["url"])

      {:ok, object_by_id} =
        Fetcher.fetch_object_from_id("https://mastodon.local/users/admin/statuses/99541947525187367")

      assert object == object_by_id

      {:ok, object_again} =
        Fetcher.fetch_object_from_id("https://mastodon.local/@admin/99541947525187367")

      assert object == object_again
    end

    @tag :todo
    test "Return MRF reason when fetched status is rejected by one" do
      clear_config([:mrf_keyword, :reject], ["yeah"])
      clear_config([:mrf, :policies], [ActivityPubWeb.MRF.KeywordPolicy])

      assert {:reject, "[KeywordPolicy] Matches with rejected keyword"} ==
               Fetcher.fetch_object_from_id(
                 "https://mastodon.local/@admin/99541947525187367"
               )
    end

    test "it does not fetch a spoofed object uploaded on an instance as an attachment" do
      assert {:error, _} =
               Fetcher.fetch_object_from_id(
                 "https://patch.local/media/03ca3c8b4ac3ddd08bf0f84be7885f2f88de0f709112131a22d83650819e36c2.json"
               )
    end

    test "does not fetch anything from a rejected instance" do
      clear_config([:mrf_simple, :reject], ["evil.example.org", "i said so"])

      assert {:reject, _} =
               Fetcher.fetch_object_from_id("http://evil.example.org/@admin/99541947525187367")
    end

    @tag :todo 
    test "does not fetch anything if mrf_simple accept is on" do
      clear_config([:mrf_simple, :accept], [{"mastodon.local", "i said so"}])
      clear_config([:mrf_simple, :reject], [])

      assert {:reject, _} =
               Fetcher.fetch_object_from_id(
                 "http://notlisted.example.org/@admin/99541947525187367"
               )

      assert {:ok, _object} =
               Fetcher.fetch_object_from_id(
                 "https://mastodon.local/@admin/99541947525187367"
               )
    end

    test "it resets instance reachability on successful fetch" do
      id = "https://mastodon.local/@admin/99541947525187367"
      Instances.set_consistently_unreachable(id)
      refute Instances.reachable?(id)

      {:ok, _object} =
        Fetcher.fetch_object_from_id("https://mastodon.local/@admin/99541947525187367")

      assert Instances.reachable?(id)
    end 
  end

  describe "implementation quirks" do
    test "it can fetch plume articles" do
      {:ok, object} =
        Fetcher.fetch_object_from_id(
          "https://xyz.local/~/PlumeDevelopment/this-month-in-plume-june-2018/"
        )

      assert object
    end

    test "it can fetch peertube videos" do
      {:ok, object} =
        Fetcher.fetch_object_from_id(
          "https://peertube2.local/videos/watch/df5f464b-be8d-46fb-ad81-2d4c2d1630e3"
        )

      assert object
    end

    test "it can fetch Mobilizon events" do
      {:ok, object} =
        Fetcher.fetch_object_from_id(
          "https://mobilizon.local/events/252d5816-00a3-4a89-a66f-15bf65c33e39"
        )

      assert object
    end

    test "it can fetch wedistribute articles" do
      {:ok, object} =
        Fetcher.fetch_object_from_id("https://wedistribute.local/wp-json/pterotype/v1/object/85810")

      assert object
    end

    test "all objects with fake directions are rejected by the object fetcher" do
      assert {:error, _} =
               Fetcher.fetch_object_from_id(
                 "https://akkoma.local/activity4.json"
               )
    end

    test "handle HTTP 410 Gone response" do
      # TODO: {:error, {"Object has been deleted", "https://mastodon.local/users/userisgone", 410}}
      assert {:error, _} =
               Fetcher.fetch_object_from_id(
                 "https://mastodon.local/users/userisgone"
               )
    end

    test "handle HTTP 404 response" do
      # TODO: assert {:error, {"Object has been deleted", "https://mastodon.local/users/userisgone404", 404}} == 
      assert {:error, _} =
               Fetcher.fetch_object_from_id(
                 "https://mastodon.local/users/userisgone404"
               )
    end

    test "it can fetch pleroma polls with attachments" do
      {:ok, object} =
        Fetcher.fetch_object_from_id("https://patch.local/objects/tesla_mock/poll_attachment")

      assert object
    end
  end

  describe "pruning" do
    test "it can refetch pruned objects" do
      object_id = "https://mastodon.local/@admin/99541947525187367"

      {:ok, object_one} = Fetcher.fetch_object_from_id(object_id)
      # FIXME: re-fetch gives un activity rather than object?
      # {:ok, %Object{} = object_one} = Fetcher.fetch_object_from_id(object_id)

      assert object_one

      {:ok, _object} = Object.hard_delete(object_one)

      refute Object.get_cached!(ap_id: object_id)

      {:ok, %Object{} = object_two} = Fetcher.fetch_object_from_id(object_id)

      assert object_one.data["id"] == object_two.data["id"]
      # assert object_one.id != object_two.id
    end
  end

  describe "signed fetches" do
    setup do: clear_config([:activitypub, :sign_object_fetches])

    test_with_mock "it signs fetches when configured to do so",
                   ActivityPub.Signature,
                   [:passthrough],
                   [] do
      clear_config([:activitypub, :sign_object_fetches], true)

      Fetcher.fetch_object_from_id("https://mastodon.local/@admin/99541947525187367")

      assert called(ActivityPub.Signature.sign(:_, :_))
    end

    test_with_mock "it doesn't sign fetches when not configured to do so",
                   ActivityPub.Signature,
                   [:passthrough],
                   [] do
      clear_config([:activitypub, :sign_object_fetches], false)

      Fetcher.fetch_object_from_id("https://mastodon.local/@admin/99541947525187367")

      refute called(ActivityPub.Signature.sign(:_, :_))
    end
  end

  describe "refetching" do
    setup do
      object1 = %{
        "id" => "https://mocked.local/1",
        "actor" => "https://mocked.local/users/emelie",
        "attributedTo" => "https://mocked.local/users/emelie",
        "type" => "Note",
        "content" => "test 1",
        "bcc" => [],
        "bto" => [],
        "cc" => [],
"to" => @public_uri,
        "summary" => ""
      }

      object2 = %{
        "id" => "https://mocked.local/2",
        "actor" => "https://mocked.local/users/emelie",
        "attributedTo" => "https://mocked.local/users/emelie",
        "type" => "Note",
        "content" => "test 2",
        "bcc" => [],
        "bto" => [],
        "cc" => [],
"to" => @public_uri,
        "summary" => "",
        "formerRepresentations" => %{
          "type" => "OrderedCollection",
          "orderedItems" => [
            %{
              "type" => "Note",
              "content" => "orig 2",
              "actor" => "https://mocked.local/users/emelie",
              "attributedTo" => "https://mocked.local/users/emelie",
              "bcc" => [],
              "bto" => [],
              "cc" => [],
              "to" => [],
              "summary" => ""
            }
          ],
          "totalItems" => 1
        }
      }

      mock(fn
        %{
          method: :get,
          url: "https://mocked.local/1"
        } ->
          %Tesla.Env{
            status: 200,
            headers: [{"content-type", "application/activity+json"}],
            body: Jason.encode!(object1)
          }

        %{
          method: :get,
          url: "https://mocked.local/2"
        } ->
          %Tesla.Env{
            status: 200,
            headers: [{"content-type", "application/activity+json"}],
            body: Jason.encode!(object2)
          }

        %{
          method: :get,
          url: "https://mocked.local/users/emelie/collections/featured"
        } ->
          %Tesla.Env{
            status: 200,
            headers: [{"content-type", "application/activity+json"}],
            body:
              Jason.encode!(%{
                "id" => "https://mocked.local/users/emelie/collections/featured",
                "type" => "OrderedCollection",
                "actor" => "https://mocked.local/users/emelie",
                "attributedTo" => "https://mocked.local/users/emelie",
                "orderedItems" => [],
                "totalItems" => 0
              })
          }

        env ->
          apply(HttpRequestMock, :request, [env])
      end)

      %{object1: object1, object2: object2}
    end

    test "it keeps formerRepresentations if remote does not have this attr", %{object1: object1} do
      full_object1 =
        object1
        |> Map.merge(%{
          "formerRepresentations" => %{
            "type" => "OrderedCollection",
            "orderedItems" => [
              %{
                "type" => "Note",
                "content" => "orig 2",
                "actor" => "https://mocked.local/users/emelie",
                "attributedTo" => "https://mocked.local/users/emelie",
                "bcc" => [],
                "bto" => [],
                "cc" => [],
                "to" => @public_uri,
                "summary" => ""
              }
            ],
            "totalItems" => 1
          }
        })

      {:ok, o} = Object.insert(full_object1, false)

      assert {:ok, refetched} = Fetcher.fetch_fresh_object_from_id(o)
      # assert {:ok, refetched} = Fetcher.refetch_object(o)

      assert %{"formerRepresentations" => %{"orderedItems" => [%{"content" => "orig 2"}]}} =
               refetched.data
    end

    test "it uses formerRepresentations from remote if possible", %{object2: object2} do
      {:ok, o} = Object.insert(object2, false)

      assert {:ok, refetched} = Fetcher.fetch_fresh_object_from_id(o)
      # assert {:ok, refetched} = Fetcher.refetch_object(o)

      assert %{"formerRepresentations" => %{"orderedItems" => [%{"content" => "orig 2"}]}} =
               refetched.data
    end

    @tag :todo
    test "it replaces formerRepresentations with the one from remote", %{object2: object2} do
      full_object2 =
        object2
        |> Map.merge(%{
          "content" => "mew mew #def",
          "formerRepresentations" => %{
            "type" => "OrderedCollection",
            "orderedItems" => [
              %{"type" => "Note", "content" => "mew mew 2"}
            ],
            "totalItems" => 1
          }
        })

      {:ok, o} = Object.insert(full_object2, false)

      assert {:ok, refetched} = Fetcher.fetch_fresh_object_from_id(o)
      # assert {:ok, refetched} = Fetcher.refetch_object(o)

      assert %{
               "content" => "test 2",
               "formerRepresentations" => %{"orderedItems" => [%{"content" => "orig 2"}]}
             } = refetched.data
    end

    @tag :todo
    test "it adds to formerRepresentations if the remote does not have one and the object has changed",
         %{object1: object1} do
      full_object1 =
        object1
        |> Map.merge(%{
          "content" => "mew mew #def",
          "formerRepresentations" => %{
            "type" => "OrderedCollection",
            "orderedItems" => [
              %{"type" => "Note", "content" => "mew mew 1", "to"=>@public_uri}
            ],
            "totalItems" => 1
          }
        })

      {:ok, o} = Object.insert(full_object1, false)

      assert {:ok, refetched} = Fetcher.fetch_fresh_object_from_id(o)
      # assert {:ok, refetched} = Fetcher.refetch_object(o)

      assert %{
               "content" => "test 1",
               "formerRepresentations" => %{
                 "orderedItems" => [
                   %{"content" => "mew mew #def"},
                   %{"content" => "mew mew 1"}
                 ],
                 "totalItems" => 2
               }
             } = refetched.data
    end
  end

  describe "fetch with history" do
    setup do
      object2 = %{
        "id" => "https://mocked.local/2",
        "actor" => "https://mocked.local/users/emelie",
        "attributedTo" => "https://mocked.local/users/emelie",
        "type" => "Note",
        "content" => "test 2",
        "bcc" => [],
        "bto" => [],
        "cc" => ["https://mocked.local/users/emelie/followers"],
        "to" => [],
        "summary" => "",
        "formerRepresentations" => %{
          "type" => "OrderedCollection",
          "orderedItems" => [
            %{
              "type" => "Note",
              "content" => "orig 2",
              "actor" => "https://mocked.local/users/emelie",
              "attributedTo" => "https://mocked.local/users/emelie",
              "bcc" => [],
              "bto" => [],
              "cc" => ["https://mocked.local/users/emelie/followers"],
              "to" => [],
              "summary" => ""
            }
          ],
          "totalItems" => 1
        }
      }

      mock(fn
        %{
          method: :get,
          url: "https://mocked.local/2"
        } ->
          %Tesla.Env{
            status: 200,
            headers: [{"content-type", "application/activity+json"}],
            body: Jason.encode!(object2)
          }

        %{
          method: :get,
          url: "https://mocked.local/users/emelie/collections/featured"
        } ->
          %Tesla.Env{
            status: 200,
            headers: [{"content-type", "application/activity+json"}],
            body:
              Jason.encode!(%{
                "id" => "https://mocked.local/users/emelie/collections/featured",
                "type" => "OrderedCollection",
                "actor" => "https://mocked.local/users/emelie",
                "attributedTo" => "https://mocked.local/users/emelie",
                "orderedItems" => [],
                "totalItems" => 0
              })
          }

        env ->
          apply(HttpRequestMock, :request, [env])
      end)

      %{object2: object2}
    end

    test "it gets history", %{object2: object2} do
      {:ok, object} = Fetcher.fetch_object_from_id(object2["id"])

      assert %{
               "formerRepresentations" => %{
                 "type" => "OrderedCollection",
                 "orderedItems" => [%{}]
               }
             } = object.data
    end
  end

  describe "get_object/1" do
    test "should return ok if the content type is application/activity+json" do
      Tesla.Mock.mock(fn
        %{
          method: :get,
          url: "https://mocked.local/2"
        } ->
          %Tesla.Env{
            status: 200,
            headers: [{"content-type", "application/activity+json"}],
            body: @sample_object
          }
        env ->
          apply(HttpRequestMock, :request, [env])
      end)

      assert {:ok, _} = Fetcher.fetch_object_from_id("https://mocked.local/2")
    end

    test "should return ok if the content type is application/ld+json with a profile" do
      Tesla.Mock.mock(fn
        %{
          method: :get,
          url: "https://mocked.local/2"
        } ->
          %Tesla.Env{
            status: 200,
            headers: [
              {"content-type",
               "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""}
            ],
            body: @sample_object
          }
          env ->
          apply(HttpRequestMock, :request, [env])
      end)

      assert {:ok, _} = Fetcher.fetch_object_from_id("https://mocked.local/2")

      Tesla.Mock.mock(fn
        %{
          method: :get,
          url: "https://mocked.local/2"
        } ->
          %Tesla.Env{
            status: 200,
            headers: [
              {"content-type",
               "application/ld+json; profile=\"http://www.w3.org/ns/activitystreams\""}
            ],
            body: @sample_object
          }
          env ->
          apply(HttpRequestMock, :request, [env])
      end)

      assert {:ok, _} = Fetcher.fetch_object_from_id("https://mocked.local/2")
    end

    # test "should not return ok with other content types" do
    #   Tesla.Mock.mock(fn
    #     %{
    #       method: :get,
    #       url: "https://mocked.local/2"
    #     } ->
    #       %Tesla.Env{
    #         status: 200,
    #         headers: [{"content-type", "text/plain"}],
    #         body: @sample_object
    #       }
    #       env ->
    #       apply(HttpRequestMock, :request, [env])
    #   end)

    #   assert {:error, {:content_type, "text/plain"}} =
    #            Fetcher.fetch_object_from_id("https://mocked.local/2")
    # end
  end
end
