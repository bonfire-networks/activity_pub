defmodule ActivityPub.JsonLd.ContextsTest do
  @moduledoc """
  The JSON-LD contexts bundled in `priv/json_ld_contexts`, read once at compile time. A document that names one of them must never make us fetch it: the LD signature loader reads them from here, and so does the set of fields that hold objects.

  The two that FEP-8b32 adds are the ones a document carrying an integrity proof names: `data-integrity/v2` (the `proof` term and its type) and `cid/v1` (`Multikey`, `assertionMethod`).
  """
  use ExUnit.Case, async: true

  alias ActivityPub.JsonLd.Contexts
  alias ActivityPub.Safety.LinkedDataSignatures.DocumentLoader

  @bundled [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/v1",
    "https://w3id.org/identity/v1",
    "https://w3id.org/security/data-integrity/v2",
    "https://www.w3.org/ns/cid/v1"
  ]

  for url <- @bundled do
    test "#{url} is bundled, and decoded" do
      assert Contexts.bundled?(unquote(url))
      assert %{"@context" => _} = Contexts.get(unquote(url))
    end
  end

  test "the loader serves each from the bundle, without a request" do
    for url <- @bundled do
      assert {:ok, %{document: %{"@context" => _}, document_url: ^url}} =
               DocumentLoader.load(url, [])
    end
  end

  test "data-integrity/v2 defines the proof term as an IRI" do
    assert "proof" in Contexts.iri_terms("https://w3id.org/security/data-integrity/v2")
  end

  test "cid/v1 defines the key terms as IRIs" do
    terms = Contexts.iri_terms("https://www.w3.org/ns/cid/v1")

    for term <- ["assertionMethod", "verificationMethod", "controller"],
        do: assert(term in terms)
  end

  test "any other URL is not bundled" do
    refute Contexts.bundled?("https://example.org/ns/unknown")
    assert Contexts.get("https://example.org/ns/unknown") == nil
  end
end
