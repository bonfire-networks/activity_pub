# alias ActivityPub.Tests.ObanHelpers
#   alias ActivityPub.Federator.Workers.ReceiverWorker
#     test "mastodon pin/unpin", %{conn: conn} do
#       status_id = "105786274556060421"

#       status =
#         file("fixtures/statuses/masto-note.json")
#         |> String.replace("{{nickname}}", "lain")
#         |> String.replace("{{status_id}}", status_id)

#       status_url = "https://mastodon.local/users/lain/statuses/#{status_id}"
#       replies_url = status_url <> "/replies?only_other_accounts=true&page=true"

#       user =
#         file("fixtures/actor.json")
#         |> String.replace("{{nickname}}", "lain")

#       actor = "https://mastodon.local/users/lain"

#       sender =
#         insert(:actor,
#           ap_id: actor,
#           featured_address: "https://mastodon.local/users/lain/collections/featured"
#         )

#       Tesla.Mock.mock(fn
#         %{
#           method: :get,
#           url: ^status_url
#         } ->
#           %Tesla.Env{
#             status: 200,
#             body: status,
#             headers: [{"content-type", "application/activity+json"}]
#           }

#         %{
#           method: :get,
#           url: ^actor
#         } ->
#           %Tesla.Env{
#             status: 200,
#             body: user,
#             headers: [{"content-type", "application/activity+json"}]
#           }

#         %{method: :get, url: "https://mastodon.local/users/lain/collections/featured"} ->
#           %Tesla.Env{
#             status: 200,
#             body:
#               "fixtures/users_mock/masto_featured.json"
#               |> file()
#               |> String.replace("{{domain}}", "example.com")
#               |> String.replace("{{nickname}}", "lain"),
#             headers: [{"content-type", "application/activity+json"}]
#           }

#         %{
#           method: :get,
#           url: ^replies_url
#         } ->
#           %Tesla.Env{
#             status: 404,
#             body: "",
#             headers: [{"content-type", "application/activity+json"}]
#           }
#       end)

#       data = %{
#         "@context" => "https://www.w3.org/ns/activitystreams",
#         "actor" => actor,
#         "object" => status_url,
#         "target" => "https://mastodon.local/users/lain/collections/featured",
#         "type" => "Add"
#       }

#       assert "ok" ==
#                conn
#                |> assign(:valid_signature, true)
#                |> put_req_header("signature", "keyId=\"#{ap_id(sender)}/main-key\"")
#                |> put_req_header("content-type", "application/activity+json")
#                |> post("#{Utils.ap_base_url()}/shared_inbox", data)
#                |> json_response(200)

#       ObanHelpers.perform(all_enqueued(worker: ReceiverWorker))
#       assert Activity.get_by_object_ap_id_with_object(data["object"])
#       user = user_by_ap_id(data["actor"])
#       assert user.pinned_objects[data["object"]]

#       data = %{
#         "actor" => actor,
#         "object" => status_url,
#         "target" => "https://mastodon.local/users/lain/collections/featured",
#         "type" => "Remove"
#       }

#       assert "ok" ==
#                conn
#                |> assign(:valid_signature, true)
#                |> put_req_header("signature", "keyId=\"#{actor}/main-key\"")
#                |> put_req_header("content-type", "application/activity+json")
#                |> post("#{Utils.ap_base_url()}/shared_inbox", data)
#                |> json_response(200)

#       ObanHelpers.perform(all_enqueued(worker: ReceiverWorker))
#       assert Activity.get_by_object_ap_id_with_object(data["object"])
#       user = refresh_record(user)
#       refute user.pinned_objects[data["object"]]
#     end
#   end

# test "pinned collection", %{conn: conn} do
#     clear_config([:instance, :max_pinned_statuses], 2)
#     user = local_actor()
#     objects = insert_list(2, :note, user: user)

#     Enum.reduce(objects, user, fn %{data: %{"id" => object_id}}, user ->
#       {:ok, updated} = User.add_pinned_object_id(user, object_id)
#       updated
#     end)

#     %{nickname: nickname, featured_address: featured_address, pinned_objects: pinned_objects} =
#       refresh_record(user)

#     %{"id" => ^featured_address, "orderedItems" => items, "totalItems" => 2} =
#       conn
#       |> get("#{Utils.ap_base_url()}/actors/#{nickname}/collections/featured")
#       |> json_response(200)

#     object_ids = Enum.map(items, & &1["id"])

#     assert Enum.all?(pinned_objects, fn {obj_id, _} ->
#              obj_id in object_ids
#            end)
#   end

#     test "fetches user featured collection" do
#       ap_id = "https://mastodon.local/users/lain"

#       featured_url = "https://mastodon.local/users/lain/collections/featured"

#       user_data =
#         "fixtures/actor.json"
#         |> file()
#         |> String.replace("{{nickname}}", "lain")
#         |> Jason.decode!()
#         |> Map.put("featured", featured_url)
#         |> Jason.encode!()

#       object_id = Ecto.UUID.generate()

#       featured_data =
#         "fixtures/mastodon/mastodon/collections/featured.json"
#         |> file()
#         |> String.replace("{{domain}}", "example.com")
#         |> String.replace("{{nickname}}", "lain")
#         |> String.replace("{{object_id}}", object_id)

#       object_url = "https://mastodon.local/objects/#{object_id}"

#       object_data =
#         "fixtures/statuses/note.json"
#         |> file()
#         |> String.replace("{{object_id}}", object_id)
#         |> String.replace("{{nickname}}", "lain")

#       Tesla.Mock.mock(fn
#         %{
#           method: :get,
#           url: ^ap_id
#         } ->
#           %Tesla.Env{
#             status: 200,
#             body: user_data,
#             headers: [{"content-type", "application/activity+json"}]
#           }

#         %{
#           method: :get,
#           url: ^featured_url
#         } ->
#           %Tesla.Env{
#             status: 200,
#             body: featured_data,
#             headers: [{"content-type", "application/activity+json"}]
#           }
#       end)

#       Tesla.Mock.mock(fn
#         %{
#           method: :get,
#           url: ^object_url
#         } ->
#           %Tesla.Env{
#             status: 200,
#             body: object_data,
#             headers: [{"content-type", "application/activity+json"}]
#           }
#       end)

#       {:ok, user} = ActivityPub.make_user_from_ap_id(ap_id)
#       Process.sleep(50)

#       assert user.featured_address == featured_url
#       assert Map.has_key?(user.pinned_objects, object_url)

#       in_db = user_by_ap_id(ap_id)
#       assert in_db.featured_address == featured_url
#       assert Map.has_key?(user.pinned_objects, object_url)

#       assert %{data: %{"id" => ^object_url}} = Object.get_cached(ap_id: object_url)
#     end
#   end

#   test "fetches user featured collection using the first property" do
#     featured_url = "https://friendica.example.com/raha/collections/featured"
#     first_url = "https://friendica.example.com/featured/raha?page=1"

#     featured_data =
#       "fixtures/friendica/friendica_featured_collection.json"
#       |> file()

#     page_data =
#       "fixtures/friendica/friendica_featured_collection_first.json"
#       |> file()

#     Tesla.Mock.mock(fn
#       %{
#         method: :get,
#         url: ^featured_url
#       } ->
#         %Tesla.Env{
#           status: 200,
#           body: featured_data,
#           headers: [{"content-type", "application/activity+json"}]
#         }

#       %{
#         method: :get,
#         url: ^first_url
#       } ->
#         %Tesla.Env{
#           status: 200,
#           body: page_data,
#           headers: [{"content-type", "application/activity+json"}]
#         }
#     end)

#     {:ok, data} = ActivityPub.fetch_and_prepare_featured_from_ap_id(featured_url)
#     assert Map.has_key?(data, "http://inserted")
#   end

#   test "fetches user featured when it has string IDs" do
#     featured_url = "https://mastodon.local/alisaie/collections/featured"
#     dead_url = "https://mastodon.local/users/alisaie/statuses/108311386746229284"

#     featured_data =
#       "fixtures/mastodon/mastodon/featured_collection.json"
#       |> file()

#     Tesla.Mock.mock(fn
#       %{
#         method: :get,
#         url: ^featured_url
#       } ->
#         %Tesla.Env{
#           status: 200,
#           body: featured_data,
#           headers: [{"content-type", "application/activity+json"}]
#         }

#       %{
#         method: :get,
#         url: ^dead_url
#       } ->
#         %Tesla.Env{
#           status: 404,
#           body: "{}",
#           headers: [{"content-type", "application/activity+json"}]
#         }
#     end)

#     {:ok, %{}} = ActivityPub.fetch_and_prepare_featured_from_ap_id(featured_url)
#   end
