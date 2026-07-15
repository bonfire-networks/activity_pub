# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.QuoteHandlingTest do
  use ActivityPub.DataCase, async: false
  use Oban.Testing, repo: repo()

  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Test.HttpRequestMock

  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  # We normalise every quote convention (quote/quoteUrl/quoteUri/quoteURL/_misskey_quote/bare FEP-e232 Links) into a single canonical quote tag Link (see `Transformer.fix_quote/2` + `add_quote_tag`)
  describe "fix_quote/1" do
    @quoted "https://mastodon.local/objects/43479e20-c0f8-4f49-bf7f-13fab8234924"
    @quote_rel "https://misskey-hub.net/ns#_misskey_quote"

    defp quote_tags(object, url),
      do: Enum.filter(object["tag"] || [], &(&1["type"] == "Link" and &1["href"] == url))

    test "a misskey quote (quoteUrl) becomes a canonical quote tag" do
      note =
        "fixtures/misskey/quote.json"
        |> file()
        |> Jason.decode!()

      fixed = Transformer.fix_quote(note)

      refute Map.has_key?(fixed, "quoteUrl")
      assert [tag] = quote_tags(fixed, @quoted)
      assert tag["rel"] == @quote_rel
    end

    test "a fedibird quote (quoteUri) becomes a canonical quote tag" do
      note =
        "fixtures/fedibird/quote.json"
        |> file()
        |> Jason.decode!()

      fixed = Transformer.fix_quote(note)

      refute Map.has_key?(fixed, "quoteUri")
      assert [tag] = quote_tags(fixed, @quoted)
      assert tag["rel"] == @quote_rel
    end

    test "a recursive quote is tagged without fetching (fetch recursion is bounded elsewhere)" do
      note =
        "fixtures/misskey/recursive_quote.json"
        |> file()
        |> Jason.decode!()

      fixed = Transformer.fix_quote(note)

      assert [_tag] = quote_tags(fixed, "https://misskey.local/notes/934gok3482")
    end
  end
end
