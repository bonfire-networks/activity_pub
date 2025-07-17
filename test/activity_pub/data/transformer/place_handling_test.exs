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
end
