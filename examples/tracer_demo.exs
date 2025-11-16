#!/usr/bin/env elixir

# Example script demonstrating the tracer system with ChatSession and tools.
#
# This example shows how to use the tracer system to monitor an interactive
# chat session with Broker and tools. When the user exits the session,
# the script displays a summary of all traced events.
#
# It also demonstrates how correlation_id is used to trace related events
# across the system, allowing you to track the flow of a request from start to finish.
#
# Usage:
#   mix run examples/tracer_demo.exs

Mix.install([
  {:mojentic, path: "."}
])

alias Mojentic.LLM.{Broker, ChatSession, Message}
alias Mojentic.LLM.Gateways.Ollama
alias Mojentic.LLM.Tools.DateResolver
alias Mojentic.Tracer
alias Mojentic.Tracer.TracerEvents.{LLMCallTracerEvent, LLMResponseTracerEvent, ToolCallTracerEvent}

defmodule TracerDemo do
  @moduledoc """
  Interactive demonstration of the tracer system.
  """

  def run do
    IO.puts("Welcome to the chat session with tracer demonstration!")
    IO.puts("Ask questions about dates (e.g., 'What day is next Friday?') or anything else.")
    IO.puts("Behind the scenes, the tracer system is recording all interactions.")
    IO.puts("Each interaction is assigned a unique correlation_id to trace related events.")
    IO.puts("Type 'exit' to quit and see the trace summary.")
    IO.puts(String.duplicate("-", 80))

    # Start a tracer system to monitor all interactions
    {:ok, tracer} = Tracer.start_link()

    # Create a broker with the tracer
    broker = Broker.new("qwen3:32b", Ollama, tracer: tracer)

    # Create a date resolver tool
    date_tool = DateResolver.new()

    # Create a chat session
    session = ChatSession.new(broker, tools: [date_tool])

    # Start the interactive chat loop
    conversation_ids = chat_loop(session, %{}, 0)

    # Display the tracer summary
    display_summary(tracer, conversation_ids)
  end

  defp chat_loop(session, conversation_ids, turn_counter) do
    case IO.gets("You: ") do
      :eof ->
        IO.puts("\nExiting chat session...")
        conversation_ids

      input ->
        query = String.trim(input)

        if query == "" or query == "exit" do
          IO.puts("Exiting chat session...")
          conversation_ids
        else
          # Generate a unique correlation_id for this conversation turn
          correlation_id = UUID.uuid4()
          turn_num = turn_counter + 1

          IO.puts("[Turn #{turn_num}, correlation_id: #{String.slice(correlation_id, 0..7)}...]")

          # Update the broker's correlation_id for this turn
          updated_broker = %{session.broker | correlation_id: correlation_id}
          updated_session = %{session | broker: updated_broker}

          # Send the message
          IO.write("Assistant: ")

          case ChatSession.send(updated_session, query) do
            {:ok, response, new_session} ->
              IO.puts(response)
              chat_loop(new_session, Map.put(conversation_ids, turn_num, correlation_id), turn_num)

            {:error, reason} ->
              IO.puts("Error: #{inspect(reason)}")
              chat_loop(session, conversation_ids, turn_num)
          end
        end
    end
  end

  defp display_summary(tracer, conversation_ids) do
    IO.puts("\nTracer System Summary")
    IO.puts(String.duplicate("=", 80))
    IO.puts("You just had a conversation with an LLM, and the tracer recorded everything!")

    # Get all events
    all_events = Tracer.get_events(tracer)
    IO.puts("Total events recorded: #{length(all_events)}")
    print_tracer_events(all_events)

    # Show how to filter events by type
    IO.puts("\nYou can filter events by type:")

    llm_calls = Tracer.get_events(tracer, event_type: LLMCallTracerEvent)
    IO.puts("LLM Call Events: #{length(llm_calls)}")

    if length(llm_calls) > 0 do
      IO.puts("Example: #{hd(llm_calls) |> LLMCallTracerEvent.printable_summary()}")
    end

    llm_responses = Tracer.get_events(tracer, event_type: LLMResponseTracerEvent)
    IO.puts("\nLLM Response Events: #{length(llm_responses)}")

    if length(llm_responses) > 0 do
      IO.puts("Example: #{hd(llm_responses) |> LLMResponseTracerEvent.printable_summary()}")
    end

    tool_calls = Tracer.get_events(tracer, event_type: ToolCallTracerEvent)
    IO.puts("\nTool Call Events: #{length(tool_calls)}")

    if length(tool_calls) > 0 do
      IO.puts("Example: #{hd(tool_calls) |> ToolCallTracerEvent.printable_summary()}")
    end

    # Show the last few events
    IO.puts("\nThe last few events:")
    last_events = Tracer.get_last_n_tracer_events(tracer, 3)
    print_tracer_events(last_events)

    # Show how to use time-based filtering
    IO.puts("\nYou can also filter events by time range:")
    IO.puts("Example: Tracer.get_events(tracer, start_time: start_timestamp, end_time: end_timestamp)")

    # Demonstrate filtering events by correlation_id
    IO.puts("\nFiltering events by correlation_id:")
    IO.puts("This is a powerful feature that allows you to trace all events related to a specific request")

    if map_size(conversation_ids) > 0 do
      first_turn_id = 1
      first_correlation_id = Map.get(conversation_ids, first_turn_id)

      if first_correlation_id do
        IO.puts("\nEvents for conversation turn #{first_turn_id} (correlation_id: #{String.slice(first_correlation_id, 0..7)}...):")

        # Get all events with this correlation_id
        related_events =
          Tracer.get_events(tracer,
            filter_func: fn event -> event.correlation_id == first_correlation_id end
          )

        if length(related_events) > 0 do
          IO.puts("Found #{length(related_events)} related events")
          print_tracer_events(related_events)

          IO.puts("\nThe correlation_id allows you to trace the complete flow of a request:")
          IO.puts("1. From the initial LLM call")
          IO.puts("2. To the LLM response")
          IO.puts("3. To any tool calls triggered by the LLM")
          IO.puts("4. And any subsequent LLM calls with the tool results")
          IO.puts("\nThis creates a complete audit trail for debugging and observability.")
        else
          IO.puts("No events found with this correlation_id. This is unexpected and may indicate an issue.")
        end
      end
    end

    # Show how to extract specific information from events
    if length(tool_calls) > 0 do
      IO.puts("\nDetailed analysis example - Tool usage stats:")

      tool_names =
        Enum.reduce(tool_calls, %{}, fn event, acc ->
          Map.update(acc, event.tool_name, 1, &(&1 + 1))
        end)

      IO.puts("Tool usage frequency:")

      Enum.each(tool_names, fn {tool_name, count} ->
        IO.puts("  - #{tool_name}: #{count} calls")
      end)
    end
  end

  defp print_tracer_events(events) do
    IO.puts("\n#{String.duplicate("-", 80)}")
    IO.puts("Tracer Events:")
    IO.puts(String.duplicate("-", 80))

    events
    |> Enum.with_index(1)
    |> Enum.each(fn {event, i} ->
      summary =
        case event do
          %LLMCallTracerEvent{} -> LLMCallTracerEvent.printable_summary(event)
          %LLMResponseTracerEvent{} -> LLMResponseTracerEvent.printable_summary(event)
          %ToolCallTracerEvent{} -> ToolCallTracerEvent.printable_summary(event)
          _ -> inspect(event)
        end

      IO.puts("#{i}. #{summary}")
      IO.puts("")
    end)
  end
end

# Run the demo
TracerDemo.run()
