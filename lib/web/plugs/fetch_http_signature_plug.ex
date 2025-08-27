# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Web.Plugs.FetchHTTPSignaturePlug do
  def init(options) do
    options
  end

  def call(%{assigns: %{current_user: %{}}} = conn, _opts) do
    # already authorized somehow?
    conn
  end

  def call(%{assigns: %{valid_signature: true}} = conn, _opts) do
    # already validated somehow?
    conn
  end

  def call(conn, _opts) do
    ActivityPub.Web.Plugs.HTTPSignaturePlug.call(conn, fetch_public_key: true)
  end
end
