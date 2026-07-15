# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.AudioHandlingTest do
  use ActivityPub.DataCase, async: false
  use Oban.Testing, repo: repo()

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Test.HttpRequestMock
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  test "Funkwhale Audio object is stored with its url list preserved" do
    data = file("fixtures/funkwhale_create_audio.json") |> Jason.decode!()

    {:ok, %Activity{local: false} = activity} = Transformer.handle_incoming(data)

    assert object = Object.normalize(activity, fetch: false)

    assert object.data["to"] == ["https://www.w3.org/ns/activitystreams#Public"]

    # we do NOT split the url list into url + attachment (Pleroma-style): the raw Link list is the input contract of `Bonfire.Files.Media.ap_receive_activity`, whose `extract_audio_url/1` picks the playable file from it on the adapter side
    assert object.data["url"] == [
             %{
               "type" => "Link",
               "mimeType" => "audio/ogg",
               "href" =>
                 "https://funkwhale.local/api/v1/listen/3901e5d8-0445-49d5-9711-e096cf32e515/?upload=42342395-0208-4fee-a38d-259a6dae0871&download=false"
             },
             %{
               "type" => "Link",
               "mimeType" => "text/html",
               "href" => "https://funkwhale.local/library/tracks/74"
             }
           ]

    assert object.data["attachment"] == nil
  end
end
