# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.MRF.KeywordMatcherTest do
  @moduledoc """
  Keywords match whole words of the visible text, case-insensitive. A `*` at either end of a keyword lets it run into a longer word on that side: `spam*` matches "spammer", `*spam` matches "antispam", `*spam*` matches anywhere.
  """
  use ExUnit.Case, async: true

  @moduletag :ap_lib

  alias ActivityPub.MRF.KeywordMatcher

  defp matches?(keywords, html_or_fields, opts \\ []),
    do: KeywordMatcher.match?(KeywordMatcher.compile(keywords), List.wrap(html_or_fields), opts)

  describe "whole words and wildcards" do
    test "a keyword without * matches only as a whole word, whatever the case" do
      for text <- ["Spam!", "#spam", "a spam.", "SPAM"],
          do: assert(matches?(["spam"], text), text)

      for text <- ["spammer", "antispam", "spamming"],
          do: refute(matches?(["spam"], text), text)
    end

    test "a * at the end lets the keyword start a longer word" do
      assert matches?(["spam*"], "spammer")
      assert matches?(["spam*"], "spam")
      refute matches?(["spam*"], "antispam")
    end

    test "a * at the start lets the keyword end a longer word" do
      assert matches?(["*spam"], "antispam")
      refute matches?(["*spam"], "spammer")
    end

    test "a * at both ends matches anywhere" do
      assert matches?(["*spam*"], "antispammer")
    end

    test "a short keyword does not match inside an unrelated word" do
      refute matches?(["ass"], "a class on passing assessments")
    end

    test "a phrase matches as a whole" do
      assert matches?(["crypto bro"], "what a Crypto Bro!")
      refute matches?(["crypto bro"], "crypto brother")
    end

    test "punctuation at either end of a keyword is part of it" do
      assert matches?(["#tag"], "about #tag.")
      refute matches?(["#tag"], "about #tagline")
      assert matches?(["wow!"], "wow! ok")
    end

    test "words in other scripts have the same boundaries" do
      assert matches?(["кот"], "мой кот.")
      refute matches?(["кот"], "котик")
      assert matches?(["*猫*"], "我的猫很可爱")
    end
  end

  describe "visible text only" do
    test "markup is not matched" do
      html = ~s(<a href="https://x.local" class="mention hashtag" rel="tag">hi</a>)

      for keyword <- ["href", "class", "mention", "rel"],
          do: refute(matches?([keyword], html), keyword)
    end

    test "a hashtag's text is matched as shown, with its #" do
      assert matches?(["#tag"], ~s(<a class="hashtag" href="/t/tag">#<span>tag</span></a>))
    end

    test "entities are decoded" do
      assert matches?(["&"], "a &amp; b")
    end

    test "an already parsed document matches like its HTML" do
      html = "<p>buy cheap spam</p>"
      assert matches?(["spam"], LazyHTML.from_fragment(html))
      refute matches?(["spammer"], LazyHTML.from_fragment(html))
    end

    test "any of several fields can match" do
      assert matches?(["spam"], ["a title", nil, "<p>some spam</p>"])
    end
  end

  describe "confusables" do
    test "look-alike letters and invisible characters don't hide a keyword" do
      # Greek α and ι for a and i
      assert matches?(["said"], "Already sαιd it")
      # zero-width joiners inside the word
      assert matches?(["bad"], "so b‍a‍d")
    end

    # the example the keyword settings give
    test "digits that look like letters don't hide a keyword" do
      assert matches?(["cool"], "so c00l")
      assert matches?(["cool"], "so C00L")
    end

    test "can be turned off" do
      refute matches?(["said"], "Already sαιd it", confusables: false)
    end

    test "regex keywords still match" do
      assert matches?([~r/comp[lL][aA][iI][nN]er/], "the compLAINer")
    end
  end

  describe "nothing to match" do
    test "no keywords compile to nil, which matches nothing" do
      assert KeywordMatcher.compile([]) == nil
      assert KeywordMatcher.compile(["", "  ", nil]) == nil
      refute KeywordMatcher.match?(nil, ["anything"])
    end
  end
end
