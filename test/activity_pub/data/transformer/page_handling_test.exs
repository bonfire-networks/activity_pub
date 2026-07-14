# Copyright © 2017-2020 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.PageHandlingTest do
  use ActivityPub.DataCase, async: false
  use Oban.Testing, repo: repo()

  alias ActivityPub.Federator.Fetcher
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  test "Lemmy Page" do
    {:ok, object} = Fetcher.fetch_object_from_id("https://lemmy.local/post/3")

    assert object.data["summary"] == "Hello Federation!"
    assert object.data["published"] == "2020-09-14T15:03:11.909105+00:00"

    # WAT
    assert object.data["url"] == "https://lemmy.local/pictrs/image/US52d9DPvf.jpg"
  end
end
