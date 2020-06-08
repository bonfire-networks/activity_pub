# MoodleNet: Connecting and empowering educators worldwide
# Copyright © 2018-2020 Moodle Pty Ltd <https://moodle.com/moodlenet/>
# Contains code from Pleroma <https://pleroma.social/> and CommonsPub <https://commonspub.org/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.FetcherTest do
  use ActivityPub.DataCase
  import Tesla.Mock

  alias ActivityPub.Fetcher

  setup do
    mock(fn
      %{method: :get, url: "https://pleroma.example/userisgone404"} ->
        %Tesla.Env{status: 404}

      %{method: :get, url: "https://pleroma.example/userisgone410"} ->
        %Tesla.Env{status: 410}

      env ->
        apply(HttpRequestMock, :request, [env])
    end)

    :ok
  end

  describe "fetching objects" do
    test "fetches a pleroma note" do
      {:ok, object} =
        Fetcher.fetch_object_from_id(
          "https://kawen.space/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779"
        )

      assert object
    end

    test "fetches a pleroma actor" do
      {:ok, object} = Fetcher.fetch_object_from_id("https://kawen.space/users/karen")

      assert object
    end

    test "rejects private posts" do
      {:error, _} =
        Fetcher.fetch_object_from_id(
          "https://testing.kawen.dance/objects/d953809b-d968-49c8-aa8f-7545b9480a12"
        )
    end

    test "rejects posts with spoofed origin" do
      {:error, _} =
        Fetcher.fetch_object_from_id(
          "https://letsalllovela.in/objects/89a60bfd-6b05-42c0-acde-ce73cc9780e6"
        )
    end

    test "doesn't insert posts twice" do
      {:ok, object_1} =
        Fetcher.fetch_object_from_id(
          "https://kawen.space/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779"
        )

      {:ok, object_2} =
        Fetcher.fetch_object_from_id(
          "https://kawen.space/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779"
        )

      assert object_1.id == object_2.id
    end

    test "accepts objects containing different scheme than requested" do
      {:ok, object} = Fetcher.fetch_object_from_id("https://home.next.moodle.net/1")

      assert object
    end
  end

  describe "handles errors" do
    test "handle HTTP 410 Gone response" do
      assert {:error, "Object has been deleted"} ==
               Fetcher.fetch_remote_object_from_id("https://pleroma.example/userisgone410")
    end

    test "handle HTTP 404 response" do
      assert {:error, "Object has been deleted"} ==
               Fetcher.fetch_remote_object_from_id("https://pleroma.example/userisgone404")
    end
  end
end
