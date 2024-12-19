defmodule ActivityPub.Web.ErrorHelpers do
  @moduledoc """
  Conveniences for translating and building error messages.
  """
  # import Phoenix.HTML
  use PhoenixHTMLHelpers

  @doc """
  Generates tag for inlined form input errors.
  """
  def error_tag(form, field) do
    Enum.map(Keyword.get_values(form.errors, field), fn error ->
      content_tag(:span, error, class: "help-block")
    end)
  end
end
