defmodule ActivityPub.Web.CollectionsTest do
  @moduledoc """
  The arithmetic every collection renderer shares, tested once.

  Each renderer used to do this itself and they disagreed. `totalItems` was the length of the page just fetched in five of them, so a collection of any size reported 10; and `next` was emitted whenever a page came back full, which links to an empty page whenever the total is an exact multiple of the page size. Both come from a real count here.

  `fetch` and `count` are stubs on purpose: what is under test is the envelope, not any particular source of items.
  """
  use ExUnit.Case, async: true

  alias ActivityPub.Web.Collections

  defp fetch(n), do: fn _page, _page_size -> Enum.to_list(1..n//1) end
  defp count(n), do: fn -> n end

  test "totalItems is the whole collection, not the page in hand" do
    page = Collections.collection("/outbox", page: 1, fetch: fetch(10), count: count(42))

    assert page["totalItems"] == 42
  end

  test "a page that exactly fills the page size does not link to an empty next page" do
    last = Collections.collection("/outbox", page: 2, fetch: fetch(10), count: count(20))

    refute Map.has_key?(last, "next"),
           "20 items at 10 a page end on page 2, so a `next` here points at nothing"

    earlier = Collections.collection("/outbox", page: 1, fetch: fetch(10), count: count(20))

    assert earlier["next"] == "/outbox?page=2",
           "and the page before it still links on, or history becomes unreachable"
  end

  test "a partial last page has no next either" do
    page = Collections.collection("/outbox", page: 2, fetch: fetch(3), count: count(13))

    refute Map.has_key?(page, "next")
  end

  test "the top level links to its first page" do
    top = Collections.collection("/outbox", fetch: fetch(10), count: count(42))

    assert top["type"] == "OrderedCollection"
    assert top["totalItems"] == 42
    assert top["first"]["id"] == "/outbox?page=1"
  end

  test "an inline collection carries its items and no first, with a last for the rest" do
    top =
      Collections.collection("/outbox",
        fetch: fetch(50),
        count: count(120),
        page_size: 50,
        inline: true
      )

    assert length(top["orderedItems"]) == 50

    refute Map.has_key?(top, "first"),
           "a `first` is what makes PieFed fetch a small page instead of reading these"

    assert top["last"] == "/outbox?page=3",
           "120 items at 50 a page put the oldest on page 3"
  end

  test "an inline collection that holds everything has no last" do
    top =
      Collections.collection("/outbox",
        fetch: fetch(4),
        count: count(4),
        page_size: 50,
        inline: true
      )

    refute Map.has_key?(top, "last"),
           "a `last` pointing at the page you are holding says nothing"
  end

  test "ordered? picks the collection and page vocabulary" do
    unordered =
      Collections.collection("/followers", fetch: fetch(2), count: count(2), ordered?: false)

    assert unordered["type"] == "Collection"
    assert unordered["first"]["type"] == "CollectionPage"
  end

  # A host that does not list who is in a collection (a group's members, say) still says how many. Handing back an empty page would link on to page after empty page, since `next` is `offset + items < total` and a total of 5 with no items is always short.
  describe "a collection whose items are not listed" do
    defp unlisted(opts) do
      Collections.collection(
        "/members",
        Keyword.merge(
          [
            fetch: fn _page, _page_size -> flunk("the items must not even be fetched") end,
            count: count(5),
            listed?: false
          ],
          opts
        )
      )
    end

    test "serves its id, type and count, and nothing to page through" do
      assert unlisted([]) == %{
               "id" => "/members",
               "type" => "OrderedCollection",
               "totalItems" => 5
             }
    end

    test "serves the same for any page asked for, so the page number reveals nothing" do
      for page <- [1, 2, 9] do
        served = unlisted(page: page)

        assert served["totalItems"] == 5
        refute Map.has_key?(served, "next"), "page #{page} links on"
        refute Map.has_key?(served, "orderedItems"), "page #{page} lists items"
      end
    end

    test "keeps what the caller adds to the top level" do
      assert unlisted(extra: %{"orderType" => "x"})["orderType"] == "x"
    end

    test "control: listed by default" do
      top = Collections.collection("/members", fetch: fetch(5), count: count(5))

      assert top["first"]["orderedItems"] == [1, 2, 3, 4, 5]
    end
  end
end
