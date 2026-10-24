# SPDX-License-Identifier: AGPL-3.0-only
#
# The base58btc coding and the LEB128 varint are adapted from `Boruta.Did.Crypto` (MIT, Copyright (c) 2019 patatoid), which does them for did:key. Changes: the `u` header, a decoder that accepts an empty or all-zero body, a strict varint decoder, and the key table.
defmodule ActivityPub.Safety.Multibase do
  @moduledoc """
  The multibase and multicodec encodings that FEP-8b32 and W3C Data Integrity use for keys and signatures.

  Two multibase headers are read, since the two cryptosuites disagree about the alphabet:

    * `z`, base58btc: Ed25519 keys (`z6Mk…`) and the `proofValue` of `eddsa-jcs-2022`
    * `u`, base64url without padding: ML-DSA-44 keys and the `proofValue` of `mldsa44-jcs-2024`

  A value is read by its header, not by what the caller expects, so a document is read with whatever its signer used. Every other multibase header is refused by name rather than guessed at.

  A Multikey (`publicKeyMultibase`) is the multibase text of a multicodec varint followed by the raw public key. `decode_multikey/1` reads the two key types we verify with.
  """

  import Bitwise

  @base58_alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @base58_indexes @base58_alphabet |> Enum.with_index() |> Map.new()
  @base58_chars List.to_tuple(@base58_alphabet)

  # multicodec code => {key type, public key size in bytes}
  #   0xED   ed25519-pub    https://github.com/multiformats/multicodec/blob/master/table.csv
  #   0x1210 mldsa-44-pub   (draft entry in the same table)
  @key_types %{
    0xED => {:ed25519, 32},
    0x1210 => {:mldsa44, 1312}
  }

  @type encoding :: :base58btc | :base64url
  @type key_type :: :ed25519 | :mldsa44

  @doc """
  Decodes a multibase string into bytes, by its header.

      iex> ActivityPub.Safety.Multibase.decode("z7paNL19xttacUY")
      {:ok, "yes mani !"}

      iex> ActivityPub.Safety.Multibase.decode("uAQ")
      {:ok, <<1>>}

      iex> ActivityPub.Safety.Multibase.decode("f6869")
      {:error, :unsupported_multibase}
  """
  @spec decode(term()) ::
          {:ok, binary()}
          | {:error, :unsupported_multibase | :invalid_base58 | :invalid_base64url}
  def decode("z" <> body), do: base58btc_decode(body)

  def decode("u" <> body) do
    case Base.url_decode64(body, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_base64url}
    end
  end

  def decode(_), do: {:error, :unsupported_multibase}

  @doc """
  Encodes bytes as a multibase string, with the `z` header for `:base58btc` or the `u` header (no padding) for `:base64url`.

      iex> ActivityPub.Safety.Multibase.encode("yes mani !", :base58btc)
      "z7paNL19xttacUY"

      iex> ActivityPub.Safety.Multibase.encode(<<1>>, :base64url)
      "uAQ"
  """
  @spec encode(binary(), encoding()) :: String.t()
  def encode(bytes, :base58btc) when is_binary(bytes), do: "z" <> base58btc_encode(bytes)

  def encode(bytes, :base64url) when is_binary(bytes),
    do: "u" <> Base.url_encode64(bytes, padding: false)

  @doc """
  Reads a Multikey `publicKeyMultibase` value into its key type and raw public key.

  Fails with `:unsupported_multibase` (a header other than `z` or `u`), `:unsupported_key_type` (a multicodec we do not verify with), `:bad_key_length` (the size is wrong for that type), or `:invalid_varint`.
  """
  @spec decode_multikey(term()) :: {:ok, {key_type(), binary()}} | {:error, atom()}
  def decode_multikey(multibase) do
    with {:ok, bytes} <- decode(multibase),
         {:ok, code, key} <- decode_varint(bytes) do
      case @key_types[code] do
        nil -> {:error, :unsupported_key_type}
        {type, size} when byte_size(key) == size -> {:ok, {type, key}}
        _wrong_size -> {:error, :bad_key_length}
      end
    end
  end

  @doc """
  The multicodec varint (unsigned LEB128) of a code.

      iex> ActivityPub.Safety.Multibase.encode_varint(0xED)
      <<0xED, 0x01>>

      iex> ActivityPub.Safety.Multibase.encode_varint(0x1210)
      <<0x90, 0x24>>
  """
  @spec encode_varint(non_neg_integer()) :: binary()
  def encode_varint(value) when is_integer(value) and value >= 0 and value < 0x80, do: <<value>>

  def encode_varint(value) when is_integer(value) and value >= 0,
    do: <<(value &&& 0x7F) ||| 0x80>> <> encode_varint(value >>> 7)

  @doc """
  Reads a varint from the front of some bytes, returning the code and the rest. Strict: a varint of more than nine bytes, or one padded with a trailing zero byte (a second way of writing the same number), is refused.
  """
  @spec decode_varint(binary()) :: {:ok, non_neg_integer(), binary()} | {:error, :invalid_varint}
  def decode_varint(bytes) when is_binary(bytes), do: decode_varint(bytes, 0, 0)

  def decode_varint(_), do: {:error, :invalid_varint}

  defp decode_varint(<<>>, _value, _shift), do: {:error, :invalid_varint}

  defp decode_varint(<<byte, rest::binary>>, value, shift) when shift <= 56 do
    value = value ||| (byte &&& 0x7F) <<< shift

    cond do
      (byte &&& 0x80) != 0 -> decode_varint(rest, value, shift + 7)
      byte == 0 and shift > 0 -> {:error, :invalid_varint}
      true -> {:ok, value, rest}
    end
  end

  defp decode_varint(_bytes, _value, _shift), do: {:error, :invalid_varint}

  # base58btc, Bitcoin alphabet. Each leading zero byte is written as a leading '1' and read back as one, so `<<>>` is "" and `<<0>>` is "1".
  defp base58btc_decode(body) do
    {ones, digits} = body |> :binary.bin_to_list() |> Enum.split_while(&(&1 == ?1))

    digits
    |> Enum.reduce_while(0, fn char, integer ->
      case @base58_indexes[char] do
        nil -> {:halt, :error}
        value -> {:cont, integer * 58 + value}
      end
    end)
    |> case do
      :error ->
        {:error, :invalid_base58}

      0 ->
        {:ok, :binary.copy(<<0>>, length(ones))}

      integer ->
        {:ok, :binary.copy(<<0>>, length(ones)) <> :binary.encode_unsigned(integer)}
    end
  end

  defp base58btc_encode(bytes) do
    {zeros, rest} = split_leading_zeros(bytes, 0)

    digits =
      if rest == <<>>,
        do: "",
        else: rest |> :binary.decode_unsigned() |> base58_digits([]) |> List.to_string()

    :binary.copy("1", zeros) <> digits
  end

  defp base58_digits(0, digits), do: digits

  defp base58_digits(integer, digits),
    do: base58_digits(div(integer, 58), [elem(@base58_chars, rem(integer, 58)) | digits])

  defp split_leading_zeros(<<0, rest::binary>>, count), do: split_leading_zeros(rest, count + 1)
  defp split_leading_zeros(bytes, count), do: {count, bytes}
end
