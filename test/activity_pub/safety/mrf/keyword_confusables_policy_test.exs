# Copyright © 2026 Bonfire Contributors 
# Copyright © 2017-2025 Akkoma & Pleroma Authors 
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.MRF.KeywordConfusablesPolicyTest do
  use ActivityPub.DataCase

  alias ActivityPub.MRF.KeywordPolicy

  setup do: clear_config(:mrf_keyword)

  setup do
    clear_config([:mrf_keyword], %{reject: [], federated_timeline_removal: [], replace: []})
  end

  describe "rejecting homoglyphs/confusables (Unicode evasion)" do
    # Greek letters that look like Latin
    test "rejects Greek homoglyphs: αιτοε → aito e" do
      clear_config([:mrf_keyword, :reject], ["said"])

      # "sαιd" uses Greek α (alpha) and ι (iota) instead of Latin a and i
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "Already sαιd ιτ",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    test "rejects Cyrillic homoglyphs: аеорсух → aeopcyx" do
      clear_config([:mrf_keyword, :reject], ["export"])

      # "ехроrt" uses Cyrillic е, х, р, о instead of Latin e, x, p, o
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "Don't ехроrt that data",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    test "rejects mathematical script homoglyphs" do
      clear_config([:mrf_keyword, :reject], ["bold"])

      # Mathematical bold letters: 𝐛𝐨𝐥𝐝 (U+1D41B, U+1D428, U+1D425, U+1D41D)
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "This is 𝐛𝐨𝐥𝐝 text",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    test "rejects full-width Latin characters" do
      clear_config([:mrf_keyword, :reject], ["spam"])

      # "ｓｐａｍ" uses full-width characters
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "This is ｓｐａｍ content",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    test "rejects mixed script evasion attempts" do
      clear_config([:mrf_keyword, :reject], ["report"])

      # Mix of Cyrillic and Greek letters that map to Latin
      # Cyrillic р (U+0440) → 'p', Greek ο (U+03BF) → 'o'
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "Please reрοrt this issue",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # Superscript letters are decomposed by NFKC normalization
    test "rejects superscript letter substitutions" do
      clear_config([:mrf_keyword, :reject], ["hate"])

      # ᵃ (U+1D43 MODIFIER LETTER SMALL A) decomposes to 'a' via NFKC
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "Don't hᵃte the player",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # Note: "раѕѕword" uses Cyrillic р, а and Latin-looking Cyrillic ѕ
    test "rejects Cyrillic homoglyphs for 'pass'" do
      clear_config([:mrf_keyword, :reject], ["pass"])

      # Cyrillic а (U+0430) maps to Latin 'a', Cyrillic ѕ (U+0455) maps to Latin 's'
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "Enter your pаѕѕword here",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # Cherokee characters have some mappings in Unicode confusables
    test "rejects Cherokee homoglyphs" do
      clear_config([:mrf_keyword, :reject], ["dave"])

      # Cherokee Ꭰ (U+13A0) maps to 'D', Ꭺ (U+13AA) maps to 'A', Ꮩ (U+13D9) maps to 'V', Ꭼ (U+13AC) maps to 'E'
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "My name is ᎠᎪᏙᎬ",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    test "still matches exact strings without homoglyphs" do
      clear_config([:mrf_keyword, :reject], ["badword"])

      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "This contains badword exactly",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    test "allows content that doesn't match even after normalization" do
      clear_config([:mrf_keyword, :reject], ["forbidden"])

      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "This is αllοwεd content with Greek letters",
          "summary" => ""
        }
      }

      assert {:ok, _} = KeywordPolicy.filter(message)
    end

    test "rejects homoglyphs in summary field" do
      clear_config([:mrf_keyword, :reject], ["scam"])

      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "Check this out",
          "summary" => "Not a ѕсаm at all"
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    test "delists homoglyph content from federated timeline" do
      clear_config([:mrf_keyword, :federated_timeline_removal], ["crypto"])

      message = %{
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "type" => "Create",
        "object" => %{
          "content" => "Buy сryрtο now!",
          "summary" => ""
        }
      }

      {:ok, result} = KeywordPolicy.filter(message)
      assert ["https://www.w3.org/ns/activitystreams#Public"] == result["cc"]
      refute ["https://www.w3.org/ns/activitystreams#Public"] == result["to"]
    end

    test "rejects mixed scripts within same word: Latin + Cyrillic + Greek" do
      clear_config([:mrf_keyword, :reject], ["password"])

      # "pаѕѕwοrd" mixes:
      # - Latin: p, w, r, d
      # - Cyrillic: а (a), ѕ (s), ѕ (s)
      # - Greek: ο (o)
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "Enter pаѕѕwοrd here",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    test "rejects heavily mixed single word with multiple scripts" do
      clear_config([:mrf_keyword, :reject], ["attack"])

      # "аttаck" mixes:
      # - Cyrillic: а (U+0430) → a
      # - Latin: t, t, c, k
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "Launching аttаck now",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    test "rejects alternating script characters" do
      clear_config([:mrf_keyword, :reject], ["hello"])

      # Alternating Latin and Cyrillic: h(lat) е(cyr) l(lat) l(lat) о(cyr)
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "hеllо world",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    test "rejects unicode + diacritics combined evasion" do
      clear_config([:mrf_keyword, :reject], ["naive"])

      # Using ï (Latin with diaeresis) and mixing with Greek α
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "Don't be so nαïve about it",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # Hebrew samekh (ס) maps to 'o' in Unicode confusables
    test "rejects Hebrew samekh homoglyph for 'o'" do
      clear_config([:mrf_keyword, :reject], ["cool"])

      # Using Hebrew samekh (ס) for o: "cססl" → "cool"
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "That's cססl",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # Accented characters (diacritics on i, etc.)
    test "rejects accented character substitutions" do
      clear_config([:mrf_keyword, :reject], ["wikipedia"])

      # Using í (acute accent) and ì (grave accent) for i
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "Check wíkìpedía for info",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    test "rejects combining diacritical marks" do
      clear_config([:mrf_keyword, :reject], ["hello"])

      # Using combining diacritical marks (e.g., h + combining acute = h́)
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "h́éĺĺó world",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # TODO: Currency symbols don't map to letters in Unicode confusables
    @tag :todo
    test "rejects currency symbol substitutions" do
      clear_config([:mrf_keyword, :reject], ["eyes"])

      # € and ¥ don't map to E and Y in Unicode confusables - they're semantic not visual
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "My €¥€s are tired",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # CJK compatibility characters
    test "rejects CJK enclosed/compatibility characters" do
      clear_config([:mrf_keyword, :reject], ["stock"])

      # Using ㈱ (parenthesized ideograph stock) or circled letters
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "Buy Ⓢⓣⓞⓒⓚ now",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # Typographic ligatures
    test "rejects typographic ligatures" do
      clear_config([:mrf_keyword, :reject], ["office"])

      # Using ﬀ (ff ligature), ﬁ (fi ligature), ﬂ (fl ligature)
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "The oﬃce is closed",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # Zero-width characters inserted between letters
    test "rejects zero-width character insertion" do
      clear_config([:mrf_keyword, :reject], ["bad"])

      # Inserting zero-width space (U+200B) or zero-width joiner (U+200D) between letters
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "This is b\u200Ba\u200Bd content",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # Modifier letters decompose via NFKC normalization
    test "rejects modifier letter substitutions" do
      clear_config([:mrf_keyword, :reject], ["nth"])

      # Modifier letters: ⁿ (U+207F) → n, ᵗ (U+1D57) → t, ʰ (U+02B0) → h
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "The ⁿᵗʰ degree",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # Letterlike symbols - ℡ (U+2121) decomposes to "TEL" via NFKC, not "t"
    # This test needs a pattern that works with NFKC decomposition
    test "rejects letterlike symbols" do
      clear_config([:mrf_keyword, :reject], ["tel"])

      # ℡ (U+2121 TELEPHONE SIGN) decomposes to "TEL" via NFKC normalization
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "Call us at ℡123",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # Enclosed alphanumerics
    test "rejects enclosed alphanumerics" do
      clear_config([:mrf_keyword, :reject], ["help"])

      # Using circled letters: Ⓗ Ⓔ Ⓛ Ⓟ
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "I need ⒽⒺⓁⓅ please",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # gets normalised to "Get free rnoney now!"
    @tag :fixme
    test "rejects homoglyphs with regex patterns" do
      clear_config([:mrf_keyword, :reject], [~r/free.*money/i])

      # Using Cyrillic and Greek letters
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "Get frее mοnеy now!",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # gets normalised to this is the ǝnd
    @tag :fixme
    test "rejects reversed/mirrored character substitutions" do
      clear_config([:mrf_keyword, :reject], ["end"])

      # Ǝ (U+018E LATIN CAPITAL LETTER REVERSED E) should map to E 
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "This is the Ǝnd",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # gets normalised to check out vlrn editor
    @tag :fixme
    test "rejects roman numerals as letter substitutes via NFKC normalization" do
      clear_config([:mrf_keyword, :reject], ["vi"])

      # Roman numeral Ⅵ (U+2165) decomposes to "VI" via NFKC
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "Check out Ⅵm editor",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    @tag :todo
    test "rejects small caps as letter substitutes" do
      clear_config([:mrf_keyword, :reject], ["bad"])

      # Small caps: ʙ (U+0299) → B, ᴀ (U+1D00) → A, ᴅ (U+1D05) → D
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "That's ʙᴀᴅ news",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # TODO: Thai characters don't have Latin homoglyph mappings in Unicode confusables
    @tag :todo
    test "rejects Thai homoglyphs (modern typography)" do
      clear_config([:mrf_keyword, :reject], ["sun"])

      # Thai ร (S), น (u), ท (n) - not mapped to Latin in Unicode confusables
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "The รนท is bright",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end

    # TODO: Simplified/Traditional Chinese 
    @tag :todo
    test "rejects Chinese simplified/traditional variants" do
      clear_config([:mrf_keyword, :reject], ["国"])

      # Traditional: 國, Simplified: 国 - these are semantic not visual equivalences
      # Unicode confusables is for visual similarity, not meaning
      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "中國 is written as 中国",
          "summary" => ""
        }
      }

      assert {:reject, _} =
               KeywordPolicy.filter(message)
    end
  end
end
