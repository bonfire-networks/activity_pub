defmodule ActivityPub.Factory do
  import ActivityPub.Test.Helpers
  @repo repo()
  use ExMachina.Ecto, repo: @repo

  def actor(attrs \\ %{}) do
    actor = insert(:actor, attrs)
    {:ok, actor} = ActivityPub.Actor.get_by_ap_id(actor.data["id"])
    actor
  end

  def local_actor(attrs \\ %{}) do
    # TODO: make into a generic adapter callback?
    if ActivityPub.Adapter.adapter() == Bonfire.Federate.ActivityPub.Adapter and
         Code.ensure_loaded?(Bonfire.Me.Fake) do
      user = Bonfire.Me.Fake.fake_user!(attrs)
      # |> debug()
      {:ok, actor} = ActivityPub.Actor.get_by_username(user.character.username)

      %{
        local: true,
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

  def community() do
    actor = insert(:actor)
    {:ok, actor} = ActivityPub.Actor.get_by_ap_id(actor.data["id"])

    community =
      insert(:actor, %{
        data: %{
          "type" => "Group",
          "attributedTo" => actor.ap_id,
          "collections" => []
        }
      })

    {:ok, community} = ActivityPub.Actor.get_by_ap_id(community.data["id"])
    community
  end

  def collection() do
    actor = insert(:actor)
    {:ok, actor} = ActivityPub.Actor.get_by_ap_id(actor.data["id"])

    community =
      insert(:actor, %{
        data: %{
          "type" => "Group",
          "attributedTo" => actor.ap_id,
          "collections" => []
        }
      })

    {:ok, community} = ActivityPub.Actor.get_by_ap_id(community.data["id"])

    collection =
      insert(:actor, %{
        data: %{
          "type" => "MN:Collection",
          "attributedTo" => actor.ap_id,
          "context" => community.ap_id,
          "resources" => []
        }
      })

    {:ok, collection} = ActivityPub.Actor.get_by_ap_id(collection.data["id"])
    collection
  end

  def actor_factory(attrs \\ %{}) do
    username = sequence(:username, &"username#{&1}")
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    id =
      attrs[:data]["id"] ||
        "https://example.tld" <> ap_base_path <> "/actors/#{username}"

    actor_object(id, username, attrs, false)
  end

  def local_actor_factory(attrs \\ %{}) do
    username = sequence(:username, &"username#{&1}")
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    id =
      attrs[:data]["id"] ||
        ActivityPubWeb.base_url() <> ap_base_path <> "/actors/#{username}"

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

  def note_factory(attrs \\ %{}) do
    text = sequence(:text, &"This is note #{&1}")

    actor = attrs[:actor] || insert(:actor)

    data = %{
      "type" => "Note",
      "content" => text,
      "id" => ActivityPub.Utils.generate_object_id(),
      "actor" => actor.data["id"],
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "likes" => [],
      "like_count" => 0,
      "context" => "context",
      "summary" => "summary",
      "tag" => ["tag"]
    }

    %ActivityPub.Object{
      data: merge_attributes(data, Map.get(attrs, :data, %{})),
      local: actor.local,
      public: ActivityPub.Utils.public?(data)
    }
  end

  def note_activity_factory(attrs \\ %{}) do
    actor = attrs[:actor] || insert(:actor)
    note = attrs[:note] || insert(:note, actor: actor)

    data_attrs = attrs[:data_attrs] || %{}
    attrs = Map.drop(attrs, [:actor, :note, :data_attrs])

    data =
      %{
        "id" => ActivityPub.Utils.generate_object_id(),
        "type" => "Create",
        "actor" => note.data["actor"],
        "to" => note.data["to"],
        "object" => note.data["id"],
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "context" => note.data["context"]
      }
      |> Map.merge(data_attrs)

    %ActivityPub.Object{
      data: data,
      local: note.local,
      public: note.public
    }
    |> Map.merge(attrs)
  end

  def announce_activity_factory(attrs \\ %{}) do
    note_activity = attrs[:note_activity] || insert(:note_activity)
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
      host: "domain.com",
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
