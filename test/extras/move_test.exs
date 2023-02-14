defmodule ActivityPub.MoveTest do
  use ActivityPub.DataCase
  use Oban.Testing, repo: repo()
  import ActivityPub.Factory
  alias ActivityPub.Object
  import Tesla.Mock

  describe "Move activity" do
    test "create" do
      old_user = local_actor()
      old_ap_id = ap_id(old_user)
      new_user = local_actor(also_known_as: [old_ap_id])
      new_ap_id = ap_id(new_user)
      follower = local_actor()
      follower_move_opted_out = local_actor(allow_following_move: false)

      follow(follower, old_user)
      follow(follower_move_opted_out, old_user)

      assert following?(follower, old_user)
      assert following?(follower_move_opted_out, old_user)

      assert {:ok, activity} = ActivityPub.move(old_user, new_user)

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

      assert old_user.follower_address in recipients

      params = %{
        "op" => "move_following",
        "origin_id" => old_user.id,
        "target_id" => new_user.id
      }

      assert_enqueued(worker: Workers.BackgroundWorker, args: params)

      Workers.BackgroundWorker.perform(%Oban.Job{args: params})

      refute following?(follower, old_user)
      assert following?(follower, new_user)

      assert following?(follower_move_opted_out, old_user)
      refute following?(follower_move_opted_out, new_user)

      # TODO
      # assert [%Notification{activity: ^activity}] = Notification.for_user(follower)
      # assert [%Notification{activity: ^activity}] = Notification.for_user(follower_move_opted_out)
    end

    test "old user must be in the new user's `also_known_as` list" do
      old_user = local_actor()
      new_user = local_actor()

      assert {:error, "Target account must have the origin in `alsoKnownAs`"} =
               ActivityPub.move(old_user, new_user)
    end

    test "do not move remote user following relationships" do
      old_user = local_actor()
      old_ap_id = ap_id(old_user)
      new_user = local_actor(also_known_as: [old_ap_id])
      new_ap_id = ap_id(new_user)
      follower_remote = local_actor(local: false)

      follow(follower_remote, old_user)

      assert following?(follower_remote, old_user)

      assert {:ok, activity} = ActivityPub.move(old_user, new_user)

      assert %Object{
               #  actor: ^old_ap_id,
               data: %{
                 "actor" => ^old_ap_id,
                 "object" => ^old_ap_id,
                 "target" => ^new_ap_id,
                 "type" => "Move"
               },
               local: true
             } = activity

      params = %{
        "op" => "move_following",
        "origin_id" => old_user.id,
        "target_id" => new_user.id
      }

      assert_enqueued(worker: Workers.BackgroundWorker, args: params)

      Workers.BackgroundWorker.perform(%Oban.Job{args: params})

      assert following?(follower_remote, old_user)
      refute following?(follower_remote, new_user)
    end
  end
end
