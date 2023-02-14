defmodule ActivityPub.FetcherTest do
  use ActivityPub.DataCase
  import Tesla.Mock

  alias ActivityPub.Fetcher
  alias ActivityPub.WebFinger

  setup do
    mock(fn
      %{method: :get, url: "https://fedi.local/userisgone404"} ->
        %Tesla.Env{status: 404}

      %{method: :get, url: "https://fedi.local/userisgone410"} ->
        %Tesla.Env{status: 410}

      %{method: :get, url: "https://fedi.local/userisgone502"} ->
        %Tesla.Env{status: 502}

      %{method: :get, url: "https://mastodon.local/user/karen"} ->
        ActivityPub.Test.HttpRequestMock.get(
          "https://mastodon.local/users/admin",
          nil,
          nil,
          nil
        )

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  describe "fetching objects" do
    test "fetches a pleroma note" do
      {:ok, object} =
        Fetcher.fetch_object_from_id(
          "https://mocked.local/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779"
        )

      assert object
    end

    test "fetches a pleroma actor" do
      {:ok, object} = Fetcher.fetch_object_from_id("https://mocked.local/users/karen")

      assert object
    end

    test "fetches a mastodon actor by AP ID" do
      {:ok, object} = Fetcher.fetch_object_from_id("https://mastodon.local/users/admin")

      assert object
    end

    test "fetches a mastodon actor by friendly URL" do
      {:ok, object} = Fetcher.fetch_object_from_id("https://mastodon.local/@karen")

      assert object
    end

    test "fetches a same mastodon actor by friendly URL and AP ID" do
      {:ok, object1} = Fetcher.fetch_object_from_id("https://mastodon.local/@karen")

      {:ok, object2} = Fetcher.fetch_object_from_id("https://mastodon.local/users/admin")

      assert object1.data == object2.data
    end

    test "fetches a same mastodon actor by AP ID and friendly URL" do
      {:ok, object1} = Fetcher.fetch_object_from_id("https://mastodon.local/users/admin")

      {:ok, object2} = Fetcher.fetch_object_from_id("https://mastodon.local/@karen")

      assert object1.data == object2.data
    end

    test "fetches a same mastodon actor by AP ID and a 3rd URL" do
      {:ok, object1} = Fetcher.fetch_object_from_id("https://mastodon.local/users/admin")

      {:ok, object2} = Fetcher.fetch_object_from_id("https://mastodon.local/user/karen")

      assert object1.data == object2.data
    end

    test "fetches a same mastodon actor by webfinger, AP ID and friendly URL" do
      {:ok, fingered} = WebFinger.finger("karen@mastodon.local")
      {:ok, object1} = Fetcher.fetch_object_from_id(fingered["id"])

      {:ok, object2} = Fetcher.fetch_object_from_id("https://mastodon.local/users/admin")

      {:ok, object3} = Fetcher.fetch_object_from_id("https://mastodon.local/@karen")

      assert object1.data == object2.data
      assert object2 == object3
    end

    test "fetches a same mastodon actor by AP ID and friendly URL and webfinger" do
      {:ok, object1} = Fetcher.fetch_object_from_id("https://mastodon.local/users/admin")

      {:ok, object2} = Fetcher.fetch_object_from_id("https://mastodon.local/@karen")

      {:ok, fingered} = WebFinger.finger("karen@mastodon.local")
      {:ok, object3} = Fetcher.fetch_object_from_id(fingered["id"])

      assert object1.data == object2.data
      assert object2 == object3
    end

    # test "rejects private posts" do # why?
    #   {:error, _} =
    #     Fetcher.fetch_object_from_id(
    #       "https://testing.local/objects/d953809b-d968-49c8-aa8f-7545b9480a12"
    #     )
    # end

    test "rejects posts with spoofed origin" do
      {:error, _} =
        Fetcher.fetch_object_from_id(
          "https://instance.local/objects/89a60bfd-6b05-42c0-acde-ce73cc9780e6"
        )
    end

    test "doesn't insert posts twice" do
      {:ok, object_1} =
        Fetcher.fetch_object_from_id(
          "https://mocked.local/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779"
        )

      {:ok, object_2} =
        Fetcher.fetch_object_from_id(
          "https://mocked.local/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779"
        )

      assert object_1.id == object_2.id
    end

    test "accepts objects containing different scheme than requested" do
      {:ok, object} = Fetcher.fetch_object_from_id("https://home.local/1")

      assert object
    end
  end

  describe "handles errors" do
    test "handle HTTP 410 Gone response" do
      assert {:error, "Object not found or deleted"} ==
               Fetcher.fetch_remote_object_from_id("https://fedi.local/userisgone410")
    end

    test "handle HTTP 404 response" do
      assert {:error, "Object not found or deleted"} ==
               Fetcher.fetch_remote_object_from_id("https://fedi.local/userisgone404")
    end

    test "handle HTTP 502 response" do
      assert {:error, _} = Fetcher.fetch_remote_object_from_id("https://fedi.local/userisgone502")
    end
  end
end
