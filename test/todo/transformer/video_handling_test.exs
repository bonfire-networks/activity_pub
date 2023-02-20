# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.VideoHandlingTest do
  use ActivityPub.DataCase, async: true
  use Oban.Testing, repo: repo()

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Test.HttpRequestMock
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  test "skip converting the content when it is nil" do
    data =
      file("fixtures/tesla_mock/framatube.org-video.json")
      |> Jason.decode!()
      |> Kernel.put_in(["object", "content"], nil)

    {:ok, %Activity{local: false} = activity} = Transformer.handle_incoming(data)

    assert object = Object.normalize(activity, fetch: false)

    assert object.data["content"] == nil
  end

  test "it converts content of object to html" do
    data = file("fixtures/tesla_mock/framatube.org-video.json") |> Jason.decode!()

    {:ok, %Activity{local: false} = activity} =
      Transformer.handle_incoming(data)
      |> debug()

    assert object =
             Object.normalize(activity, fetch: false)
             |> debug()

    assert object.data["name"] ==
             "Déframasoftisons Internet [Framasoft]"
  end

  test "it remaps video URLs as attachments if necessary" do
    {:ok, object} =
      Fetcher.fetch_object_from_id(
        "https://group.local/videos/watch/df5f464b-be8d-46fb-ad81-2d4c2d1630e3"
      )

    assert object.data["url"] ==
             "https://group.local/videos/watch/df5f464b-be8d-46fb-ad81-2d4c2d1630e3"

    assert object.data["attachment"] == [
             %{
               "type" => "Link",
               "mediaType" => "video/mp4",
               "url" => [
                 %{
                   "href" =>
                     "https://group.local/static/webseed/df5f464b-be8d-46fb-ad81-2d4c2d1630e3-480.mp4",
                   "mediaType" => "video/mp4",
                   "type" => "Link",
                   "width" => 480
                 }
               ]
             }
           ]

    data = file("fixtures/tesla_mock/framatube.org-video.json") |> Jason.decode!()

    {:ok, %Activity{local: false} = activity} = Transformer.handle_incoming(data)

    assert object = Object.normalize(activity, fetch: false)

    assert object.data["attachment"] == [
             %{
               "type" => "Link",
               "mediaType" => "video/mp4",
               "url" => [
                 %{
                   "href" =>
                     "https://framatube.local/static/webseed/6050732a-8a7a-43d4-a6cd-809525a1d206-1080.mp4",
                   "mediaType" => "video/mp4",
                   "type" => "Link",
                   "height" => 1080
                 }
               ]
             }
           ]

    assert object.data["url"] ==
             "https://framatube.local/videos/watch/6050732a-8a7a-43d4-a6cd-809525a1d206"
  end

  test "it works for peertube videos with only their mpegURL map" do
    data =
      file("fixtures/peertube/video-object-mpegURL-only.json")
      |> Jason.decode!()

    {:ok, %Activity{local: false} = activity} = Transformer.handle_incoming(data)

    assert object = Object.normalize(activity, fetch: false)

    assert object.data["attachment"] == [
             %{
               "type" => "Link",
               "mediaType" => "video/mp4",
               "url" => [
                 %{
                   "href" =>
                     "https://peertube.local/static/streaming-playlists/hls/abece3c3-b9c6-47f4-8040-f3eed8c602e6/abece3c3-b9c6-47f4-8040-f3eed8c602e6-1080-fragmented.mp4",
                   "mediaType" => "video/mp4",
                   "type" => "Link",
                   "height" => 1080
                 }
               ]
             }
           ]

    assert object.data["url"] ==
             "https://peertube.local/videos/watch/abece3c3-b9c6-47f4-8040-f3eed8c602e6"
  end
end
