# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.HTTPSignaturePlug do
  import Plug.Conn
  import Untangle
  alias ActivityPub.Config

  def init(options) do
    options
  end

  def call(%{assigns: %{current_actor: %{}}} = conn, _opts) do
    # already authorized somehow?
    conn
  end

  def call(%{assigns: %{current_user: %{}}} = conn, _opts) do
    # already authorized somehow?
    conn
  end

  def call(%{assigns: %{valid_signature: true}} = conn, _opts) do
    # used for tests
    debug("already validated somehow")
    conn
  end

  def call(%{method: http_method} = conn, opts) do
    Logger.metadata(action: info("HTTPSignaturePlug"))

    reject_unsigned? = Config.get([:activity_pub, :reject_unsigned], false)
    has_signature_header? = has_signature_header?(conn)

    if has_signature_header? && (http_method == "POST" or reject_unsigned?) do
      # set (request-target) header to the appropriate value
      # we also replace the digest header with the one we computed in `ActivityPub.Web.Plugs.DigestPlug`
      request_target = String.downcase("#{http_method}") <> " #{conn.request_path}"

      conn =
        conn
        |> put_req_header("(request-target)", request_target)
        |> case do
          %{assigns: %{digest: digest}} = conn ->
            put_req_header(
              conn,
              "digest",
              digest
              |> debug("diggest")
            )

          conn ->
            debug(conn.assigns, "no diggest")
            conn
        end

      validated? =
        if opts[:fetch_public_key] do
          HTTPSignatures.validate(conn)
        else
          HTTPSignatures.validate_cached(conn)
        end

      assign(
        conn,
        :valid_signature,
        validated?
        |> info("valid_signature?")
      )
    else
      if !has_signature_header? do
        warn(conn.req_headers, "conn has no signature header!")
      else
        warn(
          reject_unsigned?,
          "skip verifying signature for #{http_method} and `reject_unsigned?` set to "
        )
      end

      conn
    end
  end

  defp has_signature_header?(conn) do
    conn |> get_req_header("signature") |> Enum.at(0, false)
  end
end
