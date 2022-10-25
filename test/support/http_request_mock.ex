defmodule ActivityPub.Test.HttpRequestMock do
  # import Untangle
  import ActivityPub.Test.Helpers

  @mod_path __DIR__
  def file(path), do: File.read!(@mod_path <> "/../" <> path)

  def request(
        %Tesla.Env{
          url: url,
          method: method,
          headers: headers,
          query: query,
          body: body
        } = _env
      ) do
    with {:ok, res} <- apply(__MODULE__, method, [url, query, body, headers]) do
      res
    else
      {_, _r} = error ->
        # warn(r)
        error
    end
  end

  def get(url, query \\ [], body \\ [], headers \\ [])

  def get(
        "https://mocked.local/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/pleroma_note.json")
     }}
  end

  def get("https://mocked.local/users/karen", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/pleroma_user_actor.json")
     }}
  end

  def get("https://testing.local/users/karen", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/pleroma_user_actor2.json")
     }}
  end

  def get(
        "https://testing.local/objects/d953809b-d968-49c8-aa8f-7545b9480a12",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/pleroma_private_note.json")
     }}
  end

  def get(
        "https://instance.local/objects/89a60bfd-6b05-42c0-acde-ce73cc9780e6",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/spoofed_pleroma_note.json")
     }}
  end

  def get("https://home.local/1", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/mooglenet_person_actor.json")
     }}
  end

  def get(
        "https://mocked.local/.well-known/webfinger?resource=acct:karen@mocked.local",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/pleroma_webfinger.json")
     }}
  end

  def get(
        "http://mocked.local/.well-known/webfinger?resource=acct:karen@mocked.local",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/pleroma_webfinger.json")
     }}
  end

  def get(
        "https://mastodon.local/.well-known/webfinger?resource=acct:karen@mastodon.local",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/mastodon_webfinger.json")
     }}
  end

  def get(
        "http://mastodon.local/.well-known/webfinger?resource=acct:karen@mastodon.local",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/mastodon_webfinger.json")
     }}
  end

  def get("https://mastodon.local/users/karen", _, _, Accept: "application/activity+json") do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/mastdon-actor.json")
     }}
  end

  def get("https://mastodon.local/@karen", _, _, Accept: "application/activity+json") do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/mastdon-actor.json")
     }}
  end

  def get(url, query, body, headers) do
    {:error,
     "No implemented mock response for get #{inspect(url)}, #{query}, #{inspect(body)}, #{inspect(headers)}"}
  end
end
