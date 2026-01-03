defmodule ActivityPub.Factory do
  import ActivityPub.Test.Helpers
  import ActivityPub.Utils
  alias ActivityPub.Actor
  alias ActivityPub.Object
  import Untangle
  alias ActivityPub.Federator.Adapter
  @repo repo()
  use ExMachina.Ecto, repo: @repo

  def actor(attrs \\ %{}) do
    actor = insert(:actor, attrs)
    cached_or_handle(actor)
  end

  def cached_or_handle(object) do
    {:ok, object} =
      ActivityPub.Federator.Fetcher.cached_or_handle_incoming(object, already_fetched: true)

    object
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
        |> repo().maybe_preload(character: [:actor])

      {:ok, actor} = ActivityPub.Actor.get_cached(username: user.character.username)

      if attrs[:also_known_as],
        do:
          add_alias(actor, attrs[:also_known_as])
          |> debug("adddded")

      {:ok, actor} = ActivityPub.Actor.get_cached(username: user.character.username)

      %{
        local: true,
        actor: actor,
        data: actor.data,
        user: user,
        keys: Map.get(user.character.actor || %{}, :signing_key),
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

  def add_alias(%{local: true} = actor, to_alias) do
    {:ok, _actor} =
      Adapter.update_local_actor(
        actor,
        Map.put(
          actor.data,
          "alsoKnownAs",
          (Map.get(actor.data, "alsoKnownAs") || []) ++ [to_alias]
        )
      )
  end

  def add_alias(actor, to_alias) do
    {:ok, _actor} =
      Adapter.update_remote_actor(actor, %{
        data:
          Map.put(
            actor.data,
            "alsoKnownAs",
            (Map.get(actor.data, "alsoKnownAs") || []) ++ [to_alias]
          )
      })
  end

  def actor_factory(attrs \\ %{}) do
    username = sequence(:username, &"actor_#{&1}_#{Needle.UID.generate()}")

    actor_object("https://mastodon.local/ap_api", username, attrs, false)
  end

  def local_actor_factory(attrs \\ %{}) do
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")
    username = attrs[:username] || sequence(:username, &"username#{&1}")

    actor_object(ActivityPub.Web.base_url() <> ap_base_path, username, attrs, true)
  end

  defp actor_object(base_url, username, attrs, local?) do
    id =
      attrs[:ap_id] || base_url <> "/actors/#{username}"

    data = %{
      "id" => id,
      "name" => sequence(:name, &"Test actor #{&1}"),
      "preferredUsername" => username,
      "summary" => attrs[:bio] || sequence(:bio, &"Tester Number#{&1}"),
      "type" => attrs[:type] || "Person",
      "alsoKnownAs" => attrs[:also_known_as] || [],
      "inbox" => "#{id}/inbox",
      "outbox" => "#{id}/outbox",
      "followers" => "#{id}/followers",
      "following" => "#{id}/following",
      "endpoints" => %{
        "sharedInbox" => attrs[:shared_inbox] || "#{base_url}/shared_inbox"
      }
    }

    %ActivityPub.Object{
      data: merge_attributes(Map.get(attrs, :data, %{}), data),
      local: attrs[:local] || local?,
      public: true
    }
  end

  def community(attrs \\ %{}) do
    actor = insert(:actor, attrs)
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

  def collection(attrs \\ %{}) do
    actor = insert(:actor, attrs)
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

  def local_or_remote_note(attrs, actor) do
    attrs =
      attrs
      #  |> Map.drop(["inReplyTo"])
      |> Enum.into(%{actor: actor})

    actor
    |> debug("actor")

    if actor.local do
      local_note(attrs)
      |> debug("local_note")
    else
      insert(
        :note,
        attrs
      )
      |> debug("remote_note")
    end
  end

  def local_note(attrs \\ %{}) do
    actor = attrs[:actor] || local_actor()

    if ActivityPub.Federator.Adapter.adapter() == Bonfire.Federate.ActivityPub.Adapter and
         Code.ensure_loaded?(Bonfire.Posts.Fake) do
      text = attrs[:status] || sequence(:text, &"This is local note #{&1}")

      with %{} = user <- user_by_ap_id(actor) |> debug("user_by_ap_id"),
           %{id: id} = post <-
             Bonfire.Posts.Fake.fake_post!(
               user,
               attrs[:boundary] ||
                 if(
                   !attrs[:to] or
                     "https://www.w3.org/ns/activitystreams#Public" in List.wrap(attrs[:to]),
                   do: "public",
                   else: "mentions"
                 ),
               %{html_body: text},
               to_circles: attrs[:to_circles] || []
             )
             |> debug("the_post"),
           {:ok, object} <- ActivityPub.Object.get_cached(pointer: id) do
        %ActivityPub.Object{
          data: object.data,
          local: true,
          public: ActivityPub.Utils.public?(object),
          pointer: post,
          is_object: true
        }
      else
        {:error, :not_found} ->
          error(attrs, "Error creating local note: not found")
          {:error, :not_found}

        error ->
          raise "Error creating local note: #{inspect(error)}"
      end
    else
      note = build(:note, attrs |> Enum.into(%{actor: actor}))
      insert(note)
    end
  end

  def local_note_activity(attrs \\ %{}) do
    with %Object{} = note <- attrs[:note] || local_note(attrs) do
      if ActivityPub.Federator.Adapter.adapter() == Bonfire.Federate.ActivityPub.Adapter and
           Code.ensure_loaded?(Bonfire.Social.Fake) do
        ActivityPub.Object.get_activity_for_object_ap_id(note.data["id"])
      else
        actor = attrs[:actor] || local_actor()
        activity = build(:note_activity, attrs |> Enum.into(%{actor: actor, note: note}))
        insert(activity)
      end
    end
  end

  def note_factory(attrs \\ %{}) do
    attrs = attrs |> Enum.into(%{})
    text = attrs[:status] || sequence(:text, &"This is note #{&1}")
    actor = attrs[:actor] || insert(:actor, attrs)

    data =
      %{
        "type" => "Note",
        "content" => text,
        "id" => ActivityPub.Utils.generate_object_id(),
        "actor" => actor.data["id"],
        "to" => attrs[:to] || ["https://www.w3.org/ns/activitystreams#Public"],
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        # "likes" => [],
        # "like_count" => 0,
        "context" => "context",
        "summary" => "summary",
        "tag" => ["tag"]
      }
      |> debug("base_data")

    %ActivityPub.Object{
      data:
        merge_attributes(data, Map.get(attrs, :data, Map.drop(attrs, [:actor, :status, :note]))),
      local: actor.local,
      public: ActivityPub.Utils.public?(data),
      is_object: true
    }
    |> debug("prepared object")
  end

  def local_direct_note(attrs \\ %{}) do
    to = attrs[:to] || local_actor()

    local_note(
      attrs
      |> Enum.into(%{
        boundary: "mentions",
        # status: attrs[:status] || "@#{Actor.format_username(to)} status with mention", 
        to_circles: [user_by_ap_id(to)],
        actor: attrs[:actor] || local_actor()
      })
    )
  end

  def direct_note_factory(attrs \\ %{}) do
    to = attrs[:to] || insert(:actor, attrs)

    %ActivityPub.Object{data: data} = note_factory(attrs |> Enum.into(%{boundary: "mentions"}))

    %ActivityPub.Object{
      public: false,
      data: Map.merge(data, %{"to" => [ActivityPub.Utils.ap_id(to)]})
    }
  end

  def direct_note_activity_factory(attrs \\ %{}) do
    note_activity_factory(attrs |> Enum.into(%{note: attrs[:note] || insert(:direct_note)}))
  end

  def note_activity_factory(attrs \\ %{}) do
    with actor = (attrs[:actor] || insert(:actor, attrs)) |> debug("actor"),
         %{data: _} = note <-
           (attrs[:note] || local_or_remote_note(attrs, actor)) |> debug("the_note") do
      actor = note.data["actor"]

      attrs = attrs |> Enum.into(%{}) |> Map.drop([:actor, :note, :data_attrs])
      data_attrs = attrs[:data_attrs] || attrs |> Map.drop([:status])

      data =
        %{
          "id" => ActivityPub.Utils.generate_object_id(),
          "type" => "Create",
          "actor" => actor,
          "to" => note.data["to"],
          "cc" => note.data["cc"],
          "bto" => note.data["bto"],
          "bcc" => note.data["bcc"],
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
  end

  def announce_activity_factory(attrs \\ %{}) do
    note_activity = attrs[:note_activity] || insert(:note, attrs)
    actor = attrs[:actor] || insert(:actor, attrs)

    data = %{
      "type" => "Announce",
      "actor" => actor.data["id"],
      "object" => note_activity.data["id"],
      "to" => [
        actor.data["followers"],
        note_activity.data["attributedTo"] || note_activity.data["actor"]
      ],
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
      "actor" => ActivityPub.Utils.ap_id(follower),
      "type" => "Follow",
      "object" => ActivityPub.Utils.ap_id(followed),
      "state" => attrs[:state] || "pending",
      "published_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    %ActivityPub.Object{
      data: data
    }
    |> Map.merge(attrs)
  end

  def like_activity_factory(attrs \\ %{}) do
    note_activity = insert(:note_activity, attrs)
    object = ActivityPub.Object.normalize(note_activity)
    actor = insert(:actor, attrs)

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
