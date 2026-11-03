# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.PlaceHandlingTest do
  use ActivityPub.DataCase, async: false
  use Oban.Testing, repo: repo()

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Test.HttpRequestMock
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  test "can add a Place" do
    data = file("fixtures/place.json") |> Jason.decode!()

    {:ok, %Activity{data: data, local: false}} =
      Transformer.handle_incoming(data)

    # |> debug()

    object = Object.normalize(data["object"], fetch: false)

    assert object.data["name"] ==
             "CERN - Site de Meyrin"

    assert object.data["id"] == "https://mocked.local/relation/27005"

    assert object.data["latitude"] == 46.23343
  end

  # a Place that names an owner is held to the owner's origin, as any object is: otherwise its sender could take an id on another host
  describe "a delivered Place naming an owner" do
    @owner "https://mocked.local/users/karen"

    defp place(id),
      do: %{
        "type" => "Place",
        "id" => id,
        "attributedTo" => @owner,
        "name" => "somewhere",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

    defp delivered(place),
      do:
        Transformer.handle_incoming(place,
          from_inbox: true,
          authenticated: :http_signature,
          signed_by: @owner
        )

    test "is stored when its id is on the owner's host" do
      id = "https://mocked.local/places/#{System.unique_integer([:positive])}"
      delivered(place(id))

      assert {:ok, _} = Object.get_cached(ap_id: id)
    end

    test "is not stored when its id is on another host" do
      id = "https://elsewhere.local/places/#{System.unique_integer([:positive])}"
      delivered(place(id))

      assert {:error, :not_found} = Object.get_cached(ap_id: id)
    end
  end
end
