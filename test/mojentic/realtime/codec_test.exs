defmodule Mojentic.Realtime.CodecTest do
  use ExUnit.Case, async: true

  alias Mojentic.Realtime.Codec

  describe "PCM16 round-trip" do
    test "encodes and decodes a binary frame" do
      samples =
        <<0::little-16-signed, 1::little-16-signed, -1::little-16-signed,
          32_767::little-16-signed, -32_768::little-16-signed>>

      encoded = Codec.encode_base64_pcm16(samples)
      decoded = Codec.decode_base64_pcm16(encoded)

      assert decoded == samples
    end

    test "encodes a list of int16 samples" do
      list = [0, 1, -1, 100, -100]

      encoded = Codec.encode_base64_pcm16(list)
      decoded = Codec.decode_base64_pcm16(encoded)

      assert decoded ==
               <<0::little-16-signed, 1::little-16-signed, -1::little-16-signed,
                 100::little-16-signed, -100::little-16-signed>>
    end
  end
end
