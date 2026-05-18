defmodule Mojentic.Realtime.ConfigTest do
  use ExUnit.Case, async: true

  alias Mojentic.Realtime.Config
  alias Mojentic.Realtime.SemanticVadConfig
  alias Mojentic.Realtime.ServerVadConfig

  describe "new/1" do
    test "returns a Config struct with nil fields by default" do
      config = Config.new()

      assert %Config{} = config
      assert is_nil(config.instructions)
      assert is_nil(config.voice)
    end

    test "accepts keyword options" do
      config = Config.new(instructions: "Be brief.", voice: "alloy")

      assert config.instructions == "Be brief."
      assert config.voice == "alloy"
    end

    test "accepts all modality values" do
      config = Config.new(modalities: [:audio, :text])

      assert config.modalities == [:audio, :text]
    end
  end

  describe "defaults/0" do
    test "returns a map with the standard defaults" do
      defaults = Config.defaults()

      assert defaults.modalities == [:audio, :text]
      assert defaults.input_audio_format == :pcm16
      assert defaults.output_audio_format == :pcm16
      assert defaults.turn_detection == :server_vad
      assert defaults.tool_choice == :auto
      assert defaults.on_interrupt == :drop
    end
  end

  describe "ServerVadConfig" do
    test "builds a VAD config struct" do
      vad = %ServerVadConfig{threshold: 0.5, silence_duration_ms: 200}

      assert vad.threshold == 0.5
      assert vad.silence_duration_ms == 200
      assert vad.type == :server_vad
    end
  end

  describe "SemanticVadConfig" do
    test "builds a semantic VAD config struct" do
      vad = %SemanticVadConfig{eagerness: :high}

      assert vad.eagerness == :high
      assert vad.type == :semantic_vad
    end
  end
end
