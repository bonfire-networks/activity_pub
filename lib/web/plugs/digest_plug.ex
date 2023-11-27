# Copyright © 2017-2021 Pleroma & Akkoma Authors 
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.DigestPlug do
  alias Plug.Conn
  require Logger

  def read_body(conn, opts) do
    digest_algorithm =
      with [digest_header] <- Conn.get_req_header(conn, "digest") do
        digest_header
        |> String.split("=", parts: 2)
        |> List.first()
      else
        _ -> "SHA-256"
      end

    unless String.downcase(digest_algorithm) == "sha-256" do
      raise ArgumentError,
        message: "invalid value for digest algorithm, got: #{digest_algorithm}"
    end

    {:ok, body, conn} = Conn.read_body(conn, opts)
    encoded_digest = :crypto.hash(:sha256, body) |> Base.encode64()
    {:ok, body, Conn.assign(conn, :digest, "#{digest_algorithm}=#{encoded_digest}")}
  end
end
