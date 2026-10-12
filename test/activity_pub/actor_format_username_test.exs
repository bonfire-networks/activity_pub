defmodule ActivityPub.ActorFormatUsernameTest do
  @moduledoc """
  Building a handle from an actor ("reverse" in https://swicg.github.io/activitypub-webfinger/internationalized), with the actor examples given there: ids use the host's A-label and a percent-encoded username, and `preferredUsername` is unencoded.
  """
  use ExUnit.Case, async: true
  @moduletag :ap_lib

  alias ActivityPub.Actor

  for {id, preferred_username, expected} <- [
        {"https://xn--caf-dma.example/user/%E3%81%95%E3%81%8F%E3%82%89", "さくら",
         "さくら@xn--caf-dma.example"},
        {"https://xn--4kcoa2bca5aa0vzacf2mdd.example/user/%D0%B8%D0%B2%D0%B0%D0%BD", "иван",
         "иван@xn--4kcoa2bca5aa0vzacf2mdd.example"},
        {"https://xn--mxd7a1d.example/user/%D9%84%D9%8A%D9%84%D9%89", "ليلى",
         "ليلى@xn--mxd7a1d.example"}
      ] do
    test "from preferredUsername: #{expected}" do
      assert Actor.format_username(%{
               "id" => unquote(id),
               "preferredUsername" => unquote(preferred_username)
             }) == unquote(expected)
    end

    # without a preferredUsername the last segment of the id is used, which is percent-encoded
    test "from the id alone: #{expected}" do
      assert Actor.format_username(unquote(id)) == unquote(expected)
    end
  end
end
