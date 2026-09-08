defmodule ActivityPub.Transformer.LanguageMapTest do
  @moduledoc """
  AS2 gives every natural-language property two shapes: `content` (one string) and `contentMap`
  (locale => string). A sender may send only the map, so we derive the plain property from it at
  ingest and every consumer reads one shape.

  This is not limited to `content`: a cuisine.social recipe titles itself with `nameMap` and labels
  its serving size with `servingTypeMap`, and carries a `nameMap` per ingredient and a `contentMap`
  per step, so the derivation is generic over property names and descends the whole document.
  """
  use ActivityPub.DataCase, async: true

  alias ActivityPub.Federator.Transformer

  describe "deriving a property from its language map" do
    test "a single language gives the bare string" do
      assert %{"name" => "Salade de boulgour"} =
               Transformer.fix_language_maps(%{"nameMap" => %{"fr" => "Salade de boulgour"}})
    end

    test "a property the sender already sent is left alone" do
      assert %{"name" => "Sent as-is"} =
               Transformer.fix_language_maps(%{
                 "name" => "Sent as-is",
                 "nameMap" => %{"fr" => "From the map"}
               })
    end

    # cuisine.social sends `"summary": ""`, so a property present but empty is how "no text" arrives,
    # and it must not stand in for the translation the sender did give.
    test "a property the sender sent empty does not block the derivation" do
      assert %{"content" => "Faire bouillir de l'eau."} =
               Transformer.fix_language_maps(%{
                 "content" => "",
                 "contentMap" => %{"fr" => "Faire bouillir de l'eau."}
               })
    end

    test "the language map is kept, so nothing is lost" do
      assert %{"nameMap" => %{"fr" => "Salade de boulgour"}} =
               Transformer.fix_language_maps(%{"nameMap" => %{"fr" => "Salade de boulgour"}})
    end

    test "any property is derived, not just content" do
      assert %{"servingType" => "personnes", "description" => "#salade"} =
               Transformer.fix_language_maps(%{
                 "servingTypeMap" => %{"fr" => "personnes"},
                 "descriptionMap" => %{"fr" => "#salade"}
               })
    end

    test "a key that merely ends in Map is not a language map" do
      object = %{"Map" => %{"fr" => "x"}, "sitemap" => %{"fr" => "y"}}

      assert ^object = Transformer.fix_language_maps(object)
    end

    test "a non-map value is not treated as translations" do
      object = %{"nameMap" => "not a language map"}

      assert ^object = Transformer.fix_language_maps(object)
    end

    test "an empty language map derives nothing" do
      object = %{"nameMap" => %{}}

      assert ^object = Transformer.fix_language_maps(object)
    end
  end

  describe "several languages" do
    # Markup properties are rendered for a reader who may speak either language, so every
    # translation is kept, each in its own `lang`-tagged block.
    test "markup keeps every translation" do
      assert %{"content" => content} =
               Transformer.fix_language_maps(%{
                 "contentMap" => %{"en" => "<p>testing</p>", "es" => "<p>probando</p>"}
               })

      assert content =~ "<p>testing</p>"
      assert content =~ "<p>probando</p>"
      assert content =~ "lang='en'"
      assert content =~ "lang='es'"
    end

    # Mastodon sends both shapes, and the single `content` carries only one of the languages, so the
    # translations replace it rather than being dropped.
    test "markup replaces the single-language content the sender also sent" do
      assert %{"content" => content} =
               Transformer.fix_language_maps(%{
                 "content" => "<p>testing</p>",
                 "contentMap" => %{"en" => "<p>testing</p>", "es" => "<p>probando</p>"}
               })

      assert content =~ "<p>probando</p>"
    end

    test "summary is markup too" do
      assert %{"summary" => summary} =
               Transformer.fix_language_maps(%{
                 "summaryMap" => %{"en" => "spoilers", "es" => "destripes"}
               })

      assert summary =~ "spoilers"
      assert summary =~ "destripes"
    end

    # A title or a unit label is not markup: wrapping it in `<div>`s would put HTML into a heading,
    # so one translation is chosen (the first locale alphabetically, since ingest has no reader to
    # pick for).
    test "a plain property takes one translation, unwrapped" do
      assert %{"name" => "Bulgur salad"} =
               Transformer.fix_language_maps(%{
                 "nameMap" => %{"fr" => "Salade de boulgour", "en" => "Bulgur salad"}
               })
    end
  end

  describe "nested objects" do
    test "each item of a list gets its own derivation" do
      assert %{"ingredients" => [%{"name" => "Boulgour"}, %{"name" => "Lardons"}]} =
               Transformer.fix_language_maps(%{
                 "ingredients" => [
                   %{"nameMap" => %{"fr" => "Boulgour"}, "unit" => "g"},
                   %{"nameMap" => %{"fr" => "Lardons"}, "unit" => "g"}
                 ]
               })
    end

    test "a nested map gets its own derivation" do
      assert %{"location" => %{"name" => "Le Barn"}} =
               Transformer.fix_language_maps(%{
                 "location" => %{"nameMap" => %{"fr" => "Le Barn"}}
               })
    end

    test "derivation reaches an arbitrary depth" do
      assert %{"steps" => [%{"attachment" => [%{"name" => "Deep"}]}]} =
               Transformer.fix_language_maps(%{
                 "steps" => [%{"attachment" => [%{"nameMap" => %{"fr" => "Deep"}}]}]
               })
    end

    test "values that are not objects are carried unchanged" do
      object = %{"tag" => ["#cuisine", "#salade"], "serving" => 6, "recipe" => nil}

      assert ^object = Transformer.fix_language_maps(object)
    end
  end

  describe "documents that have no language maps" do
    test "are returned unchanged" do
      object = %{"type" => "Note", "content" => "<p>hi</p>", "to" => ["…#Public"]}

      assert ^object = Transformer.fix_language_maps(object)
    end

    test "a non-map document is returned unchanged" do
      assert "https://example.local/object/1" =
               Transformer.fix_language_maps("https://example.local/object/1")
    end
  end
end
