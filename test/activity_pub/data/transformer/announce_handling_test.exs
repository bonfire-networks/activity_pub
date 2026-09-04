# Copyright © 2017-2023 Bonfire, Akkoma, and Pleroma Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.Federator.Transformer.AnnounceHandlingTest do
  use ActivityPub.DataCase, async: false

  alias ActivityPub.Object, as: Activity
  alias ActivityPub.Object
  alias ActivityPub.Actor
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Test.HttpRequestMock

  import ActivityPub.Factory
  import Tesla.Mock

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  test "it works for incoming announces" do
    announce_actor = insert(:actor)
    note = insert(:note)

    data =
      file("fixtures/mastodon/mastodon-announce.json")
      |> Jason.decode!()
      |> Map.put("actor", announce_actor.data["id"])
      |> Map.put("object", note.data["id"])

    {:ok, %Object{data: data, local: false}} = Transformer.handle_incoming(data)

    assert data["actor"] == announce_actor.data["id"]
    assert data["type"] == "Announce"

    assert data["id"] ==
             "https://mastodon.local/users/admin/statuses/99542391527669785/activity"

    assert Object.get_ap_id(data["object"]) =~
             note.data["id"]
  end

  test "it works for incoming announces with an existing activity" do
    actor = local_actor()
    {:ok, note_actor} = Actor.get_cached(username: actor.username)

    note_activity =
      insert(:note_activity, %{actor: note_actor})
      |> debug("create_activity")

    announce_actor = insert(:actor)

    data =
      file("fixtures/mastodon/mastodon-announce.json")
      |> Jason.decode!()
      |> Map.put("object", note_activity.data["object"])
      |> Map.put("actor", announce_actor.data["id"])

    {:ok, %Object{data: data, local: false}} =
      Transformer.handle_incoming(data)
      |> debug("announce_activity")

    assert data["actor"] == announce_actor.data["id"]
    assert data["type"] == "Announce"

    assert data["id"] ==
             "https://mastodon.local/users/admin/statuses/99542391527669785/activity"

    object =
      Object.get_ap_id(data["object"])
      |> debug("got_object")

    assert object =~ note_activity.data["object"]

    {:ok, fetched} =
      Fetcher.fetch_object_from_id(data["object"])
      |> debug("fetched_object")

    assert fetched.data["id"] == note_activity.data["object"]
    # assert fetched.id == note_activity.id
  end

  @tag :todo
  test "it works for incoming honk announces" do
    user = actor(ap_id: "https://mastodon.local/users/admin", local: false)
    other_user = local_actor()
    post = local_note_activity(%{actor: other_user, status: "bonkeronk"})

    announce = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "actor" => "https://mastodon.local/users/admin",
      "id" => "https://mastodon.local/users/admin/bonk/1793M7B9MQ48847vdx",
      "object" => post.data["object"],
      "published" => "2019-06-25T19:33:58Z",
      "to" => "https://www.w3.org/ns/activitystreams#Public",
      "type" => "Announce"
    }

    {:ok, %Activity{local: false}} = Transformer.handle_incoming(announce)

    {:ok, object} = Object.get_cached(ap_id: post.data["object"])

    assert is_list(debug(object.data["announcements"])) and
             length(object.data["announcements"]) == 1

    assert ap_id(user) in object.data["announcements"]
  end

  @tag :todo
  test "it works for incoming announces with actor being inlined (kroeg)" do
    data = file("fixtures/kroeg-announce-with-inline-actor.json") |> Jason.decode!()

    _user = actor(local: false, ap_id: data["actor"]["id"])
    other_user = local_actor()

    post = insert(:note_activity, %{actor: other_user, status: "kroegeroeg"})

    data =
      data
      |> put_in(["object", "id"], post.data["object"])

    {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

    assert data["actor"] == "https://puckipedia.local/"
  end

  test "it works for incoming announces, fetching the announced object" do
    data =
      file("fixtures/mastodon/mastodon-announce.json")
      |> Jason.decode!()
      |> Map.put("object", "https://mastodon.local/users/admin/statuses/99512778738411822")

    _user = actor(local: false, ap_id: data["actor"])

    {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

    assert data["actor"] == "https://mastodon.local/users/admin"
    assert data["type"] == "Announce"

    assert data["id"] ==
             "https://mastodon.local/users/admin/statuses/99542391527669785/activity"

    assert Object.get_ap_id(data["object"]) =~
             "https://mastodon.local/users/admin/statuses/99512778738411822"

    assert {:ok, _} = Fetcher.fetch_object_from_id(data["object"])
  end

  # Ignore inlined activities for now
  @tag skip: true
  test "it works for incoming announces with an inlined activity" do
    data =
      file("fixtures/mastodon/mastodon-announce-private.json")
      |> Jason.decode!()

    _user =
      insert(:actor,
        local: false,
        ap_id: data["actor"],
        follower_address: data["actor"] <> "/followers"
      )

    {:ok, %Activity{data: data, local: false}} = Transformer.handle_incoming(data)

    assert data["actor"] == "https://mastodon.local/users/admin"
    assert data["type"] == "Announce"

    assert data["id"] ==
             "https://mastodon.local/users/admin/statuses/99542391527669785/activity"

    object = Object.normalize(data["object"], fetch: false)

    assert object.data["id"] == "https://mastodon.local/@admin/99541947525187368"
    assert object.data["content"] == "this is a private toot"
  end

  # FEP-1b12: a group relays by announcing the ACTIVITY (`Announce{Create{…}}`) rather than the object, which is what a Mastodon-style boost does. Verified against real captures from Lemmy, PieFed and NodeBB, as all three send this shape exclusively, so without unwrapping, the embedded `Create` is mistaken for the announced object and the inner object is never ingested at all.
  describe "a group announcing an activity (FEP-1b12)" do
    test "unwraps the inlined activity and ingests its object" do
      group = insert(:actor)
      author = insert(:actor)

      object_id = "#{author.data["id"]}/posts/1b12-unwrap"

      data = %{
        "type" => "Announce",
        "id" => "#{group.data["id"]}/activities/announce/1b12-unwrap",
        "actor" => group.data["id"],
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => %{
          "type" => "Create",
          "id" => "#{author.data["id"]}/activities/create/1b12-unwrap",
          "actor" => author.data["id"],
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "object" => %{
            "type" => "Note",
            "id" => object_id,
            "attributedTo" => author.data["id"],
            "audience" => group.data["id"],
            "content" => "announced by the group, authored by someone else",
            "to" => [group.data["id"], "https://www.w3.org/ns/activitystreams#Public"]
          }
        }
      }

      assert {:ok, %Object{data: announce}} = Transformer.handle_incoming(data)

      assert announce["type"] == "Announce"
      assert announce["actor"] == group.data["id"]

      assert Object.get_ap_id(announce["object"]) =~ object_id,
             "the announce should point at the inner OBJECT, not at the wrapping activity"

      assert %Object{data: note} = Object.normalize(object_id, fetch: false),
             "the inner object must be ingested — this is what fails when the activity is mistaken for the object"

      assert note["attributedTo"] == author.data["id"],
             "attribution stays with the author, not the announcing group"
    end

    # How far to trust an activity handed to us by a relay, mirroring the policy the inbox already applies to forwarded activities (`receiver_helpers.ex`): a verifiable signature is enough, otherwise it depends on configuration. Lemmy/PieFed/NodeBB do NOT sign relayed activities (verified against real captures), so this setting decides what happens to all of their content.
    # How far to trust an activity handed to us by a relay. Lemmy/PieFed/NodeBB do NOT sign relayed activities (verified against real captures), so this setting governs ALL threadiverse content rather than some edge case. See `Transformer.relayed_activity_trust/0`.
    test "`trust` accepts the inline copy even when the origin won't serve it" do
      mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

      with_trust_mode(:trust, fn ->
        %{data: data, object_id: object_id} = relayed_announce()

        assert {:ok, _} = Transformer.handle_incoming(data)

        assert %Object{} = Object.normalize(object_id, fetch: false),
               "the relayed copy should be accepted as-is"
      end)
    end

    test "`verify` refuses when the origin says the object does not exist" do
      mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

      with_trust_mode(:verify, fn ->
        %{data: data, object_id: object_id} = relayed_announce()

        assert {:error, _} = Transformer.handle_incoming(data)

        assert is_nil(Object.normalize(object_id, fetch: false)),
               "a 404 is evidence AGAINST the relayed copy, not a reason to fall back to it: otherwise a forger guarantees acceptance by pointing the inner id at any nonexistent URL on the victim's host"
      end)
    end

    test "`verify` accepts when the origin refuses to answer US (401/403)" do
      mock(fn %{method: :get} -> %Tesla.Env{status: 403, body: ""} end)

      with_trust_mode(:verify, fn ->
        %{data: data, object_id: object_id} = relayed_announce()

        assert {:ok, _} = Transformer.handle_incoming(data)

        assert %Object{} = Object.normalize(object_id, fetch: false),
               "'not to you' says nothing about whether the object exists, and is the case 1b12 exists for"
      end)
    end

    test "`verify` is not fooled by an unverifiable signature" do
      mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

      with_trust_mode(:verify, fn ->
        %{data: data, object_id: object_id} = relayed_announce()

        # merely LOOKING signed must not be enough: `has_verifiable_signature?/1` only checks the
        # shape, so a forger could otherwise skip verification by attaching this field
        signed =
          put_in(data["object"]["signature"], %{
            "type" => "RsaSignature2017",
            "creator" => "#{data["actor"]}#main-key",
            "signatureValue" => "bogus"
          })

        assert {:error, _} = Transformer.handle_incoming(signed)

        assert is_nil(Object.normalize(object_id, fetch: false)),
               "an invalid signature must not buy more trust than no signature at all"
      end)
    end

    test "a broken signature is refused even in `trust` mode" do
      mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

      with_trust_mode(:trust, fn ->
        %{data: data, object_id: object_id} = relayed_announce()

        signed =
          put_in(data["object"]["signature"], %{
            "type" => "RsaSignature2017",
            "creator" => "#{data["actor"]}#main-key",
            "signatureValue" => "bogus"
          })

        assert {:error, _} = Transformer.handle_incoming(signed)

        assert is_nil(Object.normalize(object_id, fetch: false)),
               "trusting UNSIGNED relays is a choice about missing evidence; a signature that fails to verify is evidence against the relayed bytes, so they are never stored — and here the origin has nothing to offer instead"
      end)
    end

    test "a broken signature falls back to the origin rather than losing the post" do
      %{data: data, object_id: object_id, inner_object: inner} = relayed_announce()
      authentic = Map.put(inner, "content", "what the author actually wrote")

      mock(fn
        %{method: :get, url: url} when url == object_id -> json(authentic)
        %{method: :get} -> %Tesla.Env{status: 404, body: ""}
      end)

      with_trust_mode(:trust, fn ->
        signed =
          put_in(data["object"]["signature"], %{
            "type" => "RsaSignature2017",
            "creator" => "#{data["actor"]}#main-key",
            "signatureValue" => "bogus"
          })

        assert {:ok, _} = Transformer.handle_incoming(signed)

        assert %Object{data: stored} = Object.normalize(object_id, fetch: false)

        assert stored["content"] == "what the author actually wrote",
               "the relay's bytes are discarded, but the post still arrives from its origin. Refusing outright loses content the origin is happy to give us, and a reserialising relay is a likelier cause of a broken signature than an attack"
      end)
    end

    test "`verify` prefers the ORIGIN's copy over the relayed one" do
      %{data: data, object_id: object_id, inner_object: inner} = relayed_announce()
      authentic = Map.put(inner, "content", "what the author actually wrote")

      mock(fn
        %{method: :get, url: url} when url == object_id -> json(authentic)
        %{method: :get} -> %Tesla.Env{status: 404, body: ""}
      end)

      with_trust_mode(:verify, fn ->
        assert {:ok, _} = Transformer.handle_incoming(data)

        assert %Object{data: stored} = Object.normalize(object_id, fetch: false)

        assert stored["content"] == "what the author actually wrote",
               "verifying is pointless if we then store the relay's version anyway"
      end)
    end

    test "refuses an inlined activity forged from another origin" do
      group = insert(:actor)
      author = insert(:actor)

      # the group claims to relay an activity whose id is on ITS OWN host while attributing it to a
      # different actor — the forgery a relay could otherwise perform
      data = %{
        "type" => "Announce",
        "id" => "#{group.data["id"]}/activities/announce/forged",
        "actor" => group.data["id"],
        "object" => %{
          "type" => "Create",
          "id" => "#{group.data["id"]}/activities/create/forged",
          "actor" => author.data["id"],
          "object" => %{
            "type" => "Note",
            "id" => "#{group.data["id"]}/posts/forged",
            "attributedTo" => author.data["id"],
            "content" => "put words in someone else's mouth"
          }
        }
      }

      assert {:error, _} = Transformer.handle_incoming(data)

      assert is_nil(Object.normalize("#{group.data["id"]}/posts/forged", fetch: false)),
             "nothing from a forged relay should be ingested"
    end
  end

  test "it rejects incoming announces with an inlined activity from another origin" do
    Tesla.Mock.mock(fn
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    data =
      file("fixtures/bogus-mastodon-announce.json")
      |> Jason.decode!()

    # _user = actor(local: false, ap_id: data["actor"])

    assert {:error, _e} = Transformer.handle_incoming(data)
  end

  # A group relaying a THIRD PARTY's activity: the case where trust actually matters. (A group relaying its own instance's activity is already covered by the delivering instance's HTTP signature.)
  describe "a remote that dual-emits" do
    # Lemmy and its family send the SAME content twice, as `Announce{Create{…}}` and as a compat
    # `Announce{<object>}`, with different activity ids and nothing in common but actor and object
    # (observed live against lemmy.world, 2026-09-04). The pair must land once.
    test "the compat copy is discarded, and the content is kept once" do
      mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

      %{data: data, object_id: object_id} = relayed_announce()

      assert {:ok, _} = Transformer.handle_incoming(data)

      # positive control: the 1b12 copy really did land, so a "skipped" result below means DEDUPED
      # rather than "never worked in the first place"
      assert %Object{} = object = Object.normalize(object_id, fetch: false)

      assert %Object{} = first = Object.get_existing_announce(data["actor"], object),
             "the first announce should have been recorded"

      compat = %{
        "type" => "Announce",
        "id" => "#{data["actor"]}/activities/announce/compat",
        "actor" => data["actor"],
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => object_id
      }

      assert {:ok, :duplicate} = Transformer.handle_incoming(compat),
             "must be skipped AS a duplicate: any other outcome, including an error, would satisfy the assertions below for the wrong reason"

      assert %Object{id: kept_id} = Object.get_existing_announce(data["actor"], object)

      assert kept_id == first.id,
             "the compat copy must not add a second announce of the same object by the same actor"

      refute Object.get_cached!(ap_id: compat["id"]),
             "and it must be discarded BEFORE it is stored, not cleaned up afterwards"
    end

    test "a different actor announcing the same object is not treated as a duplicate" do
      mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

      %{data: data, object_id: object_id} = relayed_announce()
      assert {:ok, _} = Transformer.handle_incoming(data)

      someone_else = insert(:actor)

      other = %{
        "type" => "Announce",
        "id" => "#{someone_else.data["id"]}/activities/announce/1",
        "actor" => someone_else.data["id"],
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => object_id
      }

      assert {:ok, _} = Transformer.handle_incoming(other)

      assert Object.get_cached!(ap_id: other["id"]),
             "dedup is per actor: someone else boosting the same post is a real, separate activity"
    end
  end

  defp relayed_announce do
    group = insert(:actor)
    author = insert(:actor)

    object_id = "#{author.data["id"]}/posts/relayed"

    inner_object = %{
      "type" => "Note",
      "id" => object_id,
      "attributedTo" => author.data["id"],
      "audience" => group.data["id"],
      "content" => "what the relay claims the author wrote",
      "to" => [group.data["id"], "https://www.w3.org/ns/activitystreams#Public"]
    }

    %{
      object_id: object_id,
      inner_object: inner_object,
      data: %{
        "type" => "Announce",
        "id" => "#{group.data["id"]}/activities/announce/relayed",
        "actor" => group.data["id"],
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => %{
          "type" => "Create",
          "id" => "#{author.data["id"]}/activities/create/relayed",
          "actor" => author.data["id"],
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "object" => inner_object
        }
      }
    }
  end

  defp with_trust_mode(mode, fun) do
    previous = Application.get_env(:activity_pub, :relayed_activity_trust)
    Application.put_env(:activity_pub, :relayed_activity_trust, mode)

    try do
      fun.()
    after
      Application.put_env(:activity_pub, :relayed_activity_trust, previous)
    end
  end
end
