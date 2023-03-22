defmodule ActivityPub.Federator.Transformer.AddRemoveHandlingTest do
  use ActivityPub.DataCase, async: false
  use Oban.Testing, repo: repo(), async: true

  import ActivityPub.Factory
  import Tesla.Mock

  alias ActivityPub.Federator.Transformer

  setup_all do
    Tesla.Mock.mock(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  test "accepts Add/Remove activities", %{conn: conn} do
    object_id = "c61d6733-e256-4fe1-ab13-1e369789423f"

    status =
      file("fixtures/statuses/note.json")
      |> String.replace("{{nickname}}", "lain")
      |> String.replace("{{object_id}}", object_id)

    object_url = "https://mastodon.local/objects/#{object_id}"

    user =
      file("fixtures/actor.json")
      |> String.replace("{{nickname}}", "lain")

    actor = "https://mastodon.local/users/lain"

    insert(:actor,
      ap_id: actor,
      featured_address: "https://mastodon.local/users/lain/collections/featured"
    )

    Tesla.Mock.mock(fn
      %{
        method: :get,
        url: ^object_url
      } ->
        %Tesla.Env{
          status: 200,
          body: status,
          headers: [{"content-type", "application/activity+json"}]
        }

      %{
        method: :get,
        url: ^actor
      } ->
        %Tesla.Env{
          status: 200,
          body: user,
          headers: [{"content-type", "application/activity+json"}]
        }

      %{method: :get, url: "https://mastodon.local/users/lain/collections/featured"} ->
        %Tesla.Env{
          status: 200,
          body:
            "fixtures/users_mock/masto_featured.json"
            |> file()
            |> String.replace("{{domain}}", "example.com")
            |> String.replace("{{nickname}}", "lain"),
          headers: [{"content-type", "application/activity+json"}]
        }
    end)

    data = %{
      "id" => "https://mastodon.local/objects/d61d6733-e256-4fe1-ab13-1e369789423f",
      "actor" => actor,
      "object" => object_url,
      "target" => "https://mastodon.local/users/lain/collections/featured",
      "type" => "Add",
      "to" => [ActivityPub.Config.public_uri()]
    }

    assert "ok" ==
             conn
             |> assign(:valid_signature, true)
             |> put_req_header("signature", "keyId=\"#{actor}/main-key\"")
             |> put_req_header("content-type", "application/activity+json")
             |> post("#{Utils.ap_base_url()}/shared_inbox", data)
             |> json_response(200)

    ObanHelpers.perform(all_enqueued(worker: ReceiverWorker))
    assert Object.get_cached!(ap_id: data["id"])
    user = user_by_ap_id(data["actor"])

    # TODO
    # assert user.pinned_objects[data["object"]]

    data = %{
      "id" => "https://mastodon.local/objects/d61d6733-e256-4fe1-ab13-1e369789423d",
      "actor" => actor,
      "object" => object_url,
      "target" => "https://mastodon.local/users/lain/collections/featured",
      "type" => "Remove",
      "to" => [ActivityPub.Config.public_uri()]
    }

    assert "ok" ==
             conn
             |> assign(:valid_signature, true)
             |> put_req_header("signature", "keyId=\"#{actor}/main-key\"")
             |> put_req_header("content-type", "application/activity+json")
             |> post("#{Utils.ap_base_url()}/shared_inbox", data)
             |> json_response(200)

    ObanHelpers.perform(all_enqueued(worker: ReceiverWorker))
    user = refresh_record(user)
    # TODO
    # refute user.pinned_objects[data["object"]]
  end

  test "it accepts Add/Remove activities" do
    user =
      "fixtures/actor.json"
      |> file()
      |> String.replace("{{nickname}}", "lain")

    object_id = "c61d6733-e256-4fe1-ab13-1e369789423f"

    object =
      "fixtures/statuses/note.json"
      |> file()
      |> String.replace("{{nickname}}", "lain")
      |> String.replace("{{object_id}}", object_id)

    object_url = "https://mastodon.local/objects/#{object_id}"

    actor = "https://mastodon.local/users/lain"

    Tesla.Mock.mock(fn
      %{
        method: :get,
        url: ^actor
      } ->
        %Tesla.Env{
          status: 200,
          body: user,
          headers: [{"content-type", "application/activity+json"}]
        }

      %{
        method: :get,
        url: ^object_url
      } ->
        %Tesla.Env{
          status: 200,
          body: object,
          headers: [{"content-type", "application/activity+json"}]
        }

      %{method: :get, url: "https://mastodon.local/users/lain/collections/featured"} ->
        %Tesla.Env{
          status: 200,
          body:
            "fixtures/users_mock/masto_featured.json"
            |> file()
            |> String.replace("{{domain}}", "example.com")
            |> String.replace("{{nickname}}", "lain"),
          headers: [{"content-type", "application/activity+json"}]
        }
    end)

    message = %{
      "id" => "https://mastodon.local/objects/d61d6733-e256-4fe1-ab13-1e369789423f",
      "actor" => actor,
      "object" => object_url,
      "target" => "https://mastodon.local/users/lain/collections/featured",
      "type" => "Add",
      "to" => [ActivityPub.Config.public_uri()],
      "cc" => ["https://mastodon.local/users/lain/followers"],
      "bcc" => [],
      "bto" => []
    }

    assert {:ok, activity} = Transformer.handle_incoming(message)
    assert activity.data == message
    user = user_by_ap_id(actor)

    # TODO
    # assert user.pinned_objects[object_url]

    remove = %{
      "id" => "http://localhost:400/objects/d61d6733-e256-4fe1-ab13-1e369789423d",
      "actor" => actor,
      "object" => object_url,
      "target" => "https://mastodon.local/users/lain/collections/featured",
      "type" => "Remove",
      "to" => [ActivityPub.Config.public_uri()],
      "cc" => ["https://mastodon.local/users/lain/followers"],
      "bcc" => [],
      "bto" => []
    }

    assert {:ok, activity} = Transformer.handle_incoming(remove)
    assert activity.data == remove

    user = refresh_record(user)
    # TODO
    # refute user.pinned_objects[object_url]
  end

  test "Add/Remove activities for remote users without featured address" do
    user = actor(local: false, domain: "example.com")

    user =
      user
      |> Ecto.Changeset.change(featured_address: nil)
      |> repo().update!()

    %{host: host} = URI.parse(ap_id(user))

    user_data =
      "fixtures/actor.json"
      |> file()
      |> String.replace("{{nickname}}", user.nickname)

    object_id = "c61d6733-e256-4fe1-ab13-1e369789423f"

    object =
      "fixtures/statuses/note.json"
      |> file()
      |> String.replace("{{nickname}}", user.nickname)
      |> String.replace("{{object_id}}", object_id)

    object_url = "https://#{host}/objects/#{object_id}"

    actor = "https://#{host}/users/#{user.nickname}"

    featured = "https://#{host}/users/#{user.nickname}/collections/featured"

    Tesla.Mock.mock(fn
      %{
        method: :get,
        url: ^actor
      } ->
        %Tesla.Env{
          status: 200,
          body: user_data,
          headers: [{"content-type", "application/activity+json"}]
        }

      %{
        method: :get,
        url: ^object_url
      } ->
        %Tesla.Env{
          status: 200,
          body: object,
          headers: [{"content-type", "application/activity+json"}]
        }

      %{method: :get, url: ^featured} ->
        %Tesla.Env{
          status: 200,
          body:
            "fixtures/users_mock/masto_featured.json"
            |> file()
            |> String.replace("{{domain}}", "#{host}")
            |> String.replace("{{nickname}}", user.nickname),
          headers: [{"content-type", "application/activity+json"}]
        }
    end)

    message = %{
      "id" => "https://#{host}/objects/d61d6733-e256-4fe1-ab13-1e369789423f",
      "actor" => actor,
      "object" => object_url,
      "target" => "https://#{host}/users/#{user.nickname}/collections/featured",
      "type" => "Add",
      "to" => [ActivityPub.Config.public_uri()],
      "cc" => ["https://#{host}/users/#{user.nickname}/followers"],
      "bcc" => [],
      "bto" => []
    }

    assert {:ok, activity} = Transformer.handle_incoming(message)
    assert activity.data == message
    user = user_by_ap_id(actor)
    # TODO
    # assert user.pinned_objects[object_url]
  end
end
