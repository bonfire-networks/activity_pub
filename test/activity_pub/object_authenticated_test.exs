defmodule ActivityPub.ObjectAuthenticatedTest do
  @moduledoc """
  How a stored object was vouched for is kept on its row (`authenticated`), so a copy that is not vouched for can be told from one that is, and a better one can replace it. Who vouched for a delivery is not kept: `signed_by` is virtual.
  """
  use ActivityPub.DataCase, async: true

  alias ActivityPub.Object

  @values [
    :embedded,
    :http_signature,
    :ld_signature,
    :integrity_proof,
    :fetched,
    :unverified,
    :unfetchable
  ]

  defp attrs(extra \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        data: %{
          "id" => "https://stored-#{n}.example/notes/#{n}",
          "type" => "Note",
          "content" => "hello"
        },
        local: false
      },
      extra
    )
  end

  # straight from the table, past the cache
  defp stored(%Object{id: id}), do: ActivityPub.Utils.repo().get!(Object, id)

  test "an object stored with no value has none" do
    assert {:ok, object} = Object.do_insert(attrs())

    assert stored(object).authenticated == nil
  end

  for value <- @values do
    test "#{value} is kept on the row" do
      assert {:ok, object} = Object.do_insert(attrs(%{authenticated: unquote(value)}))

      assert stored(object).authenticated == unquote(value)
    end
  end

  test "a value that is not one of them is refused" do
    changeset = Object.changeset(attrs(%{authenticated: :trust_me}))

    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :authenticated)
  end

  test "who vouched for a delivery is not kept" do
    refute :signed_by in Object.__schema__(:fields)

    assert {:ok, object} =
             Object.do_insert(
               attrs(%{authenticated: :http_signature, signed_by: "https://x.example/u"})
             )

    assert stored(object).signed_by == nil
  end
end
