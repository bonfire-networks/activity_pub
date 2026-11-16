defmodule ActivityPub.Safety.ContainmentTypeListTest do
  @moduledoc """
  An object's id has to be on the origin of its owner. A `type` that is a list is not a way round that: one type of the list that is exempt from the check (a collection, an actor) does not exempt an object that is also a `Note`, so the id of a `["Note", "Collection"]` still has to be on the host of its owner.
  """
  use ActivityPub.DataCase

  alias ActivityPub.Safety.Containment

  @id "https://a.local/n/1"

  test "control: a Note whose owner is on the same host is contained" do
    assert Containment.contain_origin(@id, %{"type" => ["Note"], "actor" => "https://a.local/u"})
    assert Containment.contain_origin(@id, %{"type" => "Note", "actor" => "https://a.local/u"})
  end

  test "control: a Note whose owner is on another host is not contained" do
    refute Containment.contain_origin(@id, %{"type" => ["Note"], "actor" => "https://v.local/u"})
    refute Containment.contain_origin(@id, %{"type" => "Note", "actor" => "https://v.local/u"})
  end

  test "a Note that also says it is a Collection, owned by someone on another host, is not contained" do
    refute Containment.contain_origin(@id, %{
             "type" => ["Note", "Collection"],
             "actor" => "https://v.local/u"
           })

    refute Containment.contain_origin(@id, %{
             "type" => ["Collection", "Note"],
             "attributedTo" => "https://v.local/u"
           })
  end

  test "a Note that also says it is an actor type, owned by someone on another host, is not contained" do
    refute Containment.contain_origin(@id, %{
             "type" => ["Note", "Person"],
             "actor" => "https://v.local/u"
           })
  end
end
