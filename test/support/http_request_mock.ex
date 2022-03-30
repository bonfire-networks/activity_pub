defmodule ActivityPub.Test.HttpRequestMock do
  import Where
  import ActivityPub.Test.Helpers

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

  def get("https://kawen.space/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!(test_path()<>"/fixtures/pleroma_note.json")
     }}
  end

  def get("https://kawen.space/users/karen", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!(test_path()<>"/fixtures/pleroma_user_actor.json")
     }}
  end

  def get("https://testing.kawen.dance/users/karen", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!(test_path()<>"/fixtures/pleroma_user_actor2.json")
     }}
  end

  def get("https://testing.kawen.dance/objects/d953809b-d968-49c8-aa8f-7545b9480a12", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!(test_path()<>"/fixtures/pleroma_private_note.json")
     }}
  end

  def get("https://letsalllovela.in/objects/89a60bfd-6b05-42c0-acde-ce73cc9780e6", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!(test_path()<>"/fixtures/spoofed_pleroma_note.json")
     }}
  end

  def get("https://home.next.moogle.net/1", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!(test_path()<>"/fixtures/mooglenet_person_actor.json")
     }}
  end

  def get("https://kawen.space/.well-known/webfinger?resource=acct:karen@kawen.space", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!(test_path()<>"/fixtures/pleroma_webfinger.json")
     }}
  end

  def get("https://mastodon.example.org/.well-known/webfinger?resource=acct:karen@mastodon.example.org", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!(test_path()<>"/fixtures/mastodon_webfinger.json")
     }}
  end

  def get("https://mastodon.example.org/users/karen", _, _, Accept: "application/activity+json") do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!(test_path()<>"/fixtures/mastdon-actor.json")
     }}
  end

  def get("https://mastodon.example.org/@karen", _, _, Accept: "application/activity+json") do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!(test_path()<>"/fixtures/mastdon-actor.json")
     }}
  end

  def get(url, query, body, headers) do
    {:error,
     "Not implemented the mock response for get #{inspect(url)}, #{query}, #{inspect(body)}, #{
       inspect(headers)
     }"}
  end
end
