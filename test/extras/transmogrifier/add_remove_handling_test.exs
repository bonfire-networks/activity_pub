defmodule ActivityPubWeb.Transmogrifier.AddRemoveHandlingTest do
  use ActivityPub.DataCase
  use Oban.Testing, repo: repo(), async: true

  import ActivityPub.Factory
  import Tesla.Mock

  alias ActivityPubWeb.Transmogrifier

  @public_uri "https://www.w3.org/ns/activitystreams#Public"

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

    object_url = "https://example.local/objects/#{object_id}"

    actor = "https://example.local/users/lain"

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

      %{method: :get, url: "https://example.local/users/lain/collections/featured"} ->
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
      "id" => "https://example.local/objects/d61d6733-e256-4fe1-ab13-1e369789423f",
      "actor" => actor,
      "object" => object_url,
      "target" => "https://example.local/users/lain/collections/featured",
      "type" => "Add",
      "to" => [@public_uri],
      "cc" => ["https://example.local/users/lain/followers"],
      "bcc" => [],
      "bto" => []
    }

    assert {:ok, activity} = Transmogrifier.handle_incoming(message)
    assert activity.data == message
    user = user_by_ap_id(actor)

    # TODO
    # assert user.pinned_objects[object_url]

    remove = %{
      "id" => "http://localhost:400/objects/d61d6733-e256-4fe1-ab13-1e369789423d",
      "actor" => actor,
      "object" => object_url,
      "target" => "https://example.local/users/lain/collections/featured",
      "type" => "Remove",
      "to" => [@public_uri],
      "cc" => ["https://example.local/users/lain/followers"],
      "bcc" => [],
      "bto" => []
    }

    assert {:ok, activity} = Transmogrifier.handle_incoming(remove)
    assert activity.data == remove

    user = refresh_record(user)
    # TODO
    # refute user.pinned_objects[object_url]
  end

  test "Add/Remove activities for remote users without featured address" do
    user = local_actor(local: false, domain: "example.com")

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
      "to" => [@public_uri],
      "cc" => ["https://#{host}/users/#{user.nickname}/followers"],
      "bcc" => [],
      "bto" => []
    }

    assert {:ok, activity} = Transmogrifier.handle_incoming(message)
    assert activity.data == message
    user = user_by_ap_id(actor)
    # TODO
    # assert user.pinned_objects[object_url]
  end
end
