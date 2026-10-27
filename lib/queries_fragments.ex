# SPDX-License-Identifier: AGPL-3.0-only
defmodule ActivityPub.Queries.Fragments do
  @moduledoc """
  Expressions on an `ap_object` row's `data`, one place each, for use inside a query: `import ActivityPub.Queries.Fragments`, with `Ecto.Query` imported. Apart from `ActivityPub.Queries`, as a macro cannot be used in the module that defines it.
  """

  @doc "The id of the object an activity is about, embedded (`object.id`) or named (`object`). The expression the `ap_object` index on it is built on, so a query filtering on this uses the index."
  defmacro object_id_of(data) do
    quote do
      fragment("coalesce((?)->'object'->>'id', (?)->>'object')", unquote(data), unquote(data))
    end
  end

  @doc "The thread a row is in, its `context`, given the row's binding: from `data`, else from `data_received`, as a signed row's `data` holds only what normalisation changed. Not indexed."
  defmacro context_of(row) do
    quote do
      fragment(
        "coalesce((?)->>'context', (?)->>'context')",
        field(unquote(row), :data),
        field(unquote(row), :data_received)
      )
    end
  end

  @doc "Everyone an activity is addressed to, `to`, `cc`, `bto`, `bcc` and `audience`, as one jsonb array, for one test (`?`) in place of five. A field that is a lone string, as `audience` often is, becomes one element; a missing one adds nothing."
  defmacro recipients(data) do
    quote do
      fragment(
        "(coalesce((?)->'to', '[]'::jsonb) || coalesce((?)->'cc', '[]'::jsonb) || coalesce((?)->'bto', '[]'::jsonb) || coalesce((?)->'bcc', '[]'::jsonb) || coalesce((?)->'audience', '[]'::jsonb))",
        unquote(data),
        unquote(data),
        unquote(data),
        unquote(data),
        unquote(data)
      )
    end
  end
end
