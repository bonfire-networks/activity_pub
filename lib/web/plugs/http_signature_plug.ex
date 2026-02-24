# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.HTTPSignaturePlug do
  import Plug.Conn
  import Untangle
  alias ActivityPub.Config
  alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter

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
    has_signature? = has_signature_header?(conn)
    has_rfc9421? = has_rfc9421_header?(conn)

    if (has_signature? or has_rfc9421?) && (http_method == "POST" or reject_unsigned?) do
      conn = prepare_headers_for_validation(conn, http_method, has_rfc9421?)

      validated? =
        HTTPSignatures.validate(conn,
          return: :key_host,
          refetch_if_expired: opts[:fetch_public_key] || false
        )

      # When valid, validated? is the sender's hostname (from keyId)
      if is_binary(validated?) do
        format = if has_rfc9421?, do: :rfc9421, else: :cavage
        SignaturesAdapter.put_signature_format(validated?, format)
      end

      assign(
        conn,
        :valid_signature,
        (validated? != false)
        |> info("valid_signature?")
      )
    else
      if !has_signature? and !has_rfc9421? do
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

  # Prepare request headers for signature validation
  defp prepare_headers_for_validation(conn, http_method, true = _rfc9421?) do
    # RFC 9421: set derived component values that HTTPSignatures.RFC9421 needs
    request_target = String.downcase("#{http_method}") <> " #{conn.request_path}"

    conn
    |> put_req_header("@method", String.upcase("#{http_method}"))
    |> put_req_header("@authority", get_authority(conn))
    |> put_req_header("@path", conn.request_path)
    |> put_req_header("@scheme", to_string(conn.scheme || "https"))
    |> put_req_header("(request-target)", request_target)
    |> maybe_put_content_digest()
    |> maybe_put_legacy_digest()
  end

  defp prepare_headers_for_validation(conn, http_method, false = _rfc9421?) do
    # Draft-cavage: set (request-target) and digest as before
    request_target = String.downcase("#{http_method}") <> " #{conn.request_path}"

    conn
    |> put_req_header("(request-target)", request_target)
    |> maybe_put_legacy_digest()
  end

  defp maybe_put_content_digest(%{assigns: %{content_digest: content_digest}} = conn) do
    put_req_header(conn, "content-digest", content_digest |> debug("content-digest"))
  end

  defp maybe_put_content_digest(conn), do: conn

  defp maybe_put_legacy_digest(%{assigns: %{digest: digest}} = conn) do
    put_req_header(conn, "digest", digest |> debug("digest"))
  end

  defp maybe_put_legacy_digest(conn) do
    debug(conn.assigns, "no digest")
    conn
  end

  defp get_authority(conn) do
    host = conn.host || "localhost"

    case conn.port do
      port when port in [80, 443, nil] -> host
      port -> "#{host}:#{port}"
    end
  end

  defp has_signature_header?(conn) do
    conn |> get_req_header("signature") |> Enum.any?()
  end

  defp has_rfc9421_header?(conn) do
    conn |> get_req_header("signature-input") |> Enum.any?()
  end
end
