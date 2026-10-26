defmodule ActivityPub.Federator.ForwarderTest do
  @moduledoc """
  Which received activities are forwarded (ActivityPub 7.1.2), and to whom: a signed reply to one of our users' posts, and an `Update` or `Delete` of one, go to the remote followers of the post's author, each inbox once, never to the sender nor to an inbox the author addressed. Exactly as received, in a request with our user's HTTP signature.

  Who else gets a copy (the authors further up the thread, those who boosted or quoted the post, or nobody when a group we host relays it) is the adapter's to decide (`Adapter.forward_to_followers_of_actors/2`), and to test with its own data. These hold whatever it decides, as the author of the post replied to is always among them.

  `Forwarder.recipients/2` is asked before the activity is handled: a deletion takes the reply away, and with it the way to its thread. The receiver forwards only what it then accepted, and never an activity it held already (a copy delivered again).
  """
  use ActivityPub.DataCase, async: false
  use Oban.Testing, repo: repo()

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Actor
  alias ActivityPub.Object
  alias ActivityPub.Federator.Forwarder
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Federator.Worker.ReceiverHelpers
  alias ActivityPub.Federator.Workers.PublisherWorker
  alias ActivityPub.Safety.IntegrityProofs
  alias ActivityPub.Tests.ObanHelpers

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    n = System.unique_integer([:positive])

    # a post of ours, made the way the host app makes one, and its author
    post = local_note()
    {:ok, owner} = Actor.get_cached(ap_id: Object.actor_from_data(post.data))

    # on different hosts, so each has an inbox of its own
    follower = remote_actor("https://follower-#{n}.example", "follower")
    other_follower = remote_actor("https://other-#{n}.example", "follower")
    for f <- [follower, other_follower], do: assert({:ok, _} = follows(f, owner))

    key = new_key(:ed25519)
    replier_id = "https://replier-#{n}.example/users/replier"

    replier =
      actor(
        ap_id: replier_id,
        shared_inbox: "https://replier-#{n}.example/inbox",
        data: %{"assertionMethod" => [multikey(replier_id, key)]}
      )

    %{
      n: n,
      owner: owner,
      follower: follower,
      other_follower: other_follower,
      key: key,
      replier: replier,
      replier_id: replier_id,
      post_id: post.data["id"]
    }
  end

  # the factory gives every actor the same shared inbox, and deliveries are grouped by it: one of their own makes each a separate delivery
  defp remote_actor(origin, name),
    do: actor(ap_id: "#{origin}/users/#{name}", shared_inbox: "#{origin}/inbox")

  defp follows(follower, followed) do
    Transformer.handle_incoming(
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{follower.ap_id}/follows/#{System.unique_integer([:positive])}",
        "type" => "Follow",
        "actor" => follower.ap_id,
        "object" => followed.data["id"]
      },
      from_inbox: true,
      authenticated: :http_signature,
      signed_by: follower.ap_id
    )
  end

  defp inbox(%{ap_id: id}),
    do: id |> URI.parse() |> Map.merge(%{path: "/inbox"}) |> URI.to_string()

  # the replier's signed reply to `in_reply_to`
  defp reply(context, in_reply_to, extra \\ %{}) do
    n = System.unique_integer([:positive])

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/data-integrity/v2"
      ],
      "id" => "#{context.replier_id}/activities/#{n}",
      "type" => "Create",
      "actor" => context.replier_id,
      "to" => [@public],
      "object" => %{
        "id" => "#{context.replier_id}/notes/#{n}",
        "type" => "Note",
        "attributedTo" => context.replier_id,
        "content" => "<p>a reply</p>",
        "inReplyTo" => in_reply_to,
        "to" => [@public]
      }
    }
    |> Map.merge(extra)
    |> sign(context.key)
  end

  # the replier's signed `type` (an `Update` or a `Delete`) of `object`
  defp signed(context, type, object) do
    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/data-integrity/v2"
      ],
      "id" =>
        "#{context.replier_id}/activities/#{String.downcase(type)}-#{System.unique_integer([:positive])}",
      "type" => type,
      "actor" => context.replier_id,
      "to" => [@public],
      "object" => object
    }
    |> sign(context.key)
  end

  # delivered over the replier's HTTP signature, which does not cover what we pass on
  defp recipients(received),
    do:
      Forwarder.recipients(received,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: received["actor"]
      )

  # delivered to our inbox over the replier's verified HTTP signature, as the receiver worker gets it
  defp deliver(received) do
    ReceiverHelpers.perform(
      %Oban.Job{
        args: %{
          "op" => "incoming_ap_doc",
          "params" => received,
          "repo" => ActivityPub.Utils.repo(),
          "signed_by" => received["actor"]
        }
      },
      :verified
    )
  end

  # the forwards of `received` that were queued, by inbox
  defp forwards(received) do
    for %{args: %{"op" => "publish_one", "params" => params}} <-
          all_enqueued(worker: PublisherWorker),
        json = Jason.decode!(params["json"]),
        json["id"] == received["id"],
        into: %{},
        do: {params["inbox"], params}
  end

  describe "a signed reply to a post of ours" do
    test "goes to the remote followers of the post's author, signed as them", context do
      assert {:ok, %{inboxes: inboxes, signer: signer}} =
               recipients(reply(context, context.post_id))

      assert Enum.sort(inboxes) ==
               Enum.sort([inbox(context.follower), inbox(context.other_follower)])

      assert signer.data["id"] == context.owner.data["id"]
    end

    test "not to the sender's own inbox", context do
      # the replier follows our user too, so their inbox is among the followers'
      assert {:ok, _} = follows(context.replier, context.owner)

      assert {:ok, %{inboxes: inboxes}} = recipients(reply(context, context.post_id))
      refute inbox(context.replier) in inboxes
      assert inbox(context.follower) in inboxes
    end

    test "not to an inbox the author addressed, which has it already", context do
      received = reply(context, context.post_id, %{"cc" => [context.follower.ap_id]})

      assert {:ok, %{inboxes: inboxes}} = recipients(received)
      refute inbox(context.follower) in inboxes
      assert inbox(context.other_follower) in inboxes
    end

    test "each inbox once", %{n: n} = context do
      same_server = remote_actor("https://follower-#{n}.example", "colleague")
      assert {:ok, _} = follows(same_server, context.owner)

      assert {:ok, %{inboxes: inboxes}} = recipients(reply(context, context.post_id))
      assert inboxes == Enum.uniq(inboxes)
      assert inbox(same_server) in inboxes
    end
  end

  # the forwarder's decision for `received`, as its telemetry event tells it
  defp decided(received) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:activity_pub, :forwarder, :decided],
      fn _event, _measurements, meta, _config -> send(test_pid, {ref, meta}) end,
      nil
    )

    try do
      deliver(received)
      id = received["id"]
      assert_received {^ref, %{activity_id: ^id, decision: decision}}
      decision
    after
      :telemetry.detach({__MODULE__, ref})
    end
  end

  describe "is not forwarded" do
    # the signature is checked once the activity is stored, so what it found is kept with it
    test "unsigned", context do
      unsigned = context |> reply(context.post_id) |> Map.delete("proof")

      assert {:skip, :unsigned} = decided(unsigned)
      assert forwards(unsigned) == %{}
    end

    test "with a signature that does not hold", context do
      Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

      broken =
        context |> reply(context.post_id) |> put_in(["object", "content"], "<p>changed</p>")

      assert {:skip, {:signature_does_not_hold, _}} = decided(broken)
      assert forwards(broken) == %{}
    end

    test "when it replies to a post that is not ours", context do
      assert {:skip, _} = recipients(reply(context, "https://elsewhere.example/notes/1"))
    end

    test "when it is not public", context do
      received =
        context
        |> reply(context.post_id)
        |> Map.delete("proof")
        |> Map.put("to", [context.owner.data["id"]])
        |> put_in(["object", "to"], [context.owner.data["id"]])
        |> sign(context.key)

      assert {:skip, :not_public} = recipients(received)
    end

    test "when it is ours", context do
      ours = context |> reply(context.post_id) |> Map.put("actor", context.owner.data["id"])

      assert {:skip, :ours} = recipients(ours)
    end
  end

  describe "an edit or a deletion of a reply to a post of ours" do
    setup context do
      received = reply(context, context.post_id)

      assert {:ok, _} =
               Transformer.handle_incoming(received,
                 from_inbox: true,
                 authenticated: :integrity_proof,
                 signed_by: context.replier_id
               )

      %{reply: received["object"]}
    end

    test "an Update is forwarded", %{reply: reply} = context do
      update = signed(context, "Update", Map.put(reply, "content", "<p>an edited reply</p>"))

      assert {:ok, %{inboxes: inboxes}} = recipients(update)
      assert inbox(context.follower) in inboxes
    end

    test "a Delete is forwarded, found through the reply it deletes", %{reply: reply} = context do
      assert {:ok, %{inboxes: inboxes}} = recipients(signed(context, "Delete", reply["id"]))
      assert inbox(context.follower) in inboxes
    end
  end

  describe "through the receiver" do
    test "a signed reply is queued for each inbox, exactly as received, signed as the post's author",
         context do
      received = reply(context, context.post_id)
      assert {:ok, _} = deliver(received)

      forwards = forwards(received)

      assert forwards |> Map.keys() |> Enum.sort() ==
               Enum.sort([inbox(context.follower), inbox(context.other_follower)])

      for {_inbox, params} <- forwards do
        assert Jason.decode!(params["json"]) == received
        assert params["actor_ap_id"] == context.owner.data["id"]
      end
    end

    test "each queued forward is posted to its inbox as received, still carrying the replier's proof, in a request with our user's HTTP signature",
         context do
      received = reply(context, context.post_id)
      assert {:ok, _} = deliver(received)

      test_pid = self()

      Tesla.Mock.mock(fn
        %{method: :post, url: url, body: body, headers: headers} ->
          send(test_pid, {:posted, url, body, headers})
          %Tesla.Env{status: 202, body: ""}

        _ ->
          %Tesla.Env{status: 404, body: ""}
      end)

      all_enqueued(worker: PublisherWorker)
      |> Enum.filter(
        &(&1.args["op"] == "publish_one" and
            Jason.decode!(&1.args["params"]["json"])["id"] == received["id"])
      )
      |> ObanHelpers.perform()

      for inbox <- [inbox(context.follower), inbox(context.other_follower)] do
        assert_received {:posted, ^inbox, body, headers}
        assert Jason.decode!(body) == received

        # the body's FEP-8b32 proof is the replier's, untouched, so the receiver can trust the reply came from them
        assert IntegrityProofs.verify(Jason.decode!(body)) == {:ok, context.replier_id}

        # the request's HTTP signature, in either format, is our user's: the post's author, who passes it on
        http_signature =
          for {name, value} <- headers, name in ["signature", "signature-input"], do: value

        assert http_signature != []
        assert Enum.any?(http_signature, &String.contains?(&1, context.owner.data["id"]))
        refute Enum.any?(http_signature, &String.contains?(&1, context.replier_id))
      end
    end

    test "a forwarded reply, delivered over the replier's HTTP signature, is stored as vouched for by their proof, and so is its note",
         context do
      received = reply(context, context.post_id)
      assert {:ok, _} = deliver(received)
      assert forwards(received) != %{}

      assert {:ok, %Object{authenticated: :integrity_proof}} =
               Object.get_cached(ap_id: received["id"])

      assert {:ok, %Object{authenticated: :integrity_proof}} =
               Object.get_cached(ap_id: received["object"]["id"])
    end

    test "a reply that is refused is not forwarded", context do
      # an activity of a deactivated actor's is refused when it is stored
      {:ok, replier} = Actor.get_cached(ap_id: context.replier_id)
      Actor.deactivate(replier)

      received = reply(context, context.post_id)
      refute match?({:ok, _}, deliver(received))

      assert forwards(received) == %{}
    end

    test "a reply delivered again is not forwarded again", context do
      received = reply(context, context.post_id)
      assert {:ok, _} = deliver(received)
      first = all_enqueued(worker: PublisherWorker) |> length()

      deliver(received)

      assert length(all_enqueued(worker: PublisherWorker)) == first
    end

    test "each decision is told as a telemetry event, forwarded or not, and why", context do
      test_pid = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:activity_pub, :forwarder, :decided],
        fn event, measurements, metadata, _ ->
          send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # forwarded, to each inbox
      received = reply(context, context.post_id)
      assert {:ok, _} = deliver(received)
      id = received["id"]

      assert_received {[:activity_pub, :forwarder, :decided], %{inboxes: 2},
                       %{
                         activity_id: ^id,
                         activity_type: "Create",
                         decision: {:ok, %{inboxes: inboxes}}
                       }}

      assert inbox(context.follower) in inboxes

      # not forwarded, and why: a reply to a post we do not hold
      elsewhere = reply(context, "https://elsewhere.local/notes/1")
      deliver(elsewhere)
      elsewhere_id = elsewhere["id"]

      assert_received {[:activity_pub, :forwarder, :decided], %{inboxes: 0},
                       %{activity_id: ^elsewhere_id, decision: {:skip, :not_a_reply_we_hold}}}

      # forwarding was decided, but the handling refused it, so it is not forwarded
      {:ok, replier} = Actor.get_cached(ap_id: context.replier_id)
      Actor.deactivate(replier)
      refused = reply(context, context.post_id)
      deliver(refused)
      refused_id = refused["id"]

      assert_received {[:activity_pub, :forwarder, :decided], %{inboxes: 0},
                       %{activity_id: ^refused_id, decision: {:skip, :not_handled}}}
    end

    test "a Delete of a reply is forwarded, though handling it takes the reply away", context do
      received = reply(context, context.post_id)
      assert {:ok, _} = deliver(received)

      delete = signed(context, "Delete", received["object"]["id"])

      assert {:ok, _} = deliver(delete)
      assert inbox(context.follower) in Map.keys(forwards(delete))
    end
  end
end
