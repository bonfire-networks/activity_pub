defmodule ActivityPub.Test.IntegrityProofFixtures do
  @moduledoc """
  The documents behind the FEP-8b32 tests, read from `test/fixtures/`, one file per document.

    * `vector(name)`: a published test vector from `test/fixtures/integrity_proofs/<name>/`. `vector.json` holds what is not a document (keys, the hashes and signature the spec lists) and the documents beside it are added under fixed keys: `unsigned.json` or `credential.json` as `"document"`, `signed.json` as `"signedDocument"`, `actor.json` as `"actor"`, `proof_options.json` as `"proofOptions"`.
    * `mitra(name)`: a document from `test/fixtures/mitra/`, as Mitra's server sent or served it (`"actor"`, `"create"`, `"follow"`, `"undo"`).
  """

  @fixtures Path.expand("../fixtures", __DIR__)

  @vectors [:fep_8b32, :vc_di_eddsa_jcs_2022, :vc_di_mldsa44_jcs_2024]

  # file in a vector's folder => its key in the map `vector/1` returns
  @documents %{
    "unsigned.json" => "document",
    "credential.json" => "document",
    "signed.json" => "signedDocument",
    "actor.json" => "actor",
    "proof_options.json" => "proofOptions"
  }

  @spec vector(atom()) :: map()
  def vector(name) when name in @vectors do
    dir = Path.join([@fixtures, "integrity_proofs", to_string(name)])
    vector = dir |> Path.join("vector.json") |> read!()

    @documents
    |> Enum.filter(fn {file, _key} -> File.exists?(Path.join(dir, file)) end)
    |> Enum.reduce(vector, fn {file, key}, acc ->
      Map.put(acc, key, dir |> Path.join(file) |> read!())
    end)
    |> name_the_did_key()
  end

  @spec mitra(String.t()) :: map()
  def mitra(name) when name in ["actor", "create", "follow", "undo"],
    do: [@fixtures, "mitra", name <> ".json"] |> Path.join() |> read!()

  # the ML-DSA draft names its verification method as the did:key of the public key, which is long, so the proof options file says so instead of repeating it
  defp name_the_did_key(%{"proofOptions" => %{"verificationMethod" => "did:key:<" <> _}} = vector) do
    put_in(
      vector,
      ["proofOptions", "verificationMethod"],
      "did:key:" <> vector["publicKeyMultibase"]
    )
  end

  defp name_the_did_key(vector), do: vector

  defp read!(path), do: path |> File.read!() |> Jason.decode!()
end
