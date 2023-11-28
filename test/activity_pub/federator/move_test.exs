defmodule ActivityPub.MoveTest do
  use ActivityPub.DataCase, async: false
  use Oban.Testing, repo: repo()
  import ActivityPub.Factory
  alias ActivityPub.Object
  alias ActivityPub.Actor
  alias ActivityPub.Federator.Transformer
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  @mismatch {:error, :not_in_also_known_as}

  test "user update works with alsoKnownAs" do
    user = actor(local: false)
    actor = ap_id(user)

    assert user.data |> Map.get("alsoKnownAs", []) == []

    {:ok, updated} =
      "fixtures/mastodon/mastodon-update.json"
      |> file()
      |> Jason.decode!()
      |> Map.put("actor", actor)
      |> Map.update!("object", fn object ->
        object
        |> Map.put("actor", actor)
        |> Map.put("id", actor)
        |> Map.put("alsoKnownAs", [
          "https://mastodon.local/users/foo",
          "http://exampleorg.local/users/bar"
        ])
      end)
      |> Transformer.handle_incoming()
      |> debug("uppdated")

    # TODO
    assert Actor.get_cached!(ap_id: actor).data |> Map.get("alsoKnownAs", []) == [
             "https://mastodon.local/users/foo",
             "http://exampleorg.local/users/bar"
           ]
  end

  test "does not accept incoming Move activities for two remote actors" do
    old_user = actor(local: false)
    new_user = actor(local: false)

    message = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type" => "Move",
      "actor" => old_user.ap_id,
      "object" => old_user.ap_id,
      "target" => new_user.ap_id
    }

    {:ok, _new_user} =
      add_alias(new_user, old_user.ap_id)

    assert @mismatch = Transformer.handle_incoming(message)
  end

  test "accepts incoming Move activities for an (old) remote actor to a (new) local actor" do
    old_user = actor(local: false)
    new_user = local_actor().actor

    message = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type" => "Move",
      "actor" => old_user.ap_id,
      "object" => old_user.ap_id,
      "target" => new_user.ap_id
    }

    assert @mismatch = Transformer.handle_incoming(message)

    {:ok, _new_user} = add_alias(new_user, old_user.ap_id)

    assert {:ok, %Object{} = activity} = Transformer.handle_incoming(message)
    assert activity.data["actor"] == old_user.ap_id
    assert activity.data["object"] == old_user.ap_id
    assert activity.data["target"] == new_user.ap_id
    assert activity.data["type"] == "Move"
  end

  test "accepts incoming Move activities for an (old) local actor to a (new) remote actor" do
    old_user = local_actor().actor
    old_ap_id = ap_id(old_user)
    new_user = actor(local: false, also_known_as: [old_ap_id])

    message = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type" => "Move",
      "actor" => old_user.ap_id,
      "object" => old_user.ap_id,
      "target" => new_user.ap_id
    }

    # FIXME?
    # assert @mismatch = Transformer.handle_incoming(message)

    {:ok, _new_user} = add_alias(new_user, old_user.ap_id)

    assert {:ok, %Object{} = activity} = Transformer.handle_incoming(message)
    assert activity.data["actor"] == old_user.ap_id
    assert activity.data["object"] == old_user.ap_id
    assert activity.data["target"] == new_user.ap_id
    assert activity.data["type"] == "Move"
  end

  test "accepts fully local Move activities" do
    old_user = local_actor().actor
    new_user = local_actor().actor

    message = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type" => "Move",
      "actor" => old_user.ap_id,
      "object" => old_user.ap_id,
      "target" => new_user.ap_id
    }

    assert @mismatch = Transformer.handle_incoming(message)

    {:ok, _new_user} = add_alias(new_user, old_user.ap_id)

    assert {:ok, %Object{} = activity} = Transformer.handle_incoming(message)
    assert activity.data["actor"] == old_user.ap_id
    assert activity.data["object"] == old_user.ap_id
    assert activity.data["target"] == new_user.ap_id
    assert activity.data["type"] == "Move"
  end

  describe "Move activity" do
    test "works (between two local actors)" do
      old_user = local_actor(name: "Old")
      old_ap_id = ap_id(old_user)
      new_user = local_actor(name: "New", also_known_as: [old_ap_id])
      new_ap_id = ap_id(new_user)
      follower = local_actor()

      # TODO?
      # follower_move_opted_out = local_actor(allow_following_move: false)

      follow(follower, old_user)
      # follow(follower_move_opted_out, old_user)

      assert following?(follower, old_user)
      # assert following?(follower_move_opted_out, old_user)

      assert {:ok, activity} = ActivityPub.move(old_user.actor, new_user.actor)

      assert %Object{
               #  actor: ^old_ap_id,
               data: %{
                 "actor" => ^old_ap_id,
                 "object" => ^old_ap_id,
                 "target" => ^new_ap_id,
                 "to" => recipients,
                 "type" => "Move"
               },
               local: true
               #  recipients: recipients
             } = activity

      assert old_user.data["followers"] in recipients

      # TODO
      # params = %{
      #   "op" => "move_following",
      #   "origin_id" => old_user.id,
      #   "target_id" => new_user.id
      # }
      # assert_enqueued(worker: Workers.BackgroundWorker, args: params)
      # Workers.BackgroundWorker.perform(%Oban.Job{args: params})

      # follow was moved?
      refute following?(follower, old_user)
      assert following?(follower, new_user)

      # follow was NOT moved?
      # assert following?(follower_move_opted_out, old_user)
      # refute following?(follower_move_opted_out, new_user)

      # TODO
      # assert [%Notification{activity: ^activity}] = Notification.for_user(follower)
      # assert [%Notification{activity: ^activity}] = Notification.for_user(follower_move_opted_out)
    end

    test "old user must be in the new user's `also_known_as` list" do
      old_user = local_actor().actor
      new_user = local_actor().actor

      assert @mismatch =
               ActivityPub.move(old_user, new_user)
    end

    test "do not move remote user following relationships" do
      old_user = local_actor()
      old_ap_id = ap_id(old_user)
      new_user = local_actor(also_known_as: [old_ap_id])
      new_ap_id = ap_id(new_user)
      follower_remote = actor(local: false)

      follow(follower_remote, old_user)

      assert following?(follower_remote, old_user)
      refute following?(follower_remote, new_user)

      assert {:error, :move_failed} = ActivityPub.move(old_user.actor, new_user.actor)

      # assert following?(follower_remote, old_user)
      # refute following?(follower_remote, new_user)
    end

    test "do not move remote user following relationships, but still move local ones" do
      old_user = local_actor()
      old_ap_id = ap_id(old_user)
      new_user = local_actor(also_known_as: [old_ap_id])
      new_ap_id = ap_id(new_user)
      follower_remote = actor(local: false)
      follower_local = local_actor()

      follow(follower_remote, old_user)
      follow(follower_local, old_user)

      assert following?(follower_remote, old_user)
      refute following?(follower_remote, new_user)

      assert following?(follower_local, old_user)
      refute following?(follower_local, new_user)

      assert {:ok, _activity} = ActivityPub.move(old_user.actor, new_user.actor)

      # FIXME?
      # assert following?(follower_remote, old_user)      
      # refute following?(follower_remote, new_user)

      refute following?(follower_local, old_user)
      assert following?(follower_local, new_user)
    end
  end
end
