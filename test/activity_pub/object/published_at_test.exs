defmodule ActivityPub.Object.PublishedAtTest do
  @moduledoc """
  A row's `inserted_at` is when what it holds happened: the document's `published`, so lists can be ordered by a column rather than by a field inside `data`. One delivered to us only within a configurable range (`config :activity_pub, :published_within`, `to_timeout(day: 4)` by default), so a sender cannot float a post to the top or bury it among old ones with a date it chose; otherwise, and when it has none, the current date. One we fetched from its origin however old, as the origin is the authority on it (an old thread, a profile's history), but not a future one. Our own as given, a future one included, so a scheduled post stays out of lists until its time.
  """
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Object
  alias ActivityPub.Utils

  # `to_timeout/1` durations, negative for the past
  defp iso(from_now),
    do: DateTime.utc_now() |> DateTime.add(from_now, :millisecond) |> DateTime.to_iso8601()

  defp days(n), do: to_timeout(day: n)

  defp near_now?(%{} = datetime),
    do: abs(DateTime.diff(DateTime.from_naive!(datetime, "Etc/UTC"), DateTime.utc_now())) < 60

  # the column keeps whole seconds
  defp same_second?(naive, iso),
    do:
      DateTime.from_naive!(naive, "Etc/UTC") |> DateTime.truncate(:second) ==
        elem(DateTime.from_iso8601(iso), 1) |> DateTime.truncate(:second)

  describe "published_at/2" do
    test "a delivered date within the range is used" do
      published = iso(-days(2))
      assert %DateTime{} = date = Utils.published_at(published, :delivered)
      assert DateTime.to_iso8601(date) |> String.slice(0, 19) == String.slice(published, 0, 19)
    end

    test "a delivered date older than the range, or in the future, or missing, gives nothing (the current date is used)" do
      assert Utils.published_at(iso(-days(10)), :delivered) == nil
      assert Utils.published_at(iso(days(1)), :delivered) == nil
      assert Utils.published_at(nil, :delivered) == nil
      assert Utils.published_at("not a date", :delivered) == nil
    end

    test "a fetched date is used however old, as its origin says it, but not a future one" do
      assert %DateTime{} = Utils.published_at(iso(-days(4000)), :fetched)
      assert Utils.published_at(iso(days(1)), :fetched) == nil
    end

    test "our own is used as given, a future one included" do
      assert %DateTime{} = Utils.published_at(iso(days(3)), :ours)
      assert %DateTime{} = Utils.published_at(iso(-days(30)), :ours)
    end
  end

  describe "a row stored" do
    defp create(n, published) do
      actor = "https://remote-#{n}.local/users/alice"

      %{
        "id" => "#{actor}/activities/#{n}",
        "type" => "Create",
        "actor" => actor,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "published" => published,
        "object" => %{
          "id" => "#{actor}/notes/#{n}",
          "type" => "Note",
          "attributedTo" => actor,
          "content" => "<p>hi</p>",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "published" => published
        }
      }
    end

    test "takes a delivered published date within the range, for the activity and its object" do
      n = System.unique_integer([:positive])
      published = iso(-days(2))
      assert {:ok, activity} = Object.insert(create(n, published), false, nil, from_inbox: true)

      assert same_second?(activity.inserted_at, published),
             "the activity's inserted_at is #{inspect(activity.inserted_at)}, its published #{published}"

      assert same_second?(activity.object.inserted_at, published),
             "the object's inserted_at is #{inspect(activity.object.inserted_at)}, its published #{published}"
    end

    test "takes the current date for a delivered published date out of the range" do
      n = System.unique_integer([:positive])

      assert {:ok, activity} =
               Object.insert(create(n, iso(-days(10))), false, nil, from_inbox: true)

      assert near_now?(activity.inserted_at)
      assert near_now?(activity.object.inserted_at)
    end

    test "takes the published date of what we fetched from its origin, however old" do
      n = System.unique_integer([:positive])
      published = iso(-days(4000))

      assert {:ok, activity} =
               Object.insert(create(n, published), false, nil, already_fetched: true)

      assert same_second?(activity.inserted_at, published)
      assert same_second?(activity.object.inserted_at, published)
    end

    # a boost names a post, usually an older one: the post is stored from its origin (a fetch), not from a copy the booster carries, so it keeps the date its origin gives however old, and a date the copy claims is not taken
    test "takes the date its origin gives for a boosted post, however old, not one the boost's copy claims" do
      n = System.unique_integer([:positive])
      author = "https://boosted-#{n}.local/users/alice"
      booster = "https://booster-#{n}.local/users/bob"
      ActivityPub.Factory.actor(ap_id: author)
      ActivityPub.Factory.actor(ap_id: booster)

      published = iso(-days(4000))

      post = %{
        "id" => "#{author}/notes/#{n}",
        "type" => "Note",
        "attributedTo" => author,
        "content" => "<p>an old post</p>",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "published" => published
      }

      post_id = post["id"]

      Tesla.Mock.mock(fn
        %{method: :get, url: ^post_id} -> Tesla.Mock.json(post)
        %{method: :get} -> %Tesla.Env{status: 404, body: ""}
      end)

      boost = %{
        "id" => "#{booster}/announces/#{n}",
        "type" => "Announce",
        "actor" => booster,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        # the copy it carries claims today
        "object" => Map.put(post, "published", iso(0))
      }

      assert {:ok, _} =
               ActivityPub.Federator.Transformer.handle_incoming(boost,
                 from_inbox: true,
                 authenticated: :http_signature,
                 signed_by: booster
               )

      assert {:ok, %Object{inserted_at: inserted_at}} = Object.get_uncached(ap_id: post_id)

      assert same_second?(inserted_at, published),
             "the boosted post's inserted_at is #{inspect(inserted_at)}, its origin's published #{published}"
    end

    # its opposite: a copy its author signed is as good as the post from its origin, date included, so it is stored from the copy and keeps the date the copy gives, however old, with nothing fetched
    test "takes the date of a boosted post's copy signed by its author, however old, with nothing fetched" do
      import ActivityPub.Test.IntegrityProofHelpers

      n = System.unique_integer([:positive])
      key = new_key(:ed25519)
      author = "https://boosted-#{n}.local/users/alice"
      booster = "https://booster-#{n}.local/users/bob"

      ActivityPub.Factory.actor(
        ap_id: author,
        data: %{"assertionMethod" => [multikey(author, key)]}
      )

      ActivityPub.Factory.actor(ap_id: booster)

      # the post's origin serves nothing
      Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

      published = iso(-days(4000))

      post =
        %{
          "@context" => [
            "https://www.w3.org/ns/activitystreams",
            "https://w3id.org/security/data-integrity/v2"
          ],
          "id" => "#{author}/notes/#{n}",
          "type" => "Note",
          "attributedTo" => author,
          "content" => "<p>an old post</p>",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "published" => published
        }
        |> sign(key)

      boost = %{
        "id" => "#{booster}/announces/#{n}",
        "type" => "Announce",
        "actor" => booster,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => post
      }

      assert {:ok, _} =
               ActivityPub.Federator.Transformer.handle_incoming(boost,
                 from_inbox: true,
                 authenticated: :http_signature,
                 signed_by: booster
               )

      assert {:ok, %Object{inserted_at: inserted_at}} = Object.get_uncached(ap_id: post["id"])

      assert same_second?(inserted_at, published),
             "the boosted post's inserted_at is #{inspect(inserted_at)}, its signed copy's published #{published}"
    end

    # a sender cannot float or bury what it delivers with a date it chose, but a date its author signed is the author's word, as good as its origin's
    test "takes the published date of a delivered Create its author signed, however old" do
      import ActivityPub.Test.IntegrityProofHelpers

      key = new_key(:ed25519)
      author = "https://signer-#{System.unique_integer([:positive])}.local/users/alice"

      ActivityPub.Factory.actor(
        ap_id: author,
        data: %{"assertionMethod" => [multikey(author, key)]}
      )

      published = iso(-days(4000))

      %{"object" => note} = create = create_note(author)

      signed =
        create
        |> Map.put("published", published)
        |> Map.put("object", Map.put(note, "published", published))
        |> sign(key)

      assert {:ok, _} =
               ActivityPub.Federator.Worker.ReceiverHelpers.perform(
                 %Oban.Job{
                   args: %{
                     "op" => "incoming_ap_doc",
                     "params" => signed,
                     "signed_by" => author,
                     "repo" => ActivityPub.Utils.repo()
                   }
                 },
                 :verified
               )

      assert {:ok, %Object{inserted_at: activity_at}} = Object.get_uncached(ap_id: signed["id"])
      assert {:ok, %Object{inserted_at: object_at}} = Object.get_uncached(ap_id: note["id"])
      assert same_second?(activity_at, published)
      assert same_second?(object_at, published)
    end

    test "an activity received today is not pruned for its old date: the pruner counts from when it was stored" do
      previous = Application.get_env(:activity_pub, :published_within)
      Application.put_env(:activity_pub, :published_within, to_timeout(day: 30))

      on_exit(fn ->
        if previous,
          do: Application.put_env(:activity_pub, :published_within, previous),
          else: Application.delete_env(:activity_pub, :published_within)
      end)

      n = System.unique_integer([:positive])
      actor = "https://remote-#{n}.local/users/alice"

      delete = %{
        "id" => "#{actor}/activities/delete-#{n}",
        "type" => "Delete",
        "actor" => actor,
        "object" => "#{actor}/notes/#{n}",
        "published" => iso(-days(20))
      }

      assert {:ok, stored} = Object.insert(delete, false, nil, from_inbox: true)
      assert same_second?(stored.inserted_at, delete["published"])

      ActivityPub.Pruner.prune_deletes(nil)

      assert {:ok, _} = Object.get_uncached(ap_id: delete["id"])
    end

    test "the inbox lists by when things happened, and a remote future date does not hide an activity, as it takes the receive time" do
      n = System.unique_integer([:positive])
      me = "https://local-#{n}.local/users/me"
      actor = "https://remote-#{n}.local/users/alice"

      activity = fn id, published ->
        %{
          "id" => "#{actor}/activities/#{id}",
          "type" => "Like",
          "actor" => actor,
          "to" => [me],
          "object" => "#{actor}/notes/#{n}",
          "published" => published
        }
      end

      delivered = [from_inbox: true]
      {:ok, older} = Object.insert(activity.("older-#{n}", iso(-days(2))), false, nil, delivered)
      {:ok, newer} = Object.insert(activity.("newer-#{n}", iso(-days(1))), false, nil, delivered)
      {:ok, future} = Object.insert(activity.("future-#{n}", iso(days(1))), false, nil, delivered)

      ids = Object.get_inbox_for_actor(me, 1) |> Enum.map(& &1.data["id"])

      assert future.data["id"] in ids

      assert Enum.filter(ids, &(&1 in [older.data["id"], newer.data["id"]])) ==
               [newer.data["id"], older.data["id"]]
    end

    test "keeps the receive time in updated_at" do
      n = System.unique_integer([:positive])

      assert {:ok, activity} =
               Object.insert(create(n, iso(-days(2))), false, nil, from_inbox: true)

      assert near_now?(activity.updated_at)
    end
  end
end
