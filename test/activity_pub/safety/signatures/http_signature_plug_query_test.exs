defmodule ActivityPub.Web.Plugs.HTTPSignaturePlugQueryTest do
  @moduledoc """
  A signed RFC 9421 GET of a URL with a query is validated with the query covered, as the signer covers it in `@target-uri`.

  Lives apart from `http_signature_plug_test.exs`, which swaps `HTTPSignatures.validate` for a stub: these tests need the real check.
  """
  use ActivityPub.Web.ConnCase, async: false

  import ActivityPub.Factory
  import Plug.Conn
  import Phoenix.Controller, only: [put_format: 2]

  alias ActivityPub.Safety.Keys
  alias ActivityPub.Web.Plugs.HTTPSignaturePlug

  setup do
    clear_config([:reject_unsigned], true)
    {:ok, signer} = ActivityPub.Actor.get_cached(username: local_actor().username)
    {:ok, signer: signer}
  end

  defp signed_get(url, signer) do
    uri = URI.parse(url)

    headers =
      Keys.maybe_add_fetch_signature_headers([], uri,
        signature_format: :rfc9421,
        current_actor: {:ok, signer}
      )

    assert Enum.any?(headers, fn {k, _} -> k == "signature-input" end)

    conn = build_conn(:get, url) |> put_format("activity+json")

    headers
    |> Enum.reduce(conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> HTTPSignaturePlug.call(%{})
  end

  test "a signed GET of a URL with a query is valid", %{signer: signer} do
    conn =
      signed_get(ActivityPub.Utils.ap_base_url() <> "/collections/narrower/abc?page=1", signer)

    assert conn.assigns.valid_signature == true
  end

  test "control: a signed GET of the same URL without a query is valid", %{signer: signer} do
    conn = signed_get(ActivityPub.Utils.ap_base_url() <> "/collections/narrower/abc", signer)

    assert conn.assigns.valid_signature == true
  end
end
