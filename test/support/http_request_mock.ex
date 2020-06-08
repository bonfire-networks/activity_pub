# MoodleNet: Connecting and empowering educators worldwide
# Copyright © 2018-2020 Moodle Pty Ltd <https://moodle.com/moodlenet/>
# Contains code from Pleroma <https://pleroma.social/> and CommonsPub <https://commonspub.org/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule HttpRequestMock do
  require Logger

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
        # Logger.warn(r)
        error
    end
  end

  def get(url, query \\ [], body \\ [], headers \\ [])

  def get("https://kawen.space/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!("test/fixtures/pleroma_note.json")
     }}
  end

  def get("https://kawen.space/users/karen", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!("test/fixtures/pleroma_user_actor.json")
     }}
  end

  def get("https://testing.kawen.dance/users/karen", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!("test/fixtures/pleroma_user_actor2.json")
     }}
  end

  def get("https://testing.kawen.dance/objects/d953809b-d968-49c8-aa8f-7545b9480a12", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!("test/fixtures/pleroma_private_note.json")
     }}
  end

  def get("https://letsalllovela.in/objects/89a60bfd-6b05-42c0-acde-ce73cc9780e6", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!("test/fixtures/spoofed_pleroma_note.json")
     }}
  end

  def get("https://home.next.moodle.net/1", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!("test/fixtures/moodlenet_person_actor.json")
     }}
  end

  def get("https://kawen.space/.well-known/webfinger?resource=acct:karen@kawen.space", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!("test/fixtures/pleroma_webfinger.json")
     }}
  end

  def get("https://niu.moe/.well-known/webfinger?resource=acct:karen@niu.moe", _, _, _) do
    {:ok,
    %Tesla.Env{
      status: 200,
      body: File.read!("test/fixtures/mastodon_webfinger.json")
    }}
  end

  def get("http://mastodon.example.org/users/admin", _, _, Accept: "application/activity+json") do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: File.read!("test/fixtures/admin@mastdon.example.org.json")
     }}
  end

  def get(url, query, body, headers) do
    {:error,
     "Not implemented the mock response for get #{inspect(url)}, #{query}, #{inspect(body)}, #{
       inspect(headers)
     }"}
  end
end
