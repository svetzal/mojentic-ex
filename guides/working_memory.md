# Working Memory Pattern

The working memory pattern enables agents to maintain and share context across multiple interactions. This guide shows you how to use `SharedWorkingMemory` and build memory-aware agents.

## Overview

Working memory provides:
- **Shared Context**: Multiple agents can read from and write to the same memory
- **Continuous Learning**: Agents automatically learn and remember new information
- **State Persistence**: Knowledge is maintained across interactions
- **Event Coordination**: Memory updates flow through the event system

## Quick Start

### Basic Usage

```elixir
alias Mojentic.Context.SharedWorkingMemory

# Create memory with initial data
memory = SharedWorkingMemory.new(%{
  "User" => %{
    "name" => "Alice",
    "age" => 30
  }
})

# Retrieve current state
current = SharedWorkingMemory.get_working_memory(memory)

# Update memory (deep merge)
memory = SharedWorkingMemory.merge_to_working_memory(memory, %{
  "User" => %{
    "city" => "NYC",
    "preferences" => %{"theme" => "dark"}
  }
})

# Result: {"User": {"name": "Alice", "age": 30, "city": "NYC", "preferences": {...}}}
```

### Memory-Aware Agent

```elixir
alias Mojentic.Agents.BaseLLMAgentWithMemory
alias Mojentic.LLM.Broker

# Initialize
broker = Broker.new("qwen2.5:7b", gateway)
memory = SharedWorkingMemory.new(%{"User" => %{"name" => "Alice"}})

# Create agent
agent = BaseLLMAgentWithMemory.new(
  broker: broker,
  memory: memory,
  behaviour: "You are a helpful assistant who remembers things.",
  instructions: "Answer questions and remember any new information.",
  response_model: %{
    "type" => "object",
    "required" => ["answer"],
    "properties" => %{
      "answer" => %{"type" => "string"}
    }
  }
)

# Generate response with memory context
{:ok, response, updated_memory} =
  BaseLLMAgentWithMemory.generate_response_with_memory(
    agent,
    "I love pizza and my favorite color is blue"
  )

# Memory now includes learned preferences
```

## Core Concepts

### SharedWorkingMemory

A simple, immutable key-value store that agents use to share context:

```elixir
defmodule SharedWorkingMemory do
  @moduledoc """
  Shared context store with deep merge support.

  Immutable - each operation returns a new instance.
  Thread-safe when used with proper concurrency patterns.
  """

  def new(initial_memory \\ %{})
  def get_working_memory(memory)
  def merge_to_working_memory(memory, updates)
end
```

**Key features:**
- **Immutable**: Operations return new instances
- **Deep Merge**: Nested maps are recursively merged
- **Simple API**: Just 3 functions to learn

### BaseLLMAgentWithMemory

An LLM agent that automatically includes memory in its context:

```elixir
agent = BaseLLMAgentWithMemory.new(
  broker: broker,           # LLM broker for generation
  memory: memory,           # SharedWorkingMemory instance
  behaviour: "...",         # System-level instructions
  instructions: "...",      # Task-specific instructions
  response_model: %{...}    # JSON schema for responses
)
```

**How it works:**
1. Memory is automatically injected into the prompt
2. Response model is extended with a `memory` field
3. Agent can update memory as part of its response
4. Updated memory is returned alongside the response

## Deep Merge Behavior

Memory updates use deep merge to preserve existing data:

```elixir
# Initial memory
memory = SharedWorkingMemory.new(%{
  "User" => %{
    "name" => "Alice",
    "age" => 30,
    "address" => %{
      "city" => "NYC",
      "state" => "NY"
    }
  }
})

# Update with nested data
memory = SharedWorkingMemory.merge_to_working_memory(memory, %{
  "User" => %{
    "age" => 31,
    "address" => %{
      "zip" => "10001"
    }
  }
})

# Result: All fields preserved, nested objects merged
%{
  "User" => %{
    "name" => "Alice",      # Preserved
    "age" => 31,            # Updated
    "address" => %{
      "city" => "NYC",      # Preserved
      "state" => "NY",      # Preserved
      "zip" => "10001"      # Added
    }
  }
}
```

## Building Custom Memory-Aware Agents

You can build your own agents using the memory pattern:

```elixir
defmodule MyApp.ResearchAgent do
  use GenServer
  alias Mojentic.Agents.BaseLLMAgentWithMemory
  alias Mojentic.Context.SharedWorkingMemory

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    memory = SharedWorkingMemory.new(%{
      "research_notes" => %{},
      "sources" => []
    })

    agent = BaseLLMAgentWithMemory.new(
      broker: opts[:broker],
      memory: memory,
      behaviour: "You are a research assistant.",
      instructions: "Research topics and maintain organized notes.",
      response_model: %{
        "type" => "object",
        "required" => ["findings"],
        "properties" => %{
          "findings" => %{"type" => "string"}
        }
      }
    )

    {:ok, %{agent: agent}}
  end

  def handle_call({:research, topic}, _from, state) do
    {:ok, response, updated_memory} =
      BaseLLMAgentWithMemory.generate_response_with_memory(
        state.agent,
        "Research: #{topic}"
      )

    # Update agent with new memory
    agent = BaseLLMAgentWithMemory.update_memory(state.agent, updated_memory)

    {:reply, {:ok, response}, %{state | agent: agent}}
  end
end
```

## Multi-Agent Coordination

Multiple agents can share the same memory instance:

```elixir
# Shared memory
memory = SharedWorkingMemory.new(%{"context" => %{}})

# Multiple agents
researcher = BaseLLMAgentWithMemory.new(
  broker: broker,
  memory: memory,
  behaviour: "You are a research assistant.",
  instructions: "Research topics thoroughly.",
  response_model: research_schema
)

writer = BaseLLMAgentWithMemory.new(
  broker: broker,
  memory: memory,
  behaviour: "You are a technical writer.",
  instructions: "Write clear documentation from research.",
  response_model: writing_schema
)

# Researcher updates memory
{:ok, research, memory} =
  BaseLLMAgentWithMemory.generate_response_with_memory(
    researcher, "Research Elixir GenServers"
  )

# Writer uses updated memory
writer = BaseLLMAgentWithMemory.update_memory(writer, memory)
{:ok, article, memory} =
  BaseLLMAgentWithMemory.generate_response_with_memory(
    writer, "Write an article about what you learned"
  )
```

## Use Cases

### 1. Conversational Chatbots

```elixir
memory = SharedWorkingMemory.new(%{
  "conversation_history" => [],
  "user_preferences" => %{}
})
```

### 2. Workflow Automation

```elixir
memory = SharedWorkingMemory.new(%{
  "workflow_state" => "started",
  "completed_steps" => [],
  "pending_tasks" => []
})
```

### 3. Knowledge Base Building

```elixir
memory = SharedWorkingMemory.new(%{
  "entities" => %{},
  "relationships" => [],
  "facts" => []
})
```

### 4. Multi-Step Planning

```elixir
memory = SharedWorkingMemory.new(%{
  "goals" => [],
  "current_plan" => [],
  "obstacles" => []
})
```

## Best Practices

### 1. Structure Your Memory

Use clear, hierarchical keys:

```elixir
%{
  "User" => %{...},
  "Conversation" => %{...},
  "SystemState" => %{...}
}
```

### 2. Update Memory Explicitly

Always propagate memory updates:

```elixir
{:ok, response, updated_memory} = generate_response(agent, input)
agent = BaseLLMAgentWithMemory.update_memory(agent, updated_memory)
```

### 3. Use Descriptive Instructions

Tell the agent what to remember:

```elixir
instructions: """
Answer questions and remember:
- User preferences and interests
- Important dates and events
- Ongoing projects and tasks
Store new information in the memory field of your response.
"""
```

### 4. Validate Memory Updates

Check memory after updates to ensure quality:

```elixir
{:ok, response, updated_memory} = generate_response(agent, input)

# Validate before accepting
if valid_memory_update?(updated_memory) do
  agent = BaseLLMAgentWithMemory.update_memory(agent, updated_memory)
else
  # Rollback or retry
end
```

## Example Application

See the complete working memory example:

```bash
cd mojentic-ex
elixir examples/working_memory.exs
```

The example demonstrates:
- Initializing memory with user data
- RequestAgent that learns from conversation
- Event-driven coordination with AsyncDispatcher
- Memory persistence across interactions

## API Reference

### SharedWorkingMemory

```elixir
@spec new(map()) :: t()
@spec get_working_memory(t()) :: map()
@spec merge_to_working_memory(t(), map()) :: t()
```

### BaseLLMAgentWithMemory

```elixir
@spec new(keyword()) :: t()
@spec generate_response_with_memory(t(), String.t()) ::
  {:ok, map(), SharedWorkingMemory.t()} | {:error, term()}
@spec update_memory(t(), SharedWorkingMemory.t()) :: t()
```

See `lib/mojentic/context/shared_working_memory.ex` and `lib/mojentic/agents/base_llm_agent_with_memory.ex` for full documentation.
