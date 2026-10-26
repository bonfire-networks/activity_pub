defmodule ActivityPub.Federator.ProofAtReceiptTest do
  @moduledoc """
  A proof (FEP-8b32) or LD signature on a delivery is checked when it arrives, so what we store says how it was vouched for: "Recipients of an object SHOULD perform proof verification if it contains integrity proofs."

  One that holds marks the activity `:integrity_proof`, though an HTTP signature came with it. One we cannot check (a key we cannot find, a cryptosuite we do not support) counts as none, as the FEP says. One that fails is evidence against the document, and what is done then is `config :activity_pub, :incoming_signatures`:

    * with a valid HTTP signature, `partly_invalid:` `:accept` (the default, on the HTTP signature), `:refetch` (the origin's copy instead) or `:reject`
    * without one, once its origin serves nothing either, it is accepted anyway only with `invalid: :accept`, never with `unsigned: :accept`, which is for what nobody signed
  """
  use ActivityPub.DataCase, async: false

  import ActivityPub.Factory
  import ActivityPub.Test.IntegrityProofHelpers
  import Tesla.Mock

  alias ActivityPub.Object
  alias ActivityPub.Federator.Worker.ReceiverHelpers

  setup do
    key = new_key(:ed25519)
    actor_id = "https://signer-#{System.unique_integer([:positive])}.example/users/alice"
    actor(ap_id: actor_id, data: %{"assertionMethod" => [multikey(actor_id, key)]})

    %{key: key, actor_id: actor_id}
  end

  defp signed_create(%{key: key, actor_id: actor_id}, opts \\ []),
    do: actor_id |> create_note() |> sign(key, opts)

  # the content changed after it was signed, so its proof does not hold
  defp broken_create(context),
    do: context |> signed_create() |> put_in(["object", "content"], "<p>changed</p>")

  # over its actor's verified HTTP signature, as the receiver worker gets it
  defp delivered(document) do
    ReceiverHelpers.perform(
      %Oban.Job{
        args: %{
          "op" => "incoming_ap_doc",
          "params" => document,
          "signed_by" => document["actor"],
          "repo" => ActivityPub.Utils.repo()
        }
      },
      :verified
    )
  end

  # with no HTTP signature that holds
  defp delivered_unsigned(document) do
    ReceiverHelpers.perform(
      %Oban.Job{
        args: %{
          "op" => "incoming_unverified_ap_doc",
          "params" => document,
          "headers" => %{},
          "repo" => ActivityPub.Utils.repo()
        }
      },
      :unverified
    )
  end

  defp stored(document) do
    case Object.get_cached(ap_id: document["id"]) do
      {:ok, %Object{authenticated: authenticated}} -> authenticated
      _ -> :not_stored
    end
  end

  # `config :activity_pub, :incoming_signatures`, with `set` merged over it while `fun` runs
  defp with_incoming_signatures(set, fun) do
    previous = Application.get_env(:activity_pub, :incoming_signatures)
    Application.put_env(:activity_pub, :incoming_signatures, Keyword.merge(previous || [], set))

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:activity_pub, :incoming_signatures, previous),
        else: Application.delete_env(:activity_pub, :incoming_signatures)
    end
  end

  defp with_partly_invalid(value, fun),
    do: with_incoming_signatures([partly_invalid: value], fun)

  # the origin serves nothing: no copy of its own to trust instead
  defp origin_answers_404, do: mock(fn _ -> %Tesla.Env{status: 404, body: ""} end)

  describe "over an HTTP signature" do
    test "a proof that holds marks the activity as vouched for by it", context do
      create = signed_create(context)
      assert {:ok, _} = delivered(create)

      assert stored(create) == :integrity_proof
    end

    test "with no proof, it is the HTTP signature's", context do
      create = context.actor_id |> create_note()
      assert {:ok, _} = delivered(create)

      assert stored(create) == :http_signature
    end

    test "a proof we cannot check counts as none", context do
      origin_answers_404()
      create = signed_create(context, verification_method: context.actor_id <> "#no-such-key")
      assert {:ok, _} = delivered(create)

      assert stored(create) == :http_signature
    end

    test "a proof that fails is accepted on the HTTP signature by default", context do
      origin_answers_404()
      create = broken_create(context)
      assert {:ok, _} = delivered(create)

      assert stored(create) == :http_signature
    end

    test "a proof that fails, with `partly_invalid: :refetch`, is not taken on the HTTP signature: nothing is stored when the origin serves nothing",
         context do
      origin_answers_404()
      create = broken_create(context)

      with_partly_invalid(:refetch, fn ->
        refute match?({:ok, _}, delivered(create))
      end)

      assert stored(create) == :not_stored
    end

    test "a proof that fails, with `partly_invalid: :reject`, is refused", context do
      origin_answers_404()
      create = broken_create(context)

      with_partly_invalid(:reject, fn ->
        refute match?({:ok, _}, delivered(create))
      end)

      assert stored(create) == :not_stored
    end
  end

  describe "with no HTTP signature, and an origin that serves nothing" do
    setup do
      origin_answers_404()
      :ok
    end

    test "a proof that fails is not accepted anyway with `unsigned: :accept`, which is for what nobody signed",
         context do
      create = broken_create(context)

      with_incoming_signatures([unsigned: :accept], fn ->
        refute match?({:ok, _}, delivered_unsigned(create))
      end)

      assert stored(create) == :not_stored
    end

    test "a proof that fails is accepted anyway with `invalid: :accept`", context do
      create = broken_create(context)

      with_incoming_signatures([invalid: :accept], fn ->
        assert {:ok, _} = delivered_unsigned(create)
      end)

      refute stored(create) == :not_stored
    end

    test "a proof we cannot check counts as none, so `unsigned: :accept` accepts it anyway",
         context do
      create = signed_create(context, verification_method: context.actor_id <> "#no-such-key")

      with_incoming_signatures([unsigned: :accept], fn ->
        assert {:ok, _} = delivered_unsigned(create)
      end)

      refute stored(create) == :not_stored
    end

    test "nothing signed it: refused by default", context do
      create = context.actor_id |> create_note()
      refute match?({:ok, _}, delivered_unsigned(create))

      assert stored(create) == :not_stored
    end
  end
end
