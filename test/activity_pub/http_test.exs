defmodule ActivityPub.HTTPTest do
  use ActivityPub.DataCase
  import Tesla.Mock

  setup do
    mock(fn
      %{
        method: :get,
        url: "http://example.com/hello",
        headers: [{"content-type", "application/json"}]
      } ->
        json(%{"my" => "data"})

      %{method: :get, url: "http://example.com/hello"} ->
        %Tesla.Env{status: 200, body: "hello"}
    end)

    :ok
  end

  describe "get/1" do
    test "returns successfully result" do
      assert ActivityPub.HTTP.get("http://example.com/hello") == {
               :ok,
               %Tesla.Env{status: 200, body: "hello"}
             }
    end
  end

  describe "get/2 (with headers)" do
    test "returns successfully result for json content-type" do
      assert ActivityPub.HTTP.get("http://example.com/hello", [
               {"content-type", "application/json"}
             ]) ==
               {
                 :ok,
                 %Tesla.Env{
                   status: 200,
                   body: "{\"my\":\"data\"}",
                   headers: [{"content-type", "application/json"}]
                 }
               }
    end
  end
end
