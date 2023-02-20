# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.RepliesHandlingTest do
  use ActivityPub.DataCase
  use Oban.Testing, repo: repo()

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Utils
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Test.HttpRequestMock
  alias ActivityPub.Federator.Workers

  import Mock
  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  setup do: clear_config([:instance, :max_remote_account_fields])

  describe "fix_quote_url/1" do
    test "a misskey quote should work", _ do
      Tesla.Mock.mock(fn %{
                           method: :get,
                           url:
                             "https://example.local/objects/43479e20-c0f8-4f49-bf7f-13fab8234924"
                         } ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/quoted_status.json"),
          headers: HttpRequestMock.activitypub_object_headers()
        }
      end)

      local_actor(%{ap_id: "https://misskey.local/users/93492q0ip0"})
      local_actor(%{ap_id: "https://example.local/users/user"})

      note =
        "fixtures/misskey/quote.json"
        |> file()
        |> Jason.decode!()

      %{"quoteUri" => "https://example.local/objects/43479e20-c0f8-4f49-bf7f-13fab8234924"} =
        Transformer.fix_quote_url(note)
    end

    test "a fedibird quote should work", _ do
      Tesla.Mock.mock(fn %{
                           method: :get,
                           url:
                             "https://example.local/objects/43479e20-c0f8-4f49-bf7f-13fab8234924"
                         } ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/quoted_status.json"),
          headers: HttpRequestMock.activitypub_object_headers()
        }
      end)

      local_actor(%{ap_id: "https://fedibird.local/users/akkoma_ap_integration_tester"})
      local_actor(%{ap_id: "https://example.local/users/user"})

      note =
        "fixtures/fedibird/quote.json"
        |> file()
        |> Jason.decode!()

      %{
        "quoteUri" => "https://example.local/objects/43479e20-c0f8-4f49-bf7f-13fab8234924"
      } = Transformer.fix_quote_url(note)
    end

    test "quote fetching should stop after n levels", _ do
      clear_config([:instance, :federation_incoming_max_recursion], 1)

      Tesla.Mock.mock(fn %{
                           method: :get,
                           url: "https://misskey.local/notes/934gok3482"
                         } ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/misskey/recursive_quote.json"),
          headers: HttpRequestMock.activitypub_object_headers()
        }
      end)

      local_actor(%{ap_id: "https://misskey.local/users/93492q0ip0"})

      note =
        "fixtures/misskey/recursive_quote.json"
        |> file()
        |> Jason.decode!()

      %{
        "quoteUri" => "https://misskey.local/notes/934gok3482"
      } = Transformer.fix_quote_url(note)
    end
  end
end
