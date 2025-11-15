defmodule Mojentic.LLM.Tools.DateResolverTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Tools.DateResolver

  describe "descriptor/0" do
    test "returns valid tool descriptor" do
      descriptor = DateResolver.descriptor()

      assert descriptor.type == "function"
      assert descriptor.function.name == "resolve_date"
      assert is_binary(descriptor.function.description)
      assert descriptor.function.parameters.type == "object"
      assert Map.has_key?(descriptor.function.parameters.properties, :relative_date_found)
      assert descriptor.function.parameters.required == ["relative_date_found"]
    end
  end

  describe "run/1 - basic relative dates" do
    test "resolves 'today' to current date" do
      args = %{"relative_date_found" => "today", "reference_date_in_iso8601" => "2025-11-10"}

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.relative_date == "today"
      assert result.resolved_date == "2025-11-10"
      assert result.summary =~ "today"
      assert result.summary =~ "2025-11-10"
    end

    test "resolves 'tomorrow'" do
      args = %{"relative_date_found" => "tomorrow", "reference_date_in_iso8601" => "2025-11-10"}

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.relative_date == "tomorrow"
      assert result.resolved_date == "2025-11-11"
    end

    test "resolves 'yesterday'" do
      args = %{"relative_date_found" => "yesterday", "reference_date_in_iso8601" => "2025-11-10"}

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.relative_date == "yesterday"
      assert result.resolved_date == "2025-11-09"
    end

    test "uses today as default reference date" do
      args = %{"relative_date_found" => "today"}

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == Date.to_iso8601(Date.utc_today())
    end
  end

  describe "run/1 - next day of week" do
    test "resolves 'next Monday' from Sunday" do
      # 2025-11-09 is a Sunday
      args = %{
        "relative_date_found" => "next Monday",
        "reference_date_in_iso8601" => "2025-11-09"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-10"
    end

    test "resolves 'next Friday' from Monday" do
      # 2025-11-10 is a Monday
      args = %{
        "relative_date_found" => "next Friday",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-14"
    end

    test "resolves 'next Tuesday'" do
      args = %{
        "relative_date_found" => "next Tuesday",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-11"
    end

    test "resolves 'next Wednesday'" do
      args = %{
        "relative_date_found" => "next Wednesday",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-12"
    end

    test "resolves 'next Thursday'" do
      args = %{
        "relative_date_found" => "next Thursday",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-13"
    end

    test "resolves 'next Saturday'" do
      args = %{
        "relative_date_found" => "next Saturday",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-15"
    end

    test "resolves 'next Sunday'" do
      args = %{
        "relative_date_found" => "next Sunday",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-16"
    end
  end

  describe "run/1 - this day of week" do
    test "resolves 'this Friday' when today is Monday" do
      # 2025-11-10 is a Monday
      args = %{
        "relative_date_found" => "this Friday",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-14"
    end

    test "resolves 'this Friday' when today is Friday" do
      # 2025-11-14 is a Friday
      args = %{
        "relative_date_found" => "this Friday",
        "reference_date_in_iso8601" => "2025-11-14"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-14"
    end
  end

  describe "run/1 - in X days" do
    test "resolves 'in 3 days'" do
      args = %{"relative_date_found" => "in 3 days", "reference_date_in_iso8601" => "2025-11-10"}

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-13"
    end

    test "resolves 'in 1 day'" do
      args = %{"relative_date_found" => "in 1 day", "reference_date_in_iso8601" => "2025-11-10"}

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-11"
    end

    test "resolves 'in 7 days'" do
      args = %{"relative_date_found" => "in 7 days", "reference_date_in_iso8601" => "2025-11-10"}

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-17"
    end

    test "resolves 'in 10 days'" do
      args = %{"relative_date_found" => "in 10 days", "reference_date_in_iso8601" => "2025-11-10"}

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-20"
    end
  end

  describe "run/1 - case insensitivity" do
    test "handles uppercase 'TOMORROW'" do
      args = %{"relative_date_found" => "TOMORROW", "reference_date_in_iso8601" => "2025-11-10"}

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-11"
    end

    test "handles mixed case 'Next Friday'" do
      args = %{
        "relative_date_found" => "Next Friday",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-14"
    end
  end

  describe "run/1 - last day of week" do
    test "resolves 'last Monday'" do
      # 2025-11-14 is Friday, last Monday would be 2025-11-10
      args = %{
        "relative_date_found" => "last Monday",
        "reference_date_in_iso8601" => "2025-11-14"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-10"
    end

    test "resolves 'last Friday'" do
      # 2025-11-10 is Monday, last Friday would be 2025-11-07
      args = %{
        "relative_date_found" => "last Friday",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-07"
    end

    test "resolves 'last Sunday'" do
      args = %{
        "relative_date_found" => "last Sunday",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-09"
    end
  end

  describe "run/1 - weeks and months" do
    test "resolves 'next week'" do
      args = %{
        "relative_date_found" => "next week",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-17"
    end

    test "resolves 'last week'" do
      args = %{
        "relative_date_found" => "last week",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-03"
    end

    test "resolves 'next month'" do
      args = %{
        "relative_date_found" => "next month",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-12-10"
    end

    test "resolves 'last month'" do
      args = %{
        "relative_date_found" => "last month",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-10-11"
    end

    test "resolves 'in 2 weeks'" do
      args = %{
        "relative_date_found" => "in 2 weeks",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-24"
    end

    test "resolves 'in 3 months'" do
      args = %{
        "relative_date_found" => "in 3 months",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      # 3 months * 30 days = 90 days
      assert result.resolved_date == "2026-02-08"
    end

    test "resolves '10 days from now'" do
      args = %{
        "relative_date_found" => "10 days from now",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert result.resolved_date == "2025-11-20"
    end
  end

  describe "run/1 - error handling" do
    test "returns error for unparseable date" do
      args = %{
        "relative_date_found" => "some random text",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:error, :unable_to_parse_date} = DateResolver.run(DateResolver.new(), args)
    end

    test "handles invalid reference date gracefully" do
      args = %{
        "relative_date_found" => "tomorrow",
        "reference_date_in_iso8601" => "invalid-date"
      }

      # Should fall back to today's date
      assert {:ok, result} = DateResolver.run(DateResolver.new(), args)
      assert is_binary(result.resolved_date)
    end

    test "handles nil relative_date" do
      args = %{"reference_date_in_iso8601" => "2025-11-10"}

      assert {:error, :unable_to_parse_date} = DateResolver.run(DateResolver.new(), args)
    end

    test "returns error for unparseable 'last' without day" do
      args = %{
        "relative_date_found" => "last something",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:error, :unable_to_parse_date} = DateResolver.run(DateResolver.new(), args)
    end

    test "returns error for unparseable 'next' without day" do
      args = %{
        "relative_date_found" => "next something",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:error, :unable_to_parse_date} = DateResolver.run(DateResolver.new(), args)
    end

    test "returns error for unparseable 'this' without day" do
      args = %{
        "relative_date_found" => "this something",
        "reference_date_in_iso8601" => "2025-11-10"
      }

      assert {:error, :unable_to_parse_date} = DateResolver.run(DateResolver.new(), args)
    end
  end
end
