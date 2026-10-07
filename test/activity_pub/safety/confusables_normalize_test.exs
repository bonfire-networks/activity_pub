defmodule ActivityPub.Safety.ConfusablesNormalizeTest do
  @moduledoc """
  `ExConfusables.normalize/1` folds text that looks alike to one form, for matching rather than display. `ActivityPub.MRF.KeywordPolicy` uses it to catch homoglyph evasion, and local username uniqueness uses it so a look-alike of an existing username is refused.
  """
  use ExUnit.Case, async: true
  @moduletag :ap_lib

  for {input, expected, why} <- [
        {"аlice", "alice", "Cyrillic а"},
        {"sαιd", "said", "Greek α and ι"},
        {"josé", "jose", "a precomposed accent"},
        {"josé", "jose", "a combining accent"},
        {"jo​sé", "jose", "a zero-width space"},
        {"𝐛𝐨𝐥𝐝", "bold", "mathematical bold letters"},
        {"ｆｕｌｌ", "full", "full-width letters"},
        {"你好", "你好", "CJK, which has no look-alikes to fold"},
        {"alice", "alice", "plain ASCII"}
      ] do
    test "#{why}: #{inspect(input)} becomes #{inspect(expected)}" do
      assert ExConfusables.normalize(unquote(input)) == unquote(expected)
    end
  end
end
