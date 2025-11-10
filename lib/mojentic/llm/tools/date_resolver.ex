defmodule Mojentic.LLM.Tools.DateResolver do
  @moduledoc """
  Tool for resolving relative dates to absolute dates.

  This tool can parse relative date references like "tomorrow",
  "next Friday", "in 3 days", etc., and convert them to absolute
  ISO 8601 dates.

  ## Examples

      alias Mojentic.LLM.Tools.DateResolver

      {:ok, result} = DateResolver.run(%{
        "relative_date_found" => "tomorrow"
      })
      # => {:ok, %{relative_date: "tomorrow", resolved_date: "2025-11-11", ...}}

  """

  @behaviour Mojentic.LLM.Tools.Tool

  @impl true
  def run(arguments) do
    relative_date = Map.get(arguments, "relative_date_found")
    reference_date_str = Map.get(arguments, "reference_date_in_iso8601")

    reference_date =
      if reference_date_str do
        case Date.from_iso8601(reference_date_str) do
          {:ok, date} -> date
          _ -> Date.utc_today()
        end
      else
        Date.utc_today()
      end

    case parse_relative_date(relative_date, reference_date) do
      {:ok, resolved_date} ->
        {:ok,
         %{
           relative_date: relative_date,
           resolved_date: Date.to_iso8601(resolved_date),
           summary: "The date on '#{relative_date}' is #{Date.to_iso8601(resolved_date)}"
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "resolve_date",
        description: "Take text that specifies a relative date, and output an absolute date",
        parameters: %{
          type: "object",
          properties: %{
            relative_date_found: %{
              type: "string",
              description: "The text referencing a relative date"
            },
            reference_date_in_iso8601: %{
              type: "string",
              description: "The reference date in YYYY-MM-DD format (optional, defaults to today)"
            }
          },
          required: ["relative_date_found"]
        }
      }
    }
  end

  # Private helper to parse relative dates
  defp parse_relative_date(text, reference_date) do
    text_lower = String.downcase(text || "")

    cond do
      String.contains?(text_lower, "today") ->
        {:ok, reference_date}

      String.contains?(text_lower, "tomorrow") ->
        {:ok, Date.add(reference_date, 1)}

      String.contains?(text_lower, "yesterday") ->
        {:ok, Date.add(reference_date, -1)}

      # Match "next <day of week>"
      String.contains?(text_lower, "next") and String.contains?(text_lower, "monday") ->
        {:ok, next_day_of_week(reference_date, 1)}

      String.contains?(text_lower, "next") and String.contains?(text_lower, "tuesday") ->
        {:ok, next_day_of_week(reference_date, 2)}

      String.contains?(text_lower, "next") and String.contains?(text_lower, "wednesday") ->
        {:ok, next_day_of_week(reference_date, 3)}

      String.contains?(text_lower, "next") and String.contains?(text_lower, "thursday") ->
        {:ok, next_day_of_week(reference_date, 4)}

      String.contains?(text_lower, "next") and String.contains?(text_lower, "friday") ->
        {:ok, next_day_of_week(reference_date, 5)}

      String.contains?(text_lower, "next") and String.contains?(text_lower, "saturday") ->
        {:ok, next_day_of_week(reference_date, 6)}

      String.contains?(text_lower, "next") and String.contains?(text_lower, "sunday") ->
        {:ok, next_day_of_week(reference_date, 7)}

      # Match "this <day of week>"
      String.contains?(text_lower, "this") and String.contains?(text_lower, "friday") ->
        {:ok, this_day_of_week(reference_date, 5)}

      # Match "in X days"
      true ->
        case Regex.run(~r/in (\d+) days?/, text_lower) do
          [_, days_str] ->
            days = String.to_integer(days_str)
            {:ok, Date.add(reference_date, days)}

          _ ->
            {:error, :unable_to_parse_date}
        end
    end
  end

  defp next_day_of_week(reference_date, target_day) do
    current_day = Date.day_of_week(reference_date)
    days_until = rem(target_day - current_day + 7, 7)
    days_until = if days_until == 0, do: 7, else: days_until
    Date.add(reference_date, days_until)
  end

  defp this_day_of_week(reference_date, target_day) do
    current_day = Date.day_of_week(reference_date)

    if current_day == target_day do
      reference_date
    else
      days_until = rem(target_day - current_day + 7, 7)
      Date.add(reference_date, days_until)
    end
  end
end
