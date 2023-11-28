# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.EventHandlingTest do
  use ActivityPub.DataCase, async: false
  use Oban.Testing, repo: repo()

  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Test.HttpRequestMock
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  test "Mobilizon Event object" do
    assert {:ok, object} =
             Fetcher.fetch_object_from_id(
               "https://mobilizon.local/events/252d5816-00a3-4a89-a66f-15bf65c33e39"
             )

    assert object.data["to"] == ["https://www.w3.org/ns/activitystreams#Public"]
    assert object.data["cc"] == ["https://mobilizon.local/@tcit/followers"]

    assert object.data["url"] ==
             "https://mobilizon.local/events/252d5816-00a3-4a89-a66f-15bf65c33e39"

    assert object.data["published"] == "2019-12-17T11:33:56Z"
    assert object.data["name"] == "Mobilizon Launching Party"
  end
end
