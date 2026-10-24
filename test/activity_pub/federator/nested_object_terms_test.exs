defmodule ActivityPub.Federator.NestedObjects.TermsTest do
  @moduledoc """
  Which fields of a document hold objects is read from its `@context`, not from the values: a string carries no marker, and the context says which terms have IRI values (`"@type": "@id"`, ActivityStreams Core §5.1). No JSON-LD expansion is involved, only the term definitions.

  The set is the IRI-typed terms of the bundled contexts and of the contexts the document names (inline, or fetched once and cached), plus the terms added in config, minus the fields that are never ingested.
  """
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Federator.NestedObjects.Terms

  @as2 "https://www.w3.org/ns/activitystreams"

  setup do
    Process.put(:activity_pub_enable_cache, true)
    n = System.unique_integer([:positive])
    %{n: n, host: "ctx-#{n}.example"}
  end

  defp fields(context, extra \\ %{}),
    do: Terms.fields(Map.merge(%{"@context" => context, "type" => "Event"}, extra))

  describe "the bundled ActivityStreams context" do
    test "has the object-valued terms" do
      set = fields(@as2)

      for term <- ["location", "instrument", "generator", "result", "origin", "target", "preview"],
          do: assert(term in set, "#{term} is IRI-typed in the context")
    end

    test "has no term that holds a literal" do
      set = fields(@as2)

      for term <- ["name", "content", "published", "summary", "duration"],
          do: refute(term in set, "#{term} is a literal")
    end

    test "has no field we never ingest" do
      set = fields(@as2)

      for term <- [
            "actor",
            "attributedTo",
            "inReplyTo",
            "to",
            "cc",
            "bto",
            "bcc",
            "object",
            "audience"
          ],
          do: refute(term in set, "#{term} is object-valued but is never ingested")
    end
  end

  describe "a document's own @context" do
    test "adds the terms it defines as IRIs" do
      set =
        fields([
          @as2,
          %{"ingredients" => %{"@id" => "ex:ingredients", "@type" => "@id"}}
        ])

      assert "ingredients" in set
      assert "location" in set, "the bundled context is still read"
    end

    test "does not add a term defined as a plain string, or typed as anything else" do
      set =
        fields([
          @as2,
          %{
            "sensitive" => "as:sensitive",
            "blurhash" => %{"@id" => "toot:blurhash", "@type" => "xsd:string"},
            "Emoji" => "toot:Emoji"
          }
        ])

      refute "sensitive" in set
      refute "blurhash" in set
      refute "Emoji" in set
    end

    test "can be a single map, a single URL, or a list of both" do
      assert "ingredients" in fields(%{"ingredients" => %{"@id" => "ex:i", "@type" => "@id"}})
      assert "location" in fields(@as2)
      assert "location" in fields([@as2, %{"x" => "ex:x"}])
    end

    test "with no @context has none of its own" do
      assert Terms.fields(%{"type" => "Event"}) |> Enum.to_list() == []
    end
  end

  describe "an unknown remote context" do
    test "is fetched once and its IRI-typed terms are used", %{host: host} do
      url = "https://#{host}/ns/recipes"
      test_pid = self()

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        send(test_pid, {:fetched, url})

        Tesla.Mock.json(%{
          "@context" => %{
            "ingredients" => %{"@id" => "r:ingredients", "@type" => "@id"},
            "servings" => "r:servings"
          }
        })
      end)

      set = fields([@as2, url])

      assert "ingredients" in set
      refute "servings" in set
      assert_received {:fetched, ^url}

      # a second document naming it does not ask again
      assert "ingredients" in fields([@as2, url])
      refute_received {:fetched, ^url}
    end

    test "that cannot be fetched adds nothing, and is not asked for again", %{host: host} do
      url = "https://#{host}/ns/gone"
      test_pid = self()

      Tesla.Mock.mock(fn %{method: :get, url: ^url} ->
        send(test_pid, {:fetched, url})
        %Tesla.Env{status: 404, body: ""}
      end)

      set = fields([@as2, url])

      assert "location" in set, "the rest of the document is still read"
      assert_received {:fetched, ^url}

      fields([@as2, url])
      refute_received {:fetched, ^url}
    end

    test "is not fetched more than the cap allows for one document", %{host: host} do
      test_pid = self()

      Tesla.Mock.mock(fn %{method: :get, url: url} ->
        send(test_pid, {:fetched, url})
        %Tesla.Env{status: 404, body: ""}
      end)

      urls = for i <- 1..20, do: "https://#{host}/ns/#{i}"
      fields([@as2 | urls])

      fetched = Enum.count(1..20, fn _ -> receive_one?() end)
      assert fetched <= 5, "fetched #{fetched} contexts for one document"
      assert fetched > 0, "and some were fetched"
    end
  end

  defp receive_one? do
    receive do
      {:fetched, _} -> true
    after
      0 -> false
    end
  end

  describe "options for one call" do
    test "include fields no context defines, and fields the never-ingest list names" do
      document = %{"@context" => @as2, "type" => "Event"}

      set = Terms.fields(document, nil, include_fields: ["somethingElse", "inReplyTo"])

      assert "somethingElse" in set
      assert "inReplyTo" in set, "an option wins over the config list"
      assert "location" in set
    end

    test "exclude fields a context defines" do
      document = %{"@context" => @as2, "type" => "Event"}

      set = Terms.fields(document, nil, exclude_fields: ["location"])

      refute "location" in set
      assert "instrument" in set
    end

    test "win over config both ways" do
      clear_config([:nested_objects, :include_fields], ["ingredients"])
      clear_config([:nested_objects, :exclude_fields], ["location"])
      document = %{"@context" => @as2, "type" => "Event"}

      set =
        Terms.fields(document, nil, include_fields: ["location"], exclude_fields: ["ingredients"])

      assert "location" in set
      refute "ingredients" in set
    end
  end

  describe "config" do
    test "has the fields to leave alone in the config file, under the same name as the option, the same as the code default" do
      configured = ActivityPub.Config.get([:nested_objects, :exclude_fields])

      assert is_list(configured) and configured != []

      for field <- ["actor", "attributedTo", "inReplyTo", "to", "cc"],
          do: assert(field in configured)
    end

    test "adds terms no context defines" do
      clear_config([:nested_objects, :include_fields], ["ingredients"])

      assert "ingredients" in fields(@as2)
    end

    test "removes a term from what is ingested" do
      clear_config([:nested_objects, :exclude_fields], ["location"])

      refute "location" in fields(@as2)
      assert "instrument" in fields(@as2)
    end
  end

  describe "policies" do
    # what is done with a nested object nobody vouched for, per field; `include_fields` carries it, a plain name being the default
    defp policies(opts \\ []),
      do: Terms.policies(%{"@context" => @as2, "type" => "Event"}, nil, opts)

    test "are :authenticate_or_store for every field, by default" do
      policies = policies()

      assert policies["location"] == :authenticate_or_store
      assert policies["instrument"] == :authenticate_or_store
    end

    test "default to what config says, for every field not given one" do
      clear_config([:nested_objects, :default_policy], :authenticate_or_drop)

      clear_config([:nested_objects, :include_fields], [
        {"location", :authenticate_or_fetch_or_store}
      ])

      assert policies()["instrument"] == :authenticate_or_drop
      assert policies()["location"] == :authenticate_or_fetch_or_store
    end

    test "are the same fields as fields/3" do
      assert policies() |> Map.keys() |> MapSet.new() == fields(@as2)
    end

    test "are set per field in config, by a {name, policy} pair in include_fields" do
      clear_config([:nested_objects, :include_fields], [
        {"location", :authenticate_or_fetch_or_drop}
      ])

      assert policies()["location"] == :authenticate_or_fetch_or_drop
      assert policies()["instrument"] == :authenticate_or_store
    end

    test "can be given as a map too" do
      clear_config([:nested_objects, :include_fields], %{"location" => :authenticate_or_drop})

      assert policies()["location"] == :authenticate_or_drop
    end

    test "add a field no context defines, with its policy" do
      clear_config([:nested_objects, :include_fields], [
        {"ingredients", :authenticate_or_fetch_or_store}
      ])

      assert policies()["ingredients"] == :authenticate_or_fetch_or_store
    end

    test "of one call win over the config's" do
      clear_config([:nested_objects, :include_fields], [{"location", :authenticate_or_drop}])

      assert policies(include_fields: [{"location", :authenticate_or_fetch_or_store}])["location"] ==
               :authenticate_or_fetch_or_store
    end

    test "a plain name in a call's include_fields keeps the config's policy for it" do
      clear_config([:nested_objects, :include_fields], [{"location", :authenticate_or_drop}])

      assert policies(include_fields: ["location"])["location"] == :authenticate_or_drop
    end

    test "leave out what exclude_fields names, whatever its policy" do
      clear_config([:nested_objects, :include_fields], [{"location", :authenticate_or_drop}])

      refute Map.has_key?(policies(exclude_fields: ["location"]), "location")
    end
  end
end
