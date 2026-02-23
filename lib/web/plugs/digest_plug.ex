# Copyright © 2017-2021 Pleroma & Akkoma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.DigestPlug do
  alias Plug.Conn
  import Untangle

  def read_body(conn, opts) do
    {:ok, body, conn} = Conn.read_body(conn, opts)

    conn =
      conn
      |> maybe_compute_digest(body)
      |> maybe_compute_content_digest(body)

    {:ok, body, conn}
  end

  # Legacy Digest header (draft-cavage / RFC 3230)
  # Format: Digest: SHA-256=base64value
  defp maybe_compute_digest(conn, body) do
    with [digest_header] <- Conn.get_req_header(conn, "digest") do
      digest_algorithm =
        digest_header
        |> String.split("=", parts: 2)
        |> List.first()

      unless String.downcase(digest_algorithm) == "sha-256" do
        raise ArgumentError,
          message: "invalid value for digest algorithm, got: #{digest_algorithm}"
      end

      encoded_digest = :crypto.hash(:sha256, body) |> Base.encode64()
      debug(encoded_digest, "encoded_digest")

      Conn.assign(conn, :digest, "#{digest_algorithm}=#{encoded_digest}")
    else
      _ -> conn
    end
  end

  # Content-Digest header (RFC 9530, used by RFC 9421 senders)
  # Format: Content-Digest: sha-256=:base64value:
  defp maybe_compute_content_digest(conn, body) do
    with [content_digest_header] <- Conn.get_req_header(conn, "content-digest") do
      # Parse "sha-256=:base64value:" format
      case String.split(content_digest_header, "=", parts: 2) do
        [algorithm, _value] ->
          unless String.downcase(algorithm) == "sha-256" do
            raise ArgumentError,
              message: "invalid value for content-digest algorithm, got: #{algorithm}"
          end

          encoded_digest = :crypto.hash(:sha256, body) |> Base.encode64()
          debug(encoded_digest, "encoded_content_digest")

          # Store in RFC 9530 format: sha-256=:base64:
          Conn.assign(conn, :content_digest, "sha-256=:#{encoded_digest}:")

        _ ->
          warn(content_digest_header, "malformed content-digest header")
          conn
      end
    else
      _ -> conn
    end
  end
end
