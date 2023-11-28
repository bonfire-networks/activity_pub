# Copyright © 2017-2021 Pleroma & Akkoma Authors 
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.DigestPlug do
  alias Plug.Conn
  import Untangle

  def read_body(conn, opts) do
    {:ok, body, conn} = Conn.read_body(conn, opts)

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

      {:ok, body, Conn.assign(conn, :digest, "#{digest_algorithm}=#{encoded_digest}")}
    else
      _ ->
        debug("no digest header so we skip computing the hash")
        {:ok, body, conn}
    end
  end
end
