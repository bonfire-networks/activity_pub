defmodule ActivityPub.Web.C2SProofTest do
  @moduledoc """
  What a client sends in through C2S, and the proofs (FEP-8b32) on it.

  Delivered, it is signed like anything else of ours: at publish, a `Create` gets a proof on its object and on itself. A proof the client made (with a key of its own, FEP-ae97, or the actor's) is not kept today: the object is stored rewritten, so ours goes on instead. Keeping it is out of scope, and its test is an optional todo.

  Served (by id, in the outbox), it is not signed today: it is stored as sent and `ObjectView` signs nothing. Pinned here as it is, so the choice of signing it (plan step 10.2, 10.3) changes a test rather than goes unnoticed.
  """
  use ActivityPub.Web.ConnCase, async: false
  use Oban.Testing, repo: repo()

  import ActivityPub.Factory
  import Tesla.Mock
  import Plug.Conn
  import Phoenix.ConnTest

  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Federator.Workers.PublisherWorker
  alias ActivityPub.Object
  alias ActivityPub.Safety.IntegrityProofs
  alias ActivityPub.Test.HttpRequestMock
  alias ActivityPub.Tests.ObanHelpers
  alias ActivityPub.Utils
  alias ActivityPub.Web.ObjectView

  @content_type "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""
  @public "https://www.w3.org/ns/activitystreams#Public"
  @created "2026-10-28T09:00:00Z"

  setup_all do
    Tesla.Mock.mock_global(fn env -> HttpRequestMock.request(env) end)
    :ok
  end

  setup do
    n = System.unique_integer([:positive])
    author = local_actor()

    # storing an object never makes the actor's keys, so an author who has published has them already
    {:ok, actor} = ActivityPub.Actor.get_cached(username: author.username)
    {:ok, _} = ActivityPub.Safety.Keys.ensure_keys_present(actor)

    follower =
      actor(
        ap_id: "https://follower-#{n}.example/users/follower",
        shared_inbox: "https://follower-#{n}.example/inbox"
      )

    # the follower follows the author, so what the author posts is delivered to it
    assert {:ok, _} =
             Transformer.handle_incoming(
               %{
                 "@context" => "https://www.w3.org/ns/activitystreams",
                 "id" => "#{follower.ap_id}/follows/#{n}",
                 "type" => "Follow",
                 "actor" => follower.ap_id,
                 "object" => ap_id(author)
               },
               from_inbox: true,
               authenticated: :http_signature,
               signed_by: follower.ap_id
             )

    %{author: author, user: user_by_ap_id(author)}
  end

  defp post_create(conn, author, user, note) do
    conn =
      conn
      |> assign(:current_user, user)
      |> put_req_header("content-type", @content_type)
      |> post("#{Utils.ap_base_url()}/actors/#{author.username}/outbox", %{
        "type" => "Create",
        "object" => note
      })

    assert conn.status == 201
    json_response(conn, 201)
  end

  # what is sent to each inbox
  defp delivered do
    all_enqueued(worker: PublisherWorker)
    |> Enum.filter(&(&1.args["op"] == "publish"))
    |> ObanHelpers.perform()

    for %{args: %{"op" => "publish_one", "params" => params}} <-
          all_enqueued(worker: PublisherWorker),
        %{"type" => "Create"} = json <- [Jason.decode!(params["json"])],
        do: json
  end

  defp note(extra \\ %{}),
    do: Map.merge(%{"type" => "Note", "content" => "from a client", "to" => [@public]}, extra)

  test "a Create sent in through C2S is delivered with a proof on the activity and on the object",
       %{conn: conn, author: author, user: user} do
    post_create(conn, author, user, note())

    assert [_ | _] = creates = delivered()

    for create <- creates do
      assert %{"proof" => _} = create
      assert %{"proof" => _} = create["object"]
      assert IntegrityProofs.verify(create) == {:ok, ap_id(author)}
      assert IntegrityProofs.verify(create["object"]) == {:ok, ap_id(author)}
    end
  end

  # Optional TODO: keeping a proof a client made. Not built. The adapter stores the object of a C2S `Create` rewritten (`@context` expanded, `actor`, `context` and other keys added), so the client's proof no longer holds over it and the delivered object carries a fresh proof of ours. Delivering the client's own needs the object stored as the client sent it.
  @tag :todo
  test "an object the client signed already is delivered as it is", %{
    conn: conn,
    author: author,
    user: user
  } do
    {:ok, actor} = ActivityPub.Actor.get_cached(username: author.username)

    {:ok, signed_note} =
      IntegrityProofs.sign(Map.put(note(), "attributedTo", ap_id(author)), actor,
        created: @created
      )

    post_create(conn, author, user, signed_note)

    assert [_ | _] = creates = delivered()

    for create <- creates do
      assert create["object"]["proof"]["created"] == @created,
             "the client's proof was replaced by a new one, in #{inspect(create["object"])}"
    end
  end

  # Signed when stored (plan step 10.2), not when served: the object is kept with its proof, and what is served is that document. The `Create` around it is not signed there, as its proof is per inbox.
  test "the object a Create is served with, by id, is the stored signed one",
       %{conn: conn, author: author, user: user} do
    created = post_create(conn, author, user, note())
    {:ok, create} = Object.get_cached(ap_id: created["id"] || created)

    served = ObjectView.render("object.json", %{object: create})

    assert IntegrityProofs.verify(served["object"]) == {:ok, ap_id(author)}
  end

  test "and the same in the outbox", %{conn: conn, author: author, user: user} do
    post_create(conn, author, user, note())
    {:ok, actor} = ActivityPub.Actor.get_cached(username: author.username)

    assert %{"orderedItems" => [_ | _] = items} =
             ObjectView.render("outbox.json", %{actor: actor, page: 1})

    creates = Enum.filter(items, &(&1["type"] == "Create"))
    assert creates != [], "no Create in the outbox, only #{inspect(Enum.map(items, & &1["type"]))}"

    for item <- creates do
      assert IntegrityProofs.verify(item["object"]) == {:ok, ap_id(author)},
             "the object of #{item["id"]} does not verify"
    end
  end
end
