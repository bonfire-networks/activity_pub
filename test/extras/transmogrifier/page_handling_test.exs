# Copyright © 2017-2020 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.Transmogrifier.PageHandlingTest do
    use ActivityPub.DataCase
use Oban.Testing, repo: repo()

  alias ActivityPub.Fetcher
  import Tesla.Mock

  test "Lemmy Page" do
    Tesla.Mock.mock(fn
      %{url: "https://lemmy.local/post/3"} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "application/activity+json"}],
          body: file("fixtures/tesla_mock/lemmy-page.json")
        }

      %{url: "https://lemmy.local/u/nutomic"} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "application/activity+json"}],
          body: file("fixtures/tesla_mock/lemmy-user.json")
        }
        env -> apply(HttpRequestMock, :request, [env])
    end)

    {:ok, object} = Fetcher.fetch_object_from_id("https://lemmy.local/post/3")

    assert object.data["summary"] == "Hello Federation!"
    assert object.data["published"] == "2020-09-14T15:03:11.909105+00:00"

    # WAT
    assert object.data["url"] == "https://lemmy.local/pictrs/image/US52d9DPvf.jpg"
  end
end
