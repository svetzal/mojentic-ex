# Tutorial: Building Chatbots

## Why Use Chat Sessions?

When working with Large Language Models (LLMs), simple text generation is useful for one-off interactions, but many applications require ongoing conversations where the model remembers previous exchanges. This is where chat sessions come in.

Chat sessions are essential when you need to:

- Build conversational agents or chatbots
- Maintain context across multiple user interactions
- Create applications where the LLM needs to remember previous information
- Develop more natural and coherent conversational experiences

## When to Apply This Approach

Use chat sessions when:

- Your application requires multi-turn conversations
- You need the LLM to reference information from earlier in the conversation
- You want to create a more interactive and engaging user experience

## The Key Difference: Expanding Context

The fundamental difference between simple text generation and chat sessions is the **expanding context**. With each new message in a chat session:

1. The message is added to the conversation history
2. All previous messages (within token limits) are sent to the LLM with each new query
3. The LLM can reference and build upon earlier parts of the conversation

## Getting Started

Let's walk through a simple example of building a chatbot using Mojentic's `ChatSession`.

### Basic Implementation

Here's the simplest way to create a chat session with Mojentic:

```elixir
alias Mojentic.LLM.{ChatSession, Broker}
alias Mojentic.LLM.Gateways.Ollama

# 1. Create an LLM broker
broker = Broker.new("qwen3:32b", Ollama)

# 2. Initialize a chat session
{:ok, session} = ChatSession.start_link(broker)

# 3. Simple interactive loop
IO.puts "Chatbot started. Type 'exit' to quit."

Stream.cycle([:input])
|> Stream.map(fn _ -> IO.gets("Query: ") |> String.trim() end)
|> Stream.take_while(&(&1 != "exit"))
|> Enum.each(fn query ->
  {:ok, response} = ChatSession.send_message(session, query)
  IO.puts(response)
end)
```

This code creates an interactive chatbot that maintains context across multiple exchanges.

## Step-by-Step Explanation

### 1. Initialize the Broker

```elixir
broker = Broker.new("qwen3:32b", Ollama)
```

The `Broker` is the central component that handles communication with the LLM provider (in this case, Ollama).

### 2. Start the Session

```elixir
{:ok, session} = ChatSession.start_link(broker)
```

`ChatSession` is a GenServer that holds the state of the conversation. By default, it manages the message history and ensures it fits within the model's context window.

### 3. Send Messages

```elixir
{:ok, response} = ChatSession.send_message(session, query)
```

When you send a message:
1. It's added to the history.
2. The full history is sent to the LLM.
3. The LLM's response is added to the history.
4. The response text is returned.

## Customizing Your Chat Session

You can customize the session with a system prompt or tools.

### System Prompt

The system prompt sets the behavior of the assistant.

```elixir
{:ok, session} = ChatSession.start_link(broker, 
  system_prompt: "You are a helpful AI assistant specialized in Elixir programming."
)
```

### Adding Tools

You can enhance your chatbot by providing tools that the LLM can use.

```elixir
alias Mojentic.LLM.Tools.DateResolver

{:ok, session} = ChatSession.start_link(broker, 
  tools: [DateResolver]
)

# The LLM can now use the date tool in conversations
{:ok, response} = ChatSession.send_message(session, "What day of the week is July 4th, 2025?")
IO.puts(response)
```

## Streaming Responses

For a better user experience with longer responses, you can stream the LLM's reply as it's generated. Because Elixir uses immutable data, streaming uses a two-phase approach:

```elixir
{:ok, stream, handle} = ChatSession.send_stream(session, "Tell me a story")
stream |> Stream.each(fn
        text when is_binary(text) -> IO.write(text)
        {:thinking, _text} -> :ok
      end) |> Stream.run()
session = ChatSession.finalize_stream(handle)
```

The `send_stream/2` function adds the user message to the session and returns a stream of chunks plus a handle. After consuming the stream, call `finalize_stream/1` with the handle to record the assembled response in the session history. Tools are handled transparently through the broker's recursive streaming.

## Summary

In this tutorial, we've learned how to:
1.  Initialize a `ChatSession` with a `Broker`.
2.  Create an interactive loop to chat with the model.
3.  Customize the session with system prompts and tools.

By leveraging chat sessions, you can create engaging conversational experiences that maintain context across multiple interactions.

### Streaming recovery and failed finalization

Use `send_stream/3` to opt in without changing legacy session streaming:

```elixir
{:ok, stream, handle} = ChatSession.send_stream(session, "Tell me a story",
  recovery: [max_attempts: 2, base_delay: 100]
)

Enum.each(stream, fn
  text when is_binary(text) -> IO.write(text)
  {:thinking, _text} -> :ok
  {:error, error} -> IO.inspect(error)
end)

case ChatSession.finalize_stream(handle) do
  {:error, error} -> {:error, error, session}
  updated_session -> {:ok, updated_session}
end
```

Always finalize the handle to release its accumulation process. An interrupted or
consumer-halted stream returns an error and cannot append an assistant response
to successful history. The original immutable session remains available. Tool
effects already completed are not rolled back or replayed, so retrying the whole
session send is an application decision. Recovery applies to the failed provider
request only. Without a hook, eligible OpenAI failures may retry; Ollama and oMLX
require admission unless real transport evidence proves `acceptance: :no`, such
as connection refusal. Ambiguous local acceptance stops with
`:admission_required`. The same rule covers `send/3`, `send_stream/3` and stream
finalization. Recovery defaults to one attempt; opt into resends explicitly with
`max_attempts`, as described in the streaming guide.


Cancellation errors forwarded by `send/3` and `send_stream/3` preserve received
response evidence and prior attempts. `CompletionError.received_evidence(error)`
is a sensitive inspection API; keep its raw bytes and headers out of ordinary
logs. `finalize_stream/1` returns the same cancellation error and releases the
handle without adding a successful assistant response. For cancellation during a
paused consumer callback, send directly to the recovery owner recorded by the
`:attempt_started` observer, as described in the streaming guide.

Recovery preserves the encoded request for the current session turn, including
prior system, user and assistant messages. The immutable-request in-process adapter tests
exercise both `send/3` and `send_stream/3` after a successful prior turn and compare
the complete payload and retry bytes with recovery disabled. Session APIs build
their own completion configuration from the optional session temperature and
per-send sampling/context/output controls. Unset provider limits stay omitted.
The richer schema/tool-history matrix is tested through gateways and brokers.
Native reasoning is kept separate from ordinary assistant text; reasoning
retention across completed tool continuations is opt-in.

Recovery-enabled `send/3` and `send_stream/3` preserve `CompletionError` values
for invalid policies, capture failures and provider length termination. Invalid
policies have category `:policy` and dispatch no request. Failed streaming handles
return the same error from `finalize_stream/1`; the original session history
remains available. See the [typed error migration guidance](broker.md#migrating-typed-policy-and-length-failures)
for matching error categories and explicitly inspecting retained causes.

## Native reasoning controls

`send/3` and `send_stream/3` accept `reasoning_effort`, `reasoning_profile` and
`preserve_reasoning` alongside `recovery`. For example:

```elixir
ChatSession.send(session, "Use the tools to check this",
  reasoning_effort: :xhigh,
  reasoning_profile: Mojentic.LLM.ReasoningProfile.qwen3_8(),
  preserve_reasoning: true
)
```

This retains native reasoning inside completed Broker tool continuations.
Session history remains bounded visible-answer history. Native stream thinking
arrives separately as `{:thinking, text}` and is excluded from the visible reply
stored at finalization. Failed or consumer-halted retention streams cannot
finalize successfully. Use completed `Broker.generate_response/4` results and
`Message.reasoning_content` when managing native history across outer turns.

## Request fidelity

The session temperature defaults to `nil`; the provider chooses its setting.
An explicit `temperature: 0` is preserved. Per-send options on `send/3` and
`send_stream/3` accept `temperature`, `num_ctx`, `max_tokens`, `top_p` and `top_k`;
a per-send temperature overrides the session setting, including explicit `nil`
to omit it. Unset provider limits stay omitted on continuations and retries.
`max_context` still defaults to 32,768 for local history trimming and never
becomes a provider `num_ctx` request setting. To restore previous request limits:

```elixir
session = ChatSession.new(broker, temperature: 1.0)
{:ok, answer, session} = ChatSession.send(session, "Hello",
  num_ctx: 32_768, max_tokens: 16_384)
```

Use `max_tokens` instead of the removed `CompletionConfig.num_predict`.
