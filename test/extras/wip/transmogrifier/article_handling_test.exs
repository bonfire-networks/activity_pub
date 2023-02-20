# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.ArticleHandlingTest do
  use ActivityPub.DataCase
  use Oban.Testing, repo: repo()

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Test.HttpRequestMock
  import Tesla.Mock

  test "Pterotype (Wordpress Plugin) Article" do
    Tesla.Mock.mock(fn
      %{url: "https://wedistribute.local/wp-json/pterotype/v1/actor/-blog"} ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/wedistribute-user.json"),
          headers: HttpRequestMock.activitypub_object_headers()
        }

      %{url: "https://wedistribute.local/wp-json/pterotype/v1/object/85809"} ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/wedistribute-create-article.json"),
          headers: HttpRequestMock.activitypub_object_headers()
        }

      env ->
        apply(HttpRequestMock, :request, [env])
    end)

    data = file("fixtures/tesla_mock/wedistribute-create-article.json") |> Jason.decode!()

    {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

    object = Object.normalize(data["object"], fetch: false)

    assert object.data["name"] == "The end is near: Mastodon plans to drop OStatus support"

    assert object.data["summary"] ==
             "One of the largest platforms in the federated social web is dropping the protocol that it started with."

    assert object.data["url"] == "https://wedistribute.local/2019/07/mastodon-drops-ostatus/"
  end

  test "Plume Article" do
    Tesla.Mock.mock(fn
      %{url: "https://xyz.local/~/PlumeDevelopment/this-month-in-plume-june-2018/"} ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/baptiste.gelex.xyz-article.json"),
          headers: HttpRequestMock.activitypub_object_headers()
        }

      %{url: "https://xyz.local/@/BaptisteGelez"} ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/baptiste.gelex.xyz-user.json"),
          headers: HttpRequestMock.activitypub_object_headers()
        }

      env ->
        apply(HttpRequestMock, :request, [env])
    end)

    {:ok, object} =
      Fetcher.fetch_object_from_id(
        "https://xyz.local/~/PlumeDevelopment/this-month-in-plume-june-2018/"
      )

    assert object.data["name"] == "This Month in Plume: June 2018"

    assert object.data["url"] ==
             "https://xyz.local/~/PlumeDevelopment/this-month-in-plume-june-2018/"
  end

  test "Prismo Article" do
    Tesla.Mock.mock(fn
      %{url: "https://prismo.local/@mxb"} ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/https___prismo.news__mxb.json"),
          headers: HttpRequestMock.activitypub_object_headers()
        }

      env ->
        apply(HttpRequestMock, :request, [env])
    end)

    data = file("fixtures/prismo-url-map.json") |> Jason.decode!()

    {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)
    object = Object.normalize(data["object"], fetch: false)

    assert object.data["url"] == "https://prismo.local/posts/83"
  end
end
