defmodule Mojentic.LLM.Tools.CurrentDatetimeTest do
  use ExUnit.Case, async: false

  alias Mojentic.LLM.Tools.CurrentDatetime

  setup do
    Mojentic.TestSupport.Clock.install()
    :ok
  end

  describe "descriptor/0" do
    test "returns valid tool descriptor" do
      descriptor = CurrentDatetime.descriptor()

      assert descriptor.type == "function"
      assert descriptor.function.name == "get_current_datetime"
      assert is_binary(descriptor.function.description)
      assert descriptor.function.description =~ "current date and time"
      assert descriptor.function.parameters.type == "object"
      assert Map.has_key?(descriptor.function.parameters.properties, :format_string)
      assert descriptor.function.parameters.required == []
    end
  end

  describe "run/1" do
    test "returns current datetime with default format" do
      args = %{}

      assert {:ok, result} = CurrentDatetime.run(CurrentDatetime.new(), args)
      assert is_binary(result.current_datetime)
      assert is_integer(result.timestamp)
      assert is_binary(result.timezone)
      # Default format is "%Y-%m-%d %H:%M:%S"
      assert result.current_datetime == "2026-01-01 00:00:00"
    end

    test "returns current datetime with custom format" do
      args = %{"format_string" => "%Y-%m-%d"}

      assert {:ok, result} = CurrentDatetime.run(CurrentDatetime.new(), args)
      assert is_binary(result.current_datetime)
      assert result.current_datetime == "2026-01-01"
      refute result.current_datetime =~ ~r/\d{2}:\d{2}:\d{2}/
    end

    test "returns timestamp as unix epoch" do
      args = %{}

      assert {:ok, result} = CurrentDatetime.run(CurrentDatetime.new(), args)
      assert result.timestamp == 1_767_225_600
      Mojentic.TestSupport.Clock.advance(1000)
      assert {:ok, advanced} = CurrentDatetime.run(CurrentDatetime.new(), args)
      assert advanced.timestamp == result.timestamp + 1
      assert advanced.current_datetime == "2026-01-01 00:00:01"
    end

    test "returns timezone information" do
      args = %{}

      assert {:ok, result} = CurrentDatetime.run(CurrentDatetime.new(), args)
      assert result.timezone == "Etc/UTC"
    end

    test "handles format with day name" do
      args = %{"format_string" => "%A"}

      assert {:ok, result} = CurrentDatetime.run(CurrentDatetime.new(), args)
      assert result.current_datetime == "Thursday"
    end

    test "handles format with month name" do
      args = %{"format_string" => "%B"}

      assert {:ok, result} = CurrentDatetime.run(CurrentDatetime.new(), args)
      assert result.current_datetime == "January"
    end

    test "handles format with year only" do
      args = %{"format_string" => "%Y"}

      assert {:ok, result} = CurrentDatetime.run(CurrentDatetime.new(), args)
      assert result.current_datetime == "2026"
    end

    test "handles invalid format gracefully" do
      args = %{"format_string" => "%invalid%"}

      assert {:ok, result} = CurrentDatetime.run(CurrentDatetime.new(), args)
      # Should still return something (fallback to ISO format)
      assert is_binary(result.current_datetime)
    end

    test "result includes all required fields" do
      args = %{}

      assert {:ok, result} = CurrentDatetime.run(CurrentDatetime.new(), args)
      assert Map.has_key?(result, :current_datetime)
      assert Map.has_key?(result, :timestamp)
      assert Map.has_key?(result, :timezone)
    end
  end
end
