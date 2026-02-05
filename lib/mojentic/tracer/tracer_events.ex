defmodule Mojentic.Tracer.TracerEvents do
  @moduledoc """
  Defines tracer event types for tracking system interactions.

  Tracer events are used to track system interactions for observability purposes.
  They are distinct from regular events which are used for agent communication.

  All tracer events include:
  - `timestamp`: Unix timestamp (seconds since epoch) when the event occurred
  - `correlation_id`: UUID string copied from cause-to-effect for tracing events
  - `source`: Module or component that generated the event

  Each event type provides a `printable_summary/1` function that returns a formatted
  string representation of the event for debugging and observability.
  """

  # Helper function to format timestamps - must be public for child modules
  def format_timestamp(timestamp) do
    # Convert float timestamp (seconds) to integer milliseconds
    timestamp_ms = trunc(timestamp * 1000)

    dt = DateTime.from_unix!(timestamp_ms, :millisecond)
    time_str = Calendar.strftime(dt, "%H:%M:%S")
    ms = rem(timestamp_ms, 1000)
    ms_str = String.pad_leading(Integer.to_string(ms), 3, "0")
    "#{time_str}.#{ms_str}"
  end

  # Helper function to format base summary for all event types - must be public for child modules
  def format_base_summary(event, event_type_name) do
    event_time = format_timestamp(event.timestamp)
    "[#{event_time}] #{event_type_name} (correlation_id: #{event.correlation_id})"
  end
end

defmodule Mojentic.Tracer.TracerEvents.TracerEvent do
  @moduledoc """
  Base structure for all tracer events.
  """

  defstruct [:timestamp, :correlation_id, :source]

  def printable_summary(%__MODULE__{} = event) do
    Mojentic.Tracer.TracerEvents.format_base_summary(event, "TracerEvent")
  end
end

defmodule Mojentic.Tracer.TracerEvents.LLMCallTracerEvent do
  @moduledoc """
  Records when an LLM is called with specific messages.
  """

  defstruct [:timestamp, :correlation_id, :source, :model, :messages, :temperature, :tools]

  def printable_summary(%__MODULE__{} = event) do
    base_summary = Mojentic.Tracer.TracerEvents.format_base_summary(event, "LLMCallTracerEvent")
    summary = "#{base_summary}\n   Model: #{event.model}"

    summary =
      if event.messages != [] do
        msg_count = length(event.messages)
        pluralized = if msg_count == 1, do: "", else: "s"
        "#{summary}\n   Messages: #{msg_count} message#{pluralized}"
      else
        summary
      end

    summary =
      if event.temperature != 1.0 do
        "#{summary}\n   Temperature: #{event.temperature}"
      else
        summary
      end

    if event.tools && event.tools != [] do
      tool_names = Enum.map(event.tools, fn tool -> Map.get(tool, "name", "unknown") end)
      "#{summary}\n   Available Tools: #{Enum.join(tool_names, ", ")}"
    else
      summary
    end
  end
end

defmodule Mojentic.Tracer.TracerEvents.LLMResponseTracerEvent do
  @moduledoc """
  Records when an LLM responds to a call.
  """

  defstruct [
    :timestamp,
    :correlation_id,
    :source,
    :model,
    :content,
    :tool_calls,
    :call_duration_ms
  ]

  def printable_summary(%__MODULE__{} = event) do
    base_summary =
      Mojentic.Tracer.TracerEvents.format_base_summary(event, "LLMResponseTracerEvent")

    summary = "#{base_summary}\n   Model: #{event.model}"

    summary =
      if event.content && String.length(event.content) > 0 do
        content_preview =
          if String.length(event.content) > 100 do
            String.slice(event.content, 0..99) <> "..."
          else
            event.content
          end

        "#{summary}\n   Content: #{content_preview}"
      else
        summary
      end

    summary =
      if event.tool_calls && event.tool_calls != [] do
        tool_count = length(event.tool_calls)
        pluralized = if tool_count == 1, do: "", else: "s"
        "#{summary}\n   Tool Calls: #{tool_count} call#{pluralized}"
      else
        summary
      end

    if event.call_duration_ms do
      "#{summary}\n   Duration: #{Float.round(event.call_duration_ms, 2)}ms"
    else
      summary
    end
  end
end

defmodule Mojentic.Tracer.TracerEvents.ToolCallTracerEvent do
  @moduledoc """
  Records when a tool is called during agent execution.
  """

  defstruct [
    :timestamp,
    :correlation_id,
    :source,
    :tool_name,
    :arguments,
    :result,
    :caller,
    :call_duration_ms
  ]

  def printable_summary(%__MODULE__{} = event) do
    base_summary = Mojentic.Tracer.TracerEvents.format_base_summary(event, "ToolCallTracerEvent")
    summary = "#{base_summary}\n   Tool: #{event.tool_name}"

    summary =
      if event.arguments && map_size(event.arguments) > 0 do
        "#{summary}\n   Arguments: #{inspect(event.arguments)}"
      else
        summary
      end

    summary =
      if event.result do
        # Convert result to string representation
        result_str = if is_binary(event.result), do: event.result, else: inspect(event.result)

        result_preview =
          if String.length(result_str) > 100 do
            String.slice(result_str, 0..99) <> "..."
          else
            result_str
          end

        # Add quotes around the preview for string results
        formatted_result =
          if is_binary(event.result), do: "\"#{result_preview}\"", else: result_preview

        "#{summary}\n   Result: #{formatted_result}"
      else
        summary
      end

    summary =
      if event.caller do
        "#{summary}\n   Caller: #{event.caller}"
      else
        summary
      end

    if event.call_duration_ms do
      "#{summary}\n   Duration: #{Float.round(event.call_duration_ms, 2)}ms"
    else
      summary
    end
  end
end

defmodule Mojentic.Tracer.TracerEvents.AgentInteractionTracerEvent do
  @moduledoc """
  Records interactions between agents.
  """

  defstruct [:timestamp, :correlation_id, :source, :from_agent, :to_agent, :event_type, :event_id]

  def printable_summary(%__MODULE__{} = event) do
    base_summary =
      Mojentic.Tracer.TracerEvents.format_base_summary(event, "AgentInteractionTracerEvent")

    summary = "#{base_summary}\n   From: #{event.from_agent} → To: #{event.to_agent}"
    summary = "#{summary}\n   Event Type: #{event.event_type}"

    if event.event_id do
      "#{summary}\n   Event ID: #{event.event_id}"
    else
      summary
    end
  end
end
