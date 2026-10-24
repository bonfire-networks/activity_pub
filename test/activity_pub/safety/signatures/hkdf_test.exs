defmodule ActivityPub.Safety.HKDFTest do
  @moduledoc """
  HKDF with SHA-256 (RFC 5869), vendored from the `hkdf` package, as we use it to derive an actor's Ed25519 key, checked against the test vectors in the RFC's appendix A. OTP's `:crypto` has no HKDF.
  """
  use ExUnit.Case, async: true

  alias ActivityPub.Safety.HKDF

  defp hex(string), do: string |> String.replace(~r/\s/, "") |> Base.decode16!(case: :lower)

  # A.1, basic test case
  test "reproduces the RFC 5869 test case 1" do
    ikm = hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
    salt = hex("000102030405060708090a0b0c")
    info = hex("f0f1f2f3f4f5f6f7f8f9")

    assert HKDF.derive(:sha256, ikm, 42, salt, info) ==
             hex("""
             3cb25f25faacd57a90434f64d0362f2a
             2d2d0a90cf1a5a4c5db02d56ecc4c5bf
             34007208d5b887185865
             """)
  end

  # A.2, longer inputs and output (more than two blocks of output)
  test "reproduces the RFC 5869 test case 2" do
    ikm = for(i <- 0x00..0x4F, into: <<>>, do: <<i>>)
    salt = for(i <- 0x60..0xAF, into: <<>>, do: <<i>>)
    info = for(i <- 0xB0..0xFF, into: <<>>, do: <<i>>)

    assert HKDF.derive(:sha256, ikm, 82, salt, info) ==
             hex("""
             b11e398dc80327a1c8e7f78c596a4934
             4f012eda2d4efad8a050cc4c19afa97c
             59045a99cac7827271cb41c65e590e09
             da3275600c2f09b8367793a9aca3db71
             cc30c58179ec3e87c14c01d5c1f3434f
             1d87
             """)
  end

  # A.3, zero-length salt and info, which is how the actor's Ed25519 seed is derived (no salt)
  test "reproduces the RFC 5869 test case 3, with no salt and no info" do
    ikm = hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")

    assert HKDF.derive(:sha256, ikm, 42, "", "") ==
             hex("""
             8da4e775a563c18f715f802a063c5a31
             b8a11f5c5ee1879ec3454e5f3c738d2d
             9d201395faa4b61a96c8
             """)
  end

  test "gives the length asked for, and a different key for a different info" do
    ikm = :crypto.strong_rand_bytes(32)

    assert byte_size(HKDF.derive(:sha256, ikm, 32, "", "a")) == 32
    assert byte_size(HKDF.derive(:sha256, ikm, 7, "", "a")) == 7
    refute HKDF.derive(:sha256, ikm, 32, "", "a") == HKDF.derive(:sha256, ikm, 32, "", "b")
  end
end
