defmodule ActivityPub.Federator.Transformer.ActorlessObjectTest do
  @moduledoc """
  A standalone object delivered with no `actor`/`attributedTo` where authorship is only implied by the HTTP signature.

  `handle_incoming/2` wraps such an object in a synthetic `#virtual_create_activity` Create. Two things must hold: the synthetic activity has to stay a valid AS2 document (no Elixir error tuple smuggled in where an actor URI belongs), and the attribution fallback must never reach for a *remote* actor.
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory

  alias ActivityPub.Object

  defp event_doc do
    %{
      "type" => "Event",
      "id" => "https://mastodon.local/event/7e57f6b1-8133-42f0-b196-8241bd847a6c",
      "name" => "test2",
      "content" => "fo bar",
      "startTime" => "2026-08-21T15:47:13Z",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }
  end

  describe "actor_from_data/1" do
    test "returns nil (not an error tuple) when the document names no actor" do
      assert Object.actor_from_data(event_doc()) == nil
    end

    test "returns nil for a list that contains no usable actor" do
      assert Object.actor_from_data([%{"type" => "Event"}, %{"type" => "Place"}]) == nil
    end

    test "still finds a declared actor" do
      assert Object.actor_from_data(%{"actor" => "https://mastodon.local/users/karen"}) ==
               "https://mastodon.local/users/karen"

      assert Object.actor_from_data(%{"attributedTo" => "https://mastodon.local/users/karen"}) ==
               "https://mastodon.local/users/karen"
    end
  end

  describe "the synthetic Create wrapped around an actorless object" do
    test "is a JSON-encodable AS2 document" do
      data =
        case ActivityPub.Federator.Transformer.handle_incoming(event_doc()) do
          {:ok, %{data: data}} -> data
          {:ok, data} when is_map(data) -> data
          other -> flunk("expected an activity or a refusal, got: #{inspect(other)}")
        end

      # an error tuple where an actor URI belongs is not encodable, and would break anything
      # downstream that serialises the document (Oban args, outgoing federation, the adapter)
      assert {:ok, _json} = Jason.encode(data)
    end

    test "is never attributed to a remote actor" do
      # a remote actor is present in the DB (as one federated in would be), so a fallback that
      # looks up an actor without checking locality can find it
      _remote = actor()

      case ActivityPub.Federator.Transformer.handle_incoming(event_doc()) do
        {:ok, %{data: %{"actor" => actor_id}}} when is_binary(actor_id) ->
          {:ok, attributed} = ActivityPub.Actor.get_cached(ap_id: actor_id)

          assert attributed.local,
                 "actorless object was attributed to remote actor #{actor_id}"

        other ->
          # refusing outright is also acceptable — inventing a remote author is not
          refute match?({:ok, _}, other)
      end
    end
  end
end
