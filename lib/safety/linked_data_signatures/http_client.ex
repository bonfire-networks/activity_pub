defmodule ActivityPub.Safety.LinkedDataSignatures.HTTPClient do
  @moduledoc """
  HTTP client for `JSON.LD.DocumentLoader.RemoteDocument`, used to load `@context` URLs that aren't bundled. Those URLs are chosen by whoever sent the document being verified, so it applies the same checks as the federation HTTP client (`ActivityPub.Safety.ORF`) on every redirect hop, instead of json_ld's default client which has none.
  """

  alias ActivityPub.Federator.HTTP.Connection

  @max_redirects 3

  def client(headers, _url, _options) do
    adapter = Application.get_env(:tesla, :adapter, {Tesla.Adapter.Finch, name: Bonfire.Finch})

    Tesla.client(
      [
        {Tesla.Middleware.Headers, headers},
        {Tesla.Middleware.FollowRedirects, max_redirects: @max_redirects},
        ActivityPub.Safety.ORF
      ],
      Connection.adapter_options(adapter, [])
    )
  end
end
