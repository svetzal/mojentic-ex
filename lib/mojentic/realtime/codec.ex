defmodule Mojentic.Realtime.Codec do
  @moduledoc """
  Audio codec helpers for the realtime subsystem.

  Realtime sends and receives audio as base64-encoded PCM16
  (little-endian 16-bit signed mono, 24 kHz by default). These helpers
  convert between the wire format and Elixir binaries of raw PCM bytes
  so consumer code never touches base64.
  """

  @doc """
  Decode a base64 string into a binary of little-endian 16-bit PCM samples.

  Returns the raw binary; pattern-match `<<sample::little-16-signed, rest::binary>>`
  to consume samples or use `:binary.bin_to_list/2` for arrays.
  """
  def decode_base64_pcm16(b64) when is_binary(b64) do
    Base.decode64!(b64)
  end

  @doc """
  Encode raw PCM16 bytes (or a list of int16 samples) into a base64 string.
  """
  def encode_base64_pcm16(samples) when is_binary(samples) do
    Base.encode64(samples)
  end

  def encode_base64_pcm16(samples) when is_list(samples) do
    samples
    |> Enum.map(fn s -> <<s::little-16-signed>> end)
    |> IO.iodata_to_binary()
    |> Base.encode64()
  end
end
