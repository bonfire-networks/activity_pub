# MoodleNet: Connecting and empowering educators worldwide
# Copyright © 2018-2020 Moodle Pty Ltd <https://moodle.com/moodlenet/>
# Contains code from Pleroma <https://pleroma.social/> and CommonsPub <https://commonspub.org/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.Plugs.HTTPSignaturePlug do
  import Plug.Conn
  require Logger

  def init(options) do
    options
  end

  def call(%{assigns: %{valid_signature: true}} = conn, _opts) do
    conn
  end

  def call(conn, _opts) do
    if has_signature_header?(conn) do
      # set (request-target) header to the appropriate value
      # we also replace the digest header with the one we computed
      request_target = String.downcase("#{conn.method}") <> " #{conn.request_path}"

      conn =
        conn
        |> put_req_header("(request-target)", request_target)
        |> case do
          %{assigns: %{digest: digest}} = conn -> put_req_header(conn, "digest", digest)
          conn -> conn
        end

      assign(conn, :valid_signature, HTTPSignatures.validate_conn(conn))
    else
      Logger.debug("No signature header!")
      conn
    end
  end

  defp has_signature_header?(conn) do
    conn |> get_req_header("signature") |> Enum.at(0, false)
  end
end
