# SPDX-License-Identifier: MIT
#
# Vendored from the `hkdf` package, version 0.3.0:
# https://github.com/jschneider1207/hkdf/blob/a26a0c34ccdedf1ba53931978430162eb30ec6a6/lib/hkdf.ex
#
# Changes: the module is `ActivityPub.Safety.HKDF`; the table of hash lengths is written out instead of being worked out while compiling, because the package does that by hashing with every algorithm it knows, MD4 included, and OpenSSL 3 (OTP 29) does not support MD4, so it does not compile there; MD4 is left out; the reference in the moduledoc says RFC 5869, not 5859.
#
# MIT License
#
# Copyright (c) 2017 sschneider1207
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
defmodule ActivityPub.Safety.HKDF do
  @moduledoc """
  Provides a simple Hashed Message Authentication Code (HMAC)-based
  key derivation function (HKDF).

  ## Process

  Keys are derived in two steps:

    1. Extract - a pseudorandom key is extracted from an input key material and optional salt.
    2. Expand - an output key material of a specific length is expanded from hashes of the pseudorandom key and an optional info message.

  ## Source

  Defined in [RFC 5869](https://tools.ietf.org/html/rfc5869). OTP's `:crypto` has no HKDF. Tested against the RFC's own test vectors.
  """
  @type hash_fun :: sha1() | sha2() | sha3() | compatibility_only_hash()
  @type sha1 :: :sha
  @type sha2 :: :sha224 | :sha256 | :sha384 | :sha512
  @type sha3 :: :sha3_224 | :sha3_256 | :sha3_384 | :sha3_512
  @typedoc "The `compatibility_only_hash/0` algorithms are recommended only for compatibility with existing applications."
  @type compatibility_only_hash :: :md5
  @type input_key_material :: binary()
  @type salt :: binary()
  @type pseudorandom_key :: binary()
  @type length :: non_neg_integer()
  @type info :: binary()
  @type output_key_material :: binary()

  @doc """
  Derives a key of a specific length using the specified hash function.

  An optional salt (extract phase) and/or info message (expand phase)
  can be supplied.

  ## Example

      iex> ActivityPub.Safety.HKDF.derive(:sha256, "some input", 16)
      <<47, 231, 129, 75, 82, 47, 198, 78, 55, 31, 167, 66, 15, 128, 63, 243>>

      iex> ActivityPub.Safety.HKDF.derive(:sha256, "some input", 16, "salt", "secret message")
      <<28, 213, 201, 204, 16, 226, 160, 120, 69, 47, 46, 58, 15, 255, 54, 52>>

  """
  @spec derive(hash_fun, input_key_material, length, salt, info) :: output_key_material
  def derive(hash_fun, ikm, len, salt \\ "", info \\ "") do
    prk = extract(hash_fun, ikm, salt)
    expand(hash_fun, prk, len, info)
  end

  @doc """
  Extract a psuedorandom key from an input key material.

  ## Example

      iex> ActivityPub.Safety.HKDF.extract(:sha256, "some input")
      <<130, 6, 35, 29, 160, 13, 100, 90, 127, 71, 104, 2, 139, 88, 204, 124, 201,
        141, 22, 223, 95, 189, 60, 4, 147, 6, 19, 196, 66, 139, 65, 153>>

      iex> ActivityPub.Safety.HKDF.extract(:sha256, "some input", "salt")
      <<165, 68, 136, 223, 19, 149, 73, 161, 172, 133, 175, 129, 14, 46, 132, 27, 219,
        137, 155, 191, 199, 9, 251, 100, 155, 173, 33, 97, 201, 250, 19, 92>>

  """
  @spec extract(hash_fun, input_key_material, salt) :: pseudorandom_key
  def extract(hash_fun, ikm, salt \\ "") do
    :crypto.mac(:hmac, hash_fun, salt, ikm)
  end

  @doc """
  Expands a pseudorandom key to an output key material of a defined length.

  ## Example

      iex(1)> prk = ActivityPub.Safety.HKDF.extract(:sha256, "some input", "salt")
      iex(2)> ActivityPub.Safety.HKDF.expand(:sha256, prk, 16)
      <<227, 13, 8, 99, 198, 12, 203, 171, 124, 253, 132, 131, 59, 202, 95, 24>>

      iex(1)> prk = ActivityPub.Safety.HKDF.extract(:sha256, "some input", "salt")
      iex(2)> ActivityPub.Safety.HKDF.expand(:sha256, prk, 16, "secret message")
      <<28, 213, 201, 204, 16, 226, 160, 120, 69, 47, 46, 58, 15, 255, 54, 52>>

  """
  @spec expand(hash_fun, pseudorandom_key, length, info) :: output_key_material
  def expand(hash_fun, prk, len, info \\ "") do
    hash_len = hash_length(hash_fun)
    n = Float.ceil(len / hash_len) |> round()

    full =
      Enum.scan(1..n, "", fn index, prev ->
        data = prev <> info <> <<index>>
        :crypto.mac(:hmac, hash_fun, prk, data)
      end)
      |> Enum.reduce("", &Kernel.<>(&2, &1))

    <<output::unit(8)-size(len), _::binary>> = full
    <<output::unit(8)-size(len)>>
  end

  # output sizes in bytes
  defp hash_length(:md5), do: 16
  defp hash_length(:sha), do: 20
  defp hash_length(:sha224), do: 28
  defp hash_length(:sha256), do: 32
  defp hash_length(:sha384), do: 48
  defp hash_length(:sha512), do: 64
  defp hash_length(:sha3_224), do: 28
  defp hash_length(:sha3_256), do: 32
  defp hash_length(:sha3_384), do: 48
  defp hash_length(:sha3_512), do: 64
end
