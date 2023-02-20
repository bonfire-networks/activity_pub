defmodule ActivityPub.Factory do
  import ActivityPub.Test.Helpers
  import ActivityPub.Utils
  import Untangle
  @repo repo()
  use ExMachina.Ecto, repo: @repo

  def actor(attrs \\ %{}) do
    actor = insert(:actor, attrs)
    actor_cached(actor)
  end

  def actor_cached(actor) do
    {:ok, actor} = ActivityPub.Actor.get_cached(ap_id: actor.data["id"])
    actor
  end

  def local_actor(attrs \\ %{}) do
    # TODO: make into a generic adapter callback?
    if ActivityPub.Federator.Adapter.adapter() == Bonfire.Federate.ActivityPub.Adapter and
         Code.ensure_loaded?(Bonfire.Me.Fake) do
      attrs = attrs |> Enum.into(%{})

      user =
        Bonfire.Me.Fake.fake_user!(attrs, attrs,
          request_before_follow: attrs[:request_before_follow] || false
        )

      # |> debug()
      {:ok, actor} = ActivityPub.Actor.get_cached(username: user.character.username)

      %{
        local: true,
        actor: actor,
        data: actor.data,
        user: user,
        keys: nil,
        username: user.character.username
      }
    else
      actor = build(:local_actor, attrs)

      {:ok, actor} =
        ActivityPub.LocalActor.insert(%{
          local: true,
          data: actor.data,
          keys: nil,
          username: actor.data["preferredUsername"]
        })

      actor
    end
  end

  def actor_factory(attrs \\ %{}) do
    username = sequence(:username, &"actor_#{&1}_#{Pointers.ULID.generate()}")
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    id =
      attrs[:data]["id"] ||
        "https://example.local" <> ap_base_path <> "/actors/#{username}"

    actor_object(id, username, attrs, false)
  end

  def local_actor_factory(attrs \\ %{}) do
    username = sequence(:username, &"username#{&1}")
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    id =
      attrs[:data]["id"] ||
        ActivityPub.Web.base_url() <> ap_base_path <> "/actors/#{username}"

    actor_object(id, username, attrs, true)
  end

  defp actor_object(id, username, attrs, local?) do
    data = %{
      "name" => sequence(:name, &"Test actor #{&1}"),
      "preferredUsername" => username,
      "summary" => sequence(:bio, &"Tester Number#{&1}"),
      "type" => "Person"
    }

    data =
      Map.merge(data, %{
        "id" => id,
        "inbox" => "#{id}/inbox",
        "outbox" => "#{id}/outbox",
        "followers" => "#{id}/followers",
        "following" => "#{id}/following"
      })

    %ActivityPub.Object{
      data: merge_attributes(data, Map.get(attrs, :data, %{})),
      local: attrs[:local] || local?,
      public: true
    }
  end

  def community() do
    actor = insert(:actor)
    {:ok, actor} = ActivityPub.Actor.get_cached(ap_id: actor.data["id"])

    community =
      insert(:actor, %{
        data: %{
          "type" => "Group",
          "attributedTo" => actor.ap_id,
          "collections" => []
        }
      })

    {:ok, community} = ActivityPub.Actor.get_cached(ap_id: community.data["id"])
    community
  end

  def collection() do
    actor = insert(:actor)
    {:ok, actor} = ActivityPub.Actor.get_cached(ap_id: actor.data["id"])

    community =
      insert(:actor, %{
        data: %{
          "type" => "Group",
          "attributedTo" => actor.ap_id,
          "collections" => []
        }
      })

    {:ok, community} = ActivityPub.Actor.get_cached(ap_id: community.data["id"])

    collection =
      insert(:actor, %{
        data: %{
          "type" => "MN:Collection",
          "attributedTo" => actor.ap_id,
          "context" => community.ap_id,
          "resources" => []
        }
      })

    {:ok, collection} = ActivityPub.Actor.get_cached(ap_id: collection.data["id"])
    collection
  end

  def local_note(attrs \\ %{}) do
    actor = attrs[:actor] || local_actor()
    note = build(:note, attrs |> Enum.into(%{actor: actor}))

    if ActivityPub.Federator.Adapter.adapter() == Bonfire.Federate.ActivityPub.Adapter and
         Code.ensure_loaded?(Bonfire.Social.Fake) do
      %{id: id} =
        post =
        Bonfire.Social.Fake.fake_post!(
          user_by_ap_id(actor),
          attrs[:boundary] || "public",
          attrs |> Enum.into(%{html_body: note.data["content"]}),
          to_circles: attrs[:to_circles] || []
        )

      {:ok, object} = ActivityPub.Object.get_cached(pointer: id)

      %ActivityPub.Object{
        data: object.data,
        local: true,
        public: ActivityPub.Utils.public?(object),
        pointer: post,
        is_object: true
      }
    else
      # TODO?
      insert(note)
    end
  end

  def local_note_activity(attrs \\ %{}) do
    actor = attrs[:actor] || local_actor()
    note = attrs[:note] || local_note(attrs)
    activity = build(:note_activity, attrs |> Enum.into(%{actor: actor, note: note}))

    if ActivityPub.Federator.Adapter.adapter() == Bonfire.Federate.ActivityPub.Adapter and
         Code.ensure_loaded?(Bonfire.Social.Fake) do
      # {:ok, ap_activity} = ActivityPub.Object.get_cached(pointer: id)

      activity
    else
      # TODO?
      insert(activity)
    end
  end

  def note_factory(attrs \\ %{}) do
    attrs = attrs |> Enum.into(%{})
    text = attrs[:status] || sequence(:text, &"This is note #{&1}")
    actor = attrs[:actor] || insert(:actor)

    data = %{
      "type" => "Note",
      "content" => text,
      "id" => ActivityPub.Utils.generate_object_id(),
      "actor" => actor.data["id"],
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
      # "likes" => [],
      # "like_count" => 0,
      "context" => "context",
      "summary" => "summary",
      "tag" => ["tag"]
    }

    %ActivityPub.Object{
      data:
        merge_attributes(data, Map.get(attrs, :data, Map.drop(attrs, [:actor, :status, :note]))),
      local: actor.local,
      public: ActivityPub.Utils.public?(data),
      is_object: true
    }
  end

  def local_direct_note(attrs \\ %{}) do
    to = attrs[:to] || local_actor()

    local_note(
      attrs
      |> Enum.into(%{
        boundary: "mentions",
        to_circles: user_by_ap_id(to).id,
        actor: attrs[:actor] || local_actor()
      })
    )
  end

  def direct_note_factory(attrs \\ %{}) do
    to = attrs[:to] || insert(:actor)

    %ActivityPub.Object{data: data} = note_factory(attrs |> Enum.into(%{boundary: "mentions"}))
    %ActivityPub.Object{public: false, data: Map.merge(data, %{"to" => [ap_id(to)]})}
  end

  def direct_note_activity_factory(attrs \\ %{}) do
    note_activity_factory(attrs |> Enum.into(%{note: attrs[:note] || insert(:direct_note)}))
  end

  def note_activity_factory(attrs \\ %{}) do
    note =
      attrs[:note] ||
        insert(
          :note,
          attrs |> Map.drop(["inReplyTo"]) |> Enum.into(%{actor: attrs[:actor] || insert(:actor)})
        )

    actor = note.data["actor"]

    attrs = attrs |> Enum.into(%{}) |> Map.drop([:actor, :note, :data_attrs])
    data_attrs = attrs[:data_attrs] || attrs |> Map.drop([:status])

    data =
      %{
        "id" => ActivityPub.Utils.generate_object_id(),
        "type" => "Create",
        "actor" => actor,
        "to" => note.data["to"],
        "object" => note.data["id"],
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "context" => note.data["context"]
      }
      |> Map.merge(data_attrs)

    struct(
      %ActivityPub.Object{
        data: data,
        local: note.local,
        public: note.public
        # object: note
      },
      attrs
    )
  end

  def announce_activity_factory(attrs \\ %{}) do
    note_activity = attrs[:note_activity] || insert(:note)
    actor = attrs[:actor] || insert(:actor)

    data = %{
      "type" => "Announce",
      "actor" => actor.data["id"],
      "object" => note_activity.data["id"],
      "to" => [actor.data["followers"], note_activity.data["actor"]],
      "cc" => ["https://www.w3.org/ns/activitystreams#Public"],
      "context" => note_activity.data["context"]
    }

    %ActivityPub.Object{
      data: data,
      public: ActivityPub.Utils.public?(data)
    }
  end

  def follow_activity_factory(attrs \\ %{}) do
    follower = attrs[:follower] || local_actor()
    followed = attrs[:followed] || local_actor()

    data = %{
      "id" => ActivityPub.Utils.generate_object_id(),
      "actor" => ap_id(follower),
      "type" => "Follow",
      "object" => ap_id(followed),
      "state" => attrs[:state] || "pending",
      "published_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    %ActivityPub.Object{
      data: data
    }
    |> Map.merge(attrs)
  end

  def like_activity_factory do
    note_activity = insert(:note_activity)
    object = ActivityPub.Object.normalize(note_activity)
    actor = insert(:actor)

    data = %{
      "id" => ActivityPub.Utils.generate_object_id(),
      "actor" => actor.data["id"],
      "type" => "Like",
      "object" => object.data["id"],
      "published_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    %ActivityPub.Object{
      data: data,
      public: ActivityPub.Utils.public?(data)
    }
  end

  def instance_factory do
    %ActivityPub.Instances.Instance{
      host: "domain.local",
      unreachable_since: nil
    }
  end

  def tombstone_factory do
    data = %{
      "type" => "Tombstone",
      "id" => ActivityPub.Utils.generate_object_id(),
      "formerType" => "Note",
      "deleted" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    %ActivityPub.Object{
      data: data
    }
  end
end
