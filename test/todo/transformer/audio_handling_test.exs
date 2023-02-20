# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.AudioHandlingTest do
  use ActivityPub.DataCase, async: true
  use Oban.Testing, repo: repo()

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Test.HttpRequestMock
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  test "Funkwhale Audio object" do
    data = file("fixtures/tesla_mock/funkwhale_create_audio.json") |> Jason.decode!()

    {:ok, %Activity{local: false} = activity} = Transformer.handle_incoming(data)

    assert object = Object.normalize(activity, fetch: false)

    assert object.data["to"] == ["https://www.w3.org/ns/activitystreams#Public"]

    assert object.data["cc"] == [
             "https://funkwhale.local/federation/actors/compositions/followers"
           ]

    assert object.data["url"] == "https://funkwhale.local/library/tracks/74"

    assert object.data["attachment"] == [
             %{
               "mediaType" => "audio/ogg",
               "type" => "Link",
               "url" => [
                 %{
                   "href" =>
                     "https://funkwhale.local/api/v1/listen/3901e5d8-0445-49d5-9711-e096cf32e515/?upload=42342395-0208-4fee-a38d-259a6dae0871&download=false",
                   "mediaType" => "audio/ogg",
                   "type" => "Link"
                 }
               ]
             }
           ]
  end
end
