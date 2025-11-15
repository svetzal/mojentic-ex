defmodule Mojentic.LLM.Tools.CurrentDatetimeTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Tools.CurrentDatetime

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

      assert {:ok, result} = CurrentDatetime.run(args)
      assert is_binary(result.current_datetime)
      assert is_integer(result.timestamp)
      assert is_binary(result.timezone)
      # Default format is "%Y-%m-%d %H:%M:%S"
      assert result.current_datetime =~ ~r/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/
    end

    test "returns current datetime with custom format" do
      args = %{"format_string" => "%Y-%m-%d"}

      assert {:ok, result} = CurrentDatetime.run(args)
      assert is_binary(result.current_datetime)
      assert result.current_datetime =~ ~r/\d{4}-\d{2}-\d{2}/
      refute result.current_datetime =~ ~r/\d{2}:\d{2}:\d{2}/
    end

    test "returns timestamp as unix epoch" do
      args = %{}

      assert {:ok, result} = CurrentDatetime.run(args)
      # Timestamp should be a reasonable unix epoch (after 2020, before 2030)
      assert result.timestamp > 1_577_836_800
      assert result.timestamp < 1_893_456_000
    end

    test "returns timezone information" do
      args = %{}

      assert {:ok, result} = CurrentDatetime.run(args)
      assert result.timezone == "Etc/UTC"
    end

    test "handles format with day name" do
      args = %{"format_string" => "%A"}

      assert {:ok, result} = CurrentDatetime.run(args)
      # Should be a day name
      assert result.current_datetime in [
               "Monday",
               "Tuesday",
               "Wednesday",
               "Thursday",
               "Friday",
               "Saturday",
               "Sunday"
             ]
    end

    test "handles format with month name" do
      args = %{"format_string" => "%B"}

      assert {:ok, result} = CurrentDatetime.run(args)
      # Should be a month name
      assert result.current_datetime in [
               "January",
               "February",
               "March",
               "April",
               "May",
               "June",
               "July",
               "August",
               "September",
               "October",
               "November",
               "December"
             ]
    end

    test "handles format with year only" do
      args = %{"format_string" => "%Y"}

      assert {:ok, result} = CurrentDatetime.run(args)
      # Should be a 4-digit year
      assert result.current_datetime =~ ~r/^\d{4}$/
    end

    test "handles invalid format gracefully" do
      args = %{"format_string" => "%invalid%"}

      assert {:ok, result} = CurrentDatetime.run(args)
      # Should still return something (fallback to ISO format)
      assert is_binary(result.current_datetime)
    end

    test "result includes all required fields" do
      args = %{}

      assert {:ok, result} = CurrentDatetime.run(args)
      assert Map.has_key?(result, :current_datetime)
      assert Map.has_key?(result, :timestamp)
      assert Map.has_key?(result, :timezone)
    end
  end
end
