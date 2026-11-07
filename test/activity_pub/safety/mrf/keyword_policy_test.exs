# Copyright © 2026 Bonfire Contributors 
# Copyright © 2017-2025 Akkoma & Pleroma Authors 
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.MRF.KeywordPolicyTest do
  use ActivityPub.DataCase

  alias ActivityPub.MRF.KeywordPolicy

  setup do: clear_config(:mrf_keyword)

  setup do
    clear_config([:mrf_keyword], %{reject: [], unlisted_from_feeds: [], replace: []})
  end

  describe "rejecting based on keywords" do
    test "a keyword matches whole words of the visible text, not inside longer words or markup" do
      clear_config([:mrf_keyword, :reject], ["ass", "href", "spam"])

      message = %{
        "type" => "Create",
        "object" => %{
          "content" => ~s(<p>a class on <a href="https://x.local/spammer">spammers</a></p>),
          "summary" => ""
        }
      }

      assert {:ok, _} = KeywordPolicy.filter(message)

      # the positive, on the same message: the word on its own
      clear_config([:mrf_keyword, :reject], ["spammers"])
      assert {:reject, _} = KeywordPolicy.filter(message)
    end

    test "a local activity is not checked: local posts are decided when published" do
      clear_config([:mrf_keyword, :reject], ["pun"])

      message = %{
        "type" => "Create",
        "object" => %{"content" => "a good pun", "summary" => ""}
      }

      assert {:reject, _} = KeywordPolicy.filter(message, is_local: false)
      assert {:ok, _} = KeywordPolicy.filter(message, is_local: true)
    end

    test "rejects if string matches in content" do
      clear_config([:mrf_keyword, :reject], ["pun"])

      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "just a daily reminder that compLAINer is a good pun",
          "summary" => ""
        }
      }

      assert {:reject, "[KeywordPolicy] Matches rejected keyword"} =
               KeywordPolicy.filter(message)
    end

    test "rejects if string matches in summary" do
      clear_config([:mrf_keyword, :reject], ["pun"])

      message = %{
        "type" => "Create",
        "object" => %{
          "summary" => "just a daily reminder that compLAINer is a good pun",
          "content" => ""
        }
      }

      assert {:reject, "[KeywordPolicy] Matches rejected keyword"} =
               KeywordPolicy.filter(message)
    end

    test "rejects if regex matches in content" do
      clear_config([:mrf_keyword, :reject], [~r/comp[lL][aA][iI][nN]er/])

      assert true ==
               Enum.all?(["complainer", "compLainer", "compLAiNer", "compLAINer"], fn content ->
                 message = %{
                   "type" => "Create",
                   "object" => %{
                     "content" => "just a daily reminder that #{content} is a good pun",
                     "summary" => ""
                   }
                 }

                 {:reject, "[KeywordPolicy] Matches rejected keyword"} ==
                   KeywordPolicy.filter(message)
               end)
    end

    test "rejects if regex matches in summary" do
      clear_config([:mrf_keyword, :reject], [~r/comp[lL][aA][iI][nN]er/])

      assert true ==
               Enum.all?(["complainer", "compLainer", "compLAiNer", "compLAINer"], fn content ->
                 message = %{
                   "type" => "Create",
                   "object" => %{
                     "summary" => "just a daily reminder that #{content} is a good pun",
                     "content" => ""
                   }
                 }

                 {:reject, "[KeywordPolicy] Matches rejected keyword"} ==
                   KeywordPolicy.filter(message)
               end)
    end

    test "rejects if string matches in history" do
      clear_config([:mrf_keyword, :reject], ["pun"])

      message = %{
        "type" => "Create",
        "object" => %{
          "content" => "just a daily reminder that compLAINer is a good",
          "summary" => "",
          "formerRepresentations" => %{
            "type" => "OrderedCollection",
            "orderedItems" => [
              %{
                "content" => "just a daily reminder that compLAINer is a good pun",
                "summary" => ""
              }
            ]
          }
        }
      }

      assert {:reject, "[KeywordPolicy] Matches rejected keyword"} =
               KeywordPolicy.filter(message)
    end

    test "rejects Updates" do
      clear_config([:mrf_keyword, :reject], ["pun"])

      message = %{
        "type" => "Update",
        "object" => %{
          "content" => "just a daily reminder that compLAINer is a good",
          "summary" => "",
          "formerRepresentations" => %{
            "type" => "OrderedCollection",
            "orderedItems" => [
              %{
                "content" => "just a daily reminder that compLAINer is a good pun",
                "summary" => ""
              }
            ]
          }
        }
      }

      assert {:reject, "[KeywordPolicy] Matches rejected keyword"} =
               KeywordPolicy.filter(message)
    end
  end

  describe "delisting from ftl based on keywords" do
    test "delists if string matches in content" do
      clear_config([:mrf_keyword, :unlisted_from_feeds], ["pun"])

      message = %{
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "type" => "Create",
        "object" => %{
          "content" => "just a daily reminder that compLAINer is a good pun",
          "summary" => ""
        }
      }

      {:ok, result} = KeywordPolicy.filter(message)
      assert ["https://www.w3.org/ns/activitystreams#Public"] == result["cc"]
      refute ["https://www.w3.org/ns/activitystreams#Public"] == result["to"]
    end

    test "delists if string matches in summary" do
      clear_config([:mrf_keyword, :unlisted_from_feeds], ["pun"])

      message = %{
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "type" => "Create",
        "object" => %{
          "summary" => "just a daily reminder that compLAINer is a good pun",
          "content" => ""
        }
      }

      {:ok, result} = KeywordPolicy.filter(message)
      assert ["https://www.w3.org/ns/activitystreams#Public"] == result["cc"]
      refute ["https://www.w3.org/ns/activitystreams#Public"] == result["to"]
    end

    test "delists if regex matches in content" do
      clear_config([:mrf_keyword, :unlisted_from_feeds], [~r/comp[lL][aA][iI][nN]er/])

      assert true ==
               Enum.all?(["complainer", "compLainer", "compLAiNer", "compLAINer"], fn content ->
                 message = %{
                   "type" => "Create",
                   "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                   "object" => %{
                     "content" => "just a daily reminder that #{content} is a good pun",
                     "summary" => ""
                   }
                 }

                 {:ok, result} = KeywordPolicy.filter(message)

                 ["https://www.w3.org/ns/activitystreams#Public"] == result["cc"] and
                   not (["https://www.w3.org/ns/activitystreams#Public"] == result["to"])
               end)
    end

    test "delists if regex matches in summary" do
      clear_config([:mrf_keyword, :unlisted_from_feeds], [~r/comp[lL][aA][iI][nN]er/])

      assert true ==
               Enum.all?(["complainer", "compLainer", "compLAiNer", "compLAINer"], fn content ->
                 message = %{
                   "type" => "Create",
                   "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                   "object" => %{
                     "summary" => "just a daily reminder that #{content} is a good pun",
                     "content" => ""
                   }
                 }

                 {:ok, result} = KeywordPolicy.filter(message)

                 ["https://www.w3.org/ns/activitystreams#Public"] == result["cc"] and
                   not (["https://www.w3.org/ns/activitystreams#Public"] == result["to"])
               end)
    end

    test "delists if string matches in history" do
      clear_config([:mrf_keyword, :unlisted_from_feeds], ["pun"])

      message = %{
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "type" => "Create",
        "object" => %{
          "content" => "just a daily reminder that compLAINer is a good",
          "summary" => "",
          "formerRepresentations" => %{
            "orderedItems" => [
              %{
                "content" => "just a daily reminder that compLAINer is a good pun",
                "summary" => ""
              }
            ]
          }
        }
      }

      {:ok, result} = KeywordPolicy.filter(message)
      assert ["https://www.w3.org/ns/activitystreams#Public"] == result["cc"]
      refute ["https://www.w3.org/ns/activitystreams#Public"] == result["to"]
    end
  end

  describe "replacing keywords" do
    test "replaces keyword if string matches in content" do
      clear_config([:mrf_keyword, :replace], [{"opensource", "free software"}])

      message = %{
        "type" => "Create",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => %{"content" => "ZFS is opensource", "summary" => ""}
      }

      {:ok, %{"object" => %{"content" => result}}} = KeywordPolicy.filter(message)
      assert result == "ZFS is free software"
    end

    test "replaces keyword if string matches in summary" do
      clear_config([:mrf_keyword, :replace], [{"opensource", "free software"}])

      message = %{
        "type" => "Create",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => %{"summary" => "ZFS is opensource", "content" => ""}
      }

      {:ok, %{"object" => %{"summary" => result}}} = KeywordPolicy.filter(message)
      assert result == "ZFS is free software"
    end

    test "replaces keyword if regex matches in content" do
      clear_config([:mrf_keyword, :replace], [
        {~r/open(-|\s)?source\s?(software)?/, "free software"}
      ])

      assert true ==
               Enum.all?(["opensource", "open-source", "open source"], fn content ->
                 message = %{
                   "type" => "Create",
                   "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                   "object" => %{"content" => "ZFS is #{content}", "summary" => ""}
                 }

                 {:ok, %{"object" => %{"content" => result}}} = KeywordPolicy.filter(message)
                 result == "ZFS is free software"
               end)
    end

    test "replaces keyword if regex matches in summary" do
      clear_config([:mrf_keyword, :replace], [
        {~r/open(-|\s)?source\s?(software)?/, "free software"}
      ])

      assert true ==
               Enum.all?(["opensource", "open-source", "open source"], fn content ->
                 message = %{
                   "type" => "Create",
                   "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                   "object" => %{"summary" => "ZFS is #{content}", "content" => ""}
                 }

                 {:ok, %{"object" => %{"summary" => result}}} = KeywordPolicy.filter(message)
                 result == "ZFS is free software"
               end)
    end

    test "replaces keyword if string matches in history" do
      clear_config([:mrf_keyword, :replace], [{"opensource", "free software"}])

      message = %{
        "type" => "Create",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => %{
          "content" => "ZFS is opensource",
          "summary" => "",
          "formerRepresentations" => %{
            "type" => "OrderedCollection",
            "orderedItems" => [
              %{"content" => "ZFS is opensource mew mew", "summary" => ""}
            ]
          }
        }
      }

      {:ok,
       %{
         "object" => %{
           "content" => "ZFS is free software",
           "formerRepresentations" => %{
             "orderedItems" => [%{"content" => "ZFS is free software mew mew"}]
           }
         }
       }} = KeywordPolicy.filter(message)
    end

    test "replaces keyword in Updates" do
      clear_config([:mrf_keyword, :replace], [{"opensource", "free software"}])

      message = %{
        "type" => "Update",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => %{
          "content" => "ZFS is opensource",
          "summary" => "",
          "formerRepresentations" => %{
            "type" => "OrderedCollection",
            "orderedItems" => [
              %{"content" => "ZFS is opensource mew mew", "summary" => ""}
            ]
          }
        }
      }

      {:ok,
       %{
         "object" => %{
           "content" => "ZFS is free software",
           "formerRepresentations" => %{
             "orderedItems" => [%{"content" => "ZFS is free software mew mew"}]
           }
         }
       }} = KeywordPolicy.filter(message)
    end
  end
end
