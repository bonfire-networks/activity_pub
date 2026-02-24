defmodule ActivityPub.Safety.LinkedDataSignatures.DocumentLoader do
  @moduledoc """
  Custom JSON-LD document loader that serves bundled context files for common
  fediverse contexts, avoiding network requests during signature verification.

  Falls back to HTTP fetching for unknown contexts.
  """

  @behaviour JSON.LD.DocumentLoader

  alias JSON.LD.DocumentLoader.RemoteDocument

  @bundled_contexts %{
    "https://www.w3.org/ns/activitystreams" => "activitystreams.json",
    "https://w3id.org/security/v1" => "security_v1.json",
    "https://w3id.org/identity/v1" => "identity_v1.json"
  }

  @impl JSON.LD.DocumentLoader
  def load(url, options) do
    case Map.get(@bundled_contexts, url) do
      nil ->
        JSON.LD.DocumentLoader.Default.load(url, options)

      filename ->
        load_bundled(url, filename)
    end
  end

  defp load_bundled(url, filename) do
    path = Path.join(:code.priv_dir(:activity_pub), "json_ld_contexts/#{filename}")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, document} ->
            {:ok,
             %RemoteDocument{
               document: document,
               document_url: url
             }}

          {:error, reason} ->
            {:error, {:json_decode_error, reason}}
        end

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end
end
