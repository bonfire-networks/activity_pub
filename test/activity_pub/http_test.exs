defmodule ActivityPub.HTTPTest do
  use ActivityPub.DataCase
  import Tesla.Mock

  setup do
    mock(fn
      %{
        method: :get,
        url: "http://example.local/hello",
        headers: [{"content-type", "application/json"}, _]
      } ->
        json(%{"my" => "hello"})

      %{method: :get, url: "http://example.local/hello"} ->
        %Tesla.Env{status: 200, body: "hello"}
    end)

    :ok
  end

  describe "get/1" do
    test "returns successfully result" do
      assert ActivityPub.HTTP.get("http://example.local/hello") == {
               :ok,
               %Tesla.Env{status: 200, body: "hello"}
             }
    end
  end

  describe "get/2 (with headers)" do
    test "returns successfully result for json content-type" do
      assert ActivityPub.HTTP.get("http://example.local/hello", [
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
