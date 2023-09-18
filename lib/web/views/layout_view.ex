defmodule ActivityPub.Web.LayoutView do
  use ActivityPub.Web, :view

  def render("app.html", assigns) do
    ~H"""
    <%= @inner_content %>
    """
  end
end
