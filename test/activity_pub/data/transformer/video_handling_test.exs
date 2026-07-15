# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.VideoHandlingTest do
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

  test "skip converting the content when it is nil" do
    data =
      file("fixtures/framatube.org-video.json")
      |> Jason.decode!()
      |> Kernel.put_in(["object", "content"], nil)

    {:ok, %Activity{local: false} = activity} = Transformer.handle_incoming(data)

    assert object = Object.normalize(activity, fetch: false)

    assert object.data["content"] == nil
  end

  test "it converts content of object to html" do
    data = file("fixtures/framatube.org-video.json") |> Jason.decode!()

    {:ok, %Activity{local: false} = activity} =
      Transformer.handle_incoming(data)
      |> debug()

    assert object =
             Object.normalize(activity, fetch: false)
             |> debug()

    assert object.data["name"] ==
             "Déframasoftisons Internet [Framasoft]"
  end

  # unlike Pleroma we do NOT remap a PeerTube video's url list into url + attachment: the raw
  # Link list is the input contract of `Bonfire.Files.Media.ap_receive_activity`, which picks
  # the best playable file from it (incl. from mpegURL playlists) on the adapter side
  test "it preserves PeerTube video url lists" do
    {:ok, object} =
      Fetcher.fetch_object_from_id(
        "https://group.local/videos/watch/df5f464b-be8d-46fb-ad81-2d4c2d1630e3"
      )

    urls = object.data["url"]
    assert is_list(urls)

    # note: this older PeerTube fixture tags links with `mimeType` rather than `mediaType`,
    # so match on href (the watch page + a playable mp4 must both still be in the list)
    assert Enum.any?(
             urls,
             &(&1["href"] ==
                 "https://group.local/videos/watch/df5f464b-be8d-46fb-ad81-2d4c2d1630e3")
           )

    assert Enum.any?(urls, &String.ends_with?(&1["href"] || "", ".mp4"))

    assert object.data["attachment"] == nil

    data = file("fixtures/framatube.org-video.json") |> Jason.decode!()

    {:ok, %Activity{local: false} = activity} = Transformer.handle_incoming(data)

    assert object = Object.normalize(activity, fetch: false)

    urls = object.data["url"]
    assert is_list(urls)

    assert Enum.any?(
             urls,
             &(&1["mediaType"] == "text/html" and
                 &1["href"] ==
                   "https://framatube.local/videos/watch/6050732a-8a7a-43d4-a6cd-809525a1d206")
           )

    assert Enum.any?(
             urls,
             &(&1["mediaType"] == "video/mp4" and
                 &1["href"] ==
                   "https://framatube.local/static/webseed/6050732a-8a7a-43d4-a6cd-809525a1d206-1080.mp4")
           )

    assert object.data["attachment"] == nil
  end

  test "it works for peertube videos with only their mpegURL map" do
    data =
      file("fixtures/peertube/video-object-mpegURL-only.json")
      |> Jason.decode!()

    {:ok, %Activity{local: false} = activity} = Transformer.handle_incoming(data)

    assert object = Object.normalize(activity, fetch: false)

    urls = object.data["url"]
    assert is_list(urls)

    assert Enum.any?(
             urls,
             &(&1["mediaType"] == "text/html" and
                 &1["href"] ==
                   "https://peertube.local/videos/watch/abece3c3-b9c6-47f4-8040-f3eed8c602e6")
           )

    # the mpegURL playlist entry is kept for the Media adapter to pick a file from
    assert Enum.any?(urls, &(&1["mediaType"] == "application/x-mpegURL"))

    assert object.data["attachment"] == nil
  end
end
