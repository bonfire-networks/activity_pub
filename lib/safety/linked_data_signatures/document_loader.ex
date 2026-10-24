defmodule ActivityPub.Safety.LinkedDataSignatures.DocumentLoader do
  @moduledoc """
  Custom JSON-LD document loader that serves bundled context files for common fediverse contexts, avoiding network requests during signature verification.

  Falls back to HTTP fetching for unknown contexts.
  """

  @behaviour JSON.LD.DocumentLoader

  alias ActivityPub.JsonLd.Contexts
  alias JSON.LD.DocumentLoader.RemoteDocument

  @impl JSON.LD.DocumentLoader
  def load(url, options) do
    case Contexts.get(url) do
      nil ->
        # through the same checks as other federation requests, since the URL is chosen by whoever sent the document
        RemoteDocument.load(url, options, ActivityPub.Safety.LinkedDataSignatures.HTTPClient)

      document ->
        {:ok, %RemoteDocument{document: document, document_url: url}}
    end
  end
end
