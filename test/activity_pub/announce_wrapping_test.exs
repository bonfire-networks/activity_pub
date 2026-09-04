defmodule ActivityPub.AnnounceWrappingTest do
  @moduledoc """
  The two Announce shapes, and how `ActivityPub.announce/2` chooses between them.

  Without `embed_object_in_create_activity`, an Announce carries the announced object's ID: a boost, one actor repeating an existing object to their own followers.

  With `embed_object_in_create_activity: true`, it carries the ACTIVITY that created the object, embedded. That is FEP-1b12's group relay, `Announce{Create{…}}`, which is how the threadiverse says a new post belongs to a group. Lemmy, PieFed and NodeBB all emit it, and Lemmy rejects an announced bare object inbound.

  Passing the activity itself is the preferred way to get that shape: handing in an activity wraps it with no flag and no lookup, since a bare-id Announce of an activity is a shape nobody consumes. `Announce` is the exception, because a boost of a boost stays a boost. The flag is the lesser path, for a caller holding only the object.

  Asking to wrap an object whose activity cannot be found falls back to the boost shape, so a group relays something rather than nothing.

  The wrapper's addressing is pinned against the captured wrappers in `bonfire_federate_activitypub/test/fixtures/{lemmy,piefed,nodebb}`: `to` is Public alone, `cc` is the announcer's followers collection, and there is NO `audience` on the wrapper, because 1b12 marks belonging on the inner activity and the object instead. The `refute` on `audience` is deliberate: adding it would look like a fix and would match nothing anyone else sends.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Object
  alias ActivityPub.Federator.Transformer

  defp group_with_post do
    group = insert(:actor, type: "Group")
    create = insert(:note_activity)
    note = Object.get_cached!(ap_id: create.data["object"])

    %{group: group, create: create, note: note}
  end

  test "embed_object_in_create_activity announces the Create, embedded whole, rather than the object's id" do
    %{group: group, create: create, note: note} = group_with_post()

    assert {:ok, announce} =
             ActivityPub.announce(%{
               actor: group,
               object: note,
               embed_object_in_create_activity: true
             })

    assert %{"type" => "Announce", "object" => %{} = announced} = announce.data

    assert announced["type"] == "Create",
           "1b12 announces the activity: an announced bare object is what Lemmy rejects"

    assert announced["id"] == create.data["id"]
  end

  test "on the wire, the announced Create carries its post inline" do
    %{group: group, note: note} = group_with_post()

    assert {:ok, announce} =
             ActivityPub.announce(%{
               actor: group,
               object: note,
               embed_object_in_create_activity: true
             })

    # the STORED form keeps the inner activity's object as a bare id, because `Object.insert/4`
    # splits an activity from its object rather than duplicating the JSON
    assert is_binary(announce.data["object"]["object"])

    assert {:ok, wire} = ActivityPub.Federator.Transformer.prepare_outgoing(announce.data)

    assert %{"type" => post_type} = wire["object"]["object"],
           "every captured `Announce{Create{Page}}` from Lemmy, PieFed and NodeBB embeds the post, and a receiver that reads the relayed copy rather than re-fetching has nothing otherwise"

    assert post_type in ["Note", "Page", "Article", "Question"]

    refute Map.has_key?(wire["object"], "@context"),
           "the captures put `@context` on the top-level document only"
  end

  test "the wrapper is addressed like the captured ones, and carries no audience" do
    %{group: group, note: note} = group_with_post()

    assert {:ok, announce} =
             ActivityPub.announce(%{
               actor: group,
               object: note,
               embed_object_in_create_activity: true
             })

    assert announce.data["actor"] == group.data["id"]
    assert announce.data["to"] == [ActivityPub.Config.public_uri()]
    assert announce.data["cc"] == [group.data["followers"]]

    refute Map.has_key?(announce.data, "audience"),
           "no captured wrapper has one; belonging is marked on the inner activity and object"
  end

  test "without embed_object_in_create_activity the boost shape is unchanged" do
    %{group: group, note: note} = group_with_post()

    assert {:ok, announce} = ActivityPub.announce(%{actor: group, object: note})

    assert announce.data["object"] == note.data["id"],
           "a boost announces the object's id"
  end

  test "announcing an activity wraps it without being asked to" do
    %{group: group, create: create} = group_with_post()

    assert {:ok, announce} = ActivityPub.announce(%{actor: group, object: create})

    assert %{"id" => announced_id} = announce.data["object"],
           "an activity can only be announced embedded: a bare-id Announce is resolved by receivers that then type-check it against post types and drop it"

    assert announced_id == create.data["id"]
  end

  test "announcing an Announce stays a boost, since a boost of a boost is a boost" do
    %{group: group, note: note} = group_with_post()
    someone_else = insert(:actor)

    assert {:ok, boost} = ActivityPub.announce(%{actor: group, object: note})

    assert {:ok, reboost} = ActivityPub.announce(%{actor: someone_else, object: boost})

    assert reboost.data["object"] == boost.data["id"],
           "nesting announces is not a shape anyone consumes"
  end

  describe "a group relay goes out as both shapes" do
    # Lemmy accepts only `Announce{Activity}` (its `Page` variant is send-only and errors on receipt) while Akkoma, Misskey, Sharkey, Iceshrimp and GoToSocial drop `Announce{Create}` and take only the object form, so neither shape alone reaches everyone. Lemmy and NodeBB both send both.
    defp announced(actor, object) do
      assert {:ok, announce} = ActivityPub.announce(%{actor: actor, object: object})
      assert {:ok, prepared} = Transformer.prepare_outgoing(announce.data)
      prepared
    end

    test "the second shape wraps the Create and carries its own id" do
      %{group: group, create: create, note: note} = group_with_post()

      compat = announced(group, note)
      wrapped = Transformer.wrapped_relay_data(group, compat)

      assert wrapped["object"]["type"] == "Create"
      assert wrapped["object"]["id"] == create.data["id"]

      assert wrapped["id"] == ActivityPub.Object.activity_object_url(compat["id"]),
             "derived from the canonical id, so the pair stays recognisably one activity"

      refute wrapped["id"] == compat["id"],
             "two documents claiming one id would make the pair incoherent to anyone who fetches it"

      assert wrapped["actor"] == compat["actor"]
    end

    test "a person's boost has no second shape" do
      %{note: note} = group_with_post()
      someone = insert(:actor)

      refute Transformer.wrapped_relay_data(someone, announced(someone, note)),
             "a boost is one actor repeating an object, not a group relaying an activity"
    end

    # The fan-out itself, where one activity becomes one payload per inbox, lives in
    # `bonfire_federate_activitypub/test/activity_pub_integration/group_outgoing_test.exs`:
    # `prepare_publish_params/2` resolves recipients through the adapter, which needs actors backed
    # by local pointers rather than the bare `%Object{}` actors this factory builds.

    test "an announce with no Create behind it has no second shape" do
      group = insert(:actor, type: "Group")
      orphan = insert(:note)

      refute Transformer.wrapped_relay_data(group, announced(group, orphan)),
             "nothing to wrap means the compat copy travels alone rather than a broken pair going out"
    end
  end

  test "falls back to the boost shape when there is no activity to wrap" do
    group = insert(:actor, type: "Group")
    orphan = insert(:note)

    assert {:ok, announce} =
             ActivityPub.announce(%{
               actor: group,
               object: orphan,
               embed_object_in_create_activity: true
             })

    assert announce.data["type"] == "Announce"

    assert announce.data["object"] == orphan.data["id"],
           "relaying the object still reaches every receiver but Lemmy, where relaying nothing reaches nobody"
  end
end
