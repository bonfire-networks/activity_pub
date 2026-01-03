defmodule ActivityPub.Federator.FetcherSpoofTest do
  use ActivityPub.DataCase, async: false
  import Tesla.Mock
  import Mock
  use Oban.Testing, repo: repo()

  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.WebFinger

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Instances
  alias ActivityPub.Object

  alias ActivityPub.Test.HttpRequestMock

  @sample_object "{\"actor\": \"https://mocked.local/users/karen\", \"id\": \"https://mocked.local/2\", \"to\": \"#{ActivityPub.Config.public_uri()}\"}"

  setup_all do
    mock_global(fn
      env ->
        HttpRequestMock.request(env)
    end)

    :ok
  end

  describe "fetching objects" do
    @tag :fixme
    test "it does not fetch a spoofed object uploaded on an instance as an attachment" do
      # FIXME!
      assert {:error, _} =
               Fetcher.fetch_object_from_id(
                 "https://patch.local/media/03ca3c8b4ac3ddd08bf0f84be7885f2f88de0f709112131a22d83650819e36c2.json"
               )

      assert all_enqueued(worker: Workers.RemoteFetcherWorker) == []
    end

    test "does not fetch anything from a rejected instance" do
      clear_config([:mrf_simple, :reject], ["evil.example.org", "i said so"])

      assert reject_or_no_recipients?(
               Fetcher.fetch_object_from_id("http://evil.example.org/@admin/99512778738411822")
             )
    end
  end
end
