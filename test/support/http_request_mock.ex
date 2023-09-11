defmodule ActivityPub.Test.HttpRequestMock do
  import ActivityPub.Test.Helpers
  import Untangle
  alias ActivityPub.Fixtures
  import Fixtures

  require Phoenix.ConnTest
  alias Phoenix.ConnTest

  alias ActivityPub.Utils

  @endpoint endpoint()

  @sample_object "{\"actor\": \"https://mocked.local/users/karen\", \"id\": \"https://mocked.local/2\", \"to\": \"#{ActivityPub.Config.public_uri()}\"}"

  def request(env) do
    case env do
      %{
        method: :get,
        url: "http://mastodon.local/hello",
        headers: [{"content-type", "application/json"}, _]
      } ->
        Tesla.Mock.json(%{"my" => "hello"})

      %Tesla.Env{
        url: url,
        method: method,
        headers: headers,
        query: query,
        body: body
      } ->
        with nil <- apply(Fixtures, method, [url, query, body, headers]) do
          case fixtures_generic()[url] do
            nil ->
              none(url, query, body, headers)

            fun ->
              fun.(url)
          end
        else
          other ->
            other
        end
    end

    # |> IO.inspect(label: "moccck")
  end
end
