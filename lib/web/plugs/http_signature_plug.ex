# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.HTTPSignaturePlug do
  import Plug.Conn
  import Untangle
  alias ActivityPub.Config
  alias ActivityPub.Safety.HTTP.Signatures, as: SignaturesAdapter
  alias ActivityPub.Web.Plugs.EnsureHTTPSignaturePlug

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

    reject_unsigned? = Config.reject_unsigned?()
    has_signature? = has_signature_header?(conn)
    has_rfc9421? = has_rfc9421_header?(conn)

    if (has_signature? or has_rfc9421?) && (http_method == "POST" or reject_unsigned?) &&
         not served_unsigned_anyway?(conn, http_method) do
      conn = prepare_headers_for_validation(conn, http_method, has_rfc9421?)

      if has_rfc9421? do
        debug(
          %{
            "@method" => Plug.Conn.get_req_header(conn, "@method") |> List.first(),
            "@authority" => Plug.Conn.get_req_header(conn, "@authority") |> List.first(),
            "@path" => Plug.Conn.get_req_header(conn, "@path") |> List.first(),
            "@scheme" => Plug.Conn.get_req_header(conn, "@scheme") |> List.first(),
            "signature-input" =>
              Plug.Conn.get_req_header(conn, "signature-input") |> List.first(),
            "content-digest" => Plug.Conn.get_req_header(conn, "content-digest") |> List.first()
          },
          "RFC 9421 receiver-side headers for verification"
        )
      end

      validated? =
        HTTPSignatures.validate(conn,
          return: :key_host,
          refetch_if_expired: opts[:fetch_public_key] || false
        )

      # When valid, validated? is the sender's hostname (from keyId)
      if is_binary(validated?) do
        format = if has_rfc9421?, do: :rfc9421, else: :cavage
        SignaturesAdapter.maybe_put_signature_format(validated?, format)
      end

      # Reject signatures with stale Date headers to prevent replay attacks
      validated? =
        if is_binary(validated?) and not date_within_skew?(conn) do
          warn("Date header too stale, treating signature as invalid")
          false
        else
          validated?
        end

      # A signature on a delivery has to vouch for the request, the body and the time: otherwise it can be put on any body, or replayed whenever. A delivery that fails this is treated like an unsigned one (`valid_signature` false), as with a stale Date.
      validated? =
        if is_binary(validated?) and http_method == "POST" and
             not delivery_covered?(conn, has_rfc9421?) do
          warn(
            "Signature does not cover the request target, body and time, treating it as invalid"
          )

          false
        else
          validated?
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

  # A signed GET that would be served without a signature anyway is not validated, and flows on as an unsigned one does (no `valid_signature` assign). Validating it means fetching the signer's key, and our fetcher signs every GET as the service actor: two servers that have each lost the other's key would fetch each other's service actor, signed, without end.
  defp served_unsigned_anyway?(conn, "GET"),
    do: not EnsureHTTPSignaturePlug.signature_required?(conn, Config.signed_fetch_required())

  defp served_unsigned_anyway?(_conn, _http_method), do: false

  # Prepare request headers for signature validation
  defp prepare_headers_for_validation(conn, http_method, true = _rfc9421?) do
    # RFC 9421: set derived component values that HTTPSignatures.RFC9421 needs
    request_target = String.downcase("#{http_method}") <> " #{conn.request_path}"

    base_uri = ActivityPub.Web.base_uri()

    conn
    |> put_req_header("@method", String.upcase("#{http_method}"))
    |> put_req_header("@authority", get_authority(base_uri))
    |> put_req_header("@path", conn.request_path)
    |> maybe_put_query()
    |> put_req_header("@scheme", get_scheme(base_uri))
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

  # the signer covers the query in `@target-uri` (without the leading `?`), so the check has to include it too. With no query there is nothing to add.
  defp maybe_put_query(%{query_string: query} = conn) when is_binary(query) and query != "",
    do: put_req_header(conn, "@query", query)

  defp maybe_put_query(conn), do: conn

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

  # Derive @scheme and @authority from configured base_url to avoid proxy mismatches
  defp get_scheme(%URI{scheme: scheme}) do
    scheme || "https"
  end

  defp get_scheme(_), do: "https"

  defp get_authority(%URI{} = uri), do: ActivityPub.Utils.authority(uri) || "localhost"
  defp get_authority(_), do: "localhost"

  defp has_signature_header?(conn) do
    conn |> get_req_header("signature") |> Enum.any?()
  end

  defp has_rfc9421_header?(conn) do
    conn |> get_req_header("signature-input") |> Enum.any?()
  end

  # 1 hour + 1 minute buffer for clock skew
  @max_clock_skew_seconds 3660

  defp date_within_skew?(conn) do
    case get_req_header(conn, "date") do
      [date_str] ->
        case parse_http_date(date_str) do
          {:ok, request_time} ->
            abs(DateTime.diff(DateTime.utc_now(), request_time)) <= @max_clock_skew_seconds

          _ ->
            # Can't parse date — be lenient, don't reject on date alone
            true
        end

      _ ->
        # No Date header — don't reject on date alone
        true
    end
  end

  # What a POST's signature must cover. Cavage: `(request-target)`, `date` and `digest`, with a `Date` header present and fresh. `host` is not required and the `algorithm` is not looked at (some senders put `hs2019` without `(created)`). RFC 9421: `@method`, `@target-uri` and `content-digest`, with `created` present and fresh. The digest itself is recomputed from the body by the DigestPlug and used in place of the header when validating.
  defp delivery_covered?(conn, true = _rfc9421?) do
    with %{"headers" => covered, "created" => created} when is_list(covered) <-
           HTTPSignatures.extract_signature(conn),
         true <- Enum.all?(["@method", "@target-uri", "content-digest"], &(&1 in covered)),
         true <- is_integer(created) do
      abs(System.os_time(:second) - created) <= @max_clock_skew_seconds
    else
      _ -> false
    end
  end

  defp delivery_covered?(conn, false = _rfc9421?) do
    with %{"headers" => covered} when is_list(covered) <- HTTPSignatures.extract_signature(conn),
         true <- Enum.all?(["(request-target)", "date", "digest"], &(&1 in covered)) do
      date_present_and_fresh?(conn)
    else
      _ -> false
    end
  end

  defp date_present_and_fresh?(conn) do
    with [date_str] <- get_req_header(conn, "date"),
         {:ok, request_time} <- parse_http_date(date_str) do
      abs(DateTime.diff(DateTime.utc_now(), request_time)) <= @max_clock_skew_seconds
    else
      _ -> false
    end
  end

  defp parse_http_date(date_str) do
    case :httpd_util.convert_request_date(String.to_charlist(date_str)) do
      {date, time} ->
        NaiveDateTime.from_erl({date, time})
        |> case do
          {:ok, naive} -> DateTime.from_naive(naive, "Etc/UTC")
          error -> error
        end

      _ ->
        {:error, :invalid_date}
    end
  end
end
