# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.HTTPSignaturePlug do
  import Plug.Conn
  import Untangle

  def init(options) do
    options
  end

  def call(%{assigns: %{valid_signature: true}} = conn, _opts) do
    # already validated somehow?
    conn
  end

  def call(conn, _opts) do
    Logger.metadata(action: info("HTTPSignaturePlug"))

    if has_signature_header?(conn) do
      # set (request-target) header to the appropriate value
      # we also replace the digest header with the one we computed
      request_target = String.downcase("#{conn.method}") <> " #{conn.request_path}"

      conn =
        conn
        |> put_req_header("(request-target)", request_target)
        |> case do
          %{assigns: %{digest: digest}} = conn ->
            put_req_header(conn, "digest", digest)

          conn ->
            conn
        end

      validate =
        HTTPSignatures.validate_conn(conn)
        |> info("valid_signature?")

      assign(conn, :valid_signature, validate)
    else
      warn("conn has no signature header!")
      conn
    end
  end

  defp has_signature_header?(conn) do
    conn |> get_req_header("signature") |> Enum.at(0, false)
  end
end
