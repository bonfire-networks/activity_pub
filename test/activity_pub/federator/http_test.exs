defmodule ActivityPub.Federator.HTTPTest do
  use ActivityPub.DataCase, async: false
  import Tesla.Mock

  setup_all do
    mock_global(fn
      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  describe "get/1" do
    test "returns successfully result" do
      assert ActivityPub.Federator.HTTP.get("http://mastodon.local/hello") == {
               :ok,
               %Tesla.Env{status: 200, body: "hello"}
             }
    end
  end

  describe "get/2 (with headers)" do
    test "returns successfully result for json content-type" do
      assert ActivityPub.Federator.HTTP.get("http://mastodon.local/hello", [
               {"content-type", "application/json"}
             ]) ==
               {
                 :ok,
                 %Tesla.Env{
                   status: 200,
                   body: "{\"my\":\"hello\"}",
                   headers: [{"content-type", "application/json"}]
                 }
               }
    end
  end
end
