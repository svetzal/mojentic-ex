defmodule Mojentic.LLM.CompletionConfig do
  @moduledoc """
  Configuration for LLM completion requests.

  Set `max_tool_iterations: :infinity` to let the tool loop run until the model
  returns a final response, the gateway fails, or its caller cancels execution.
  This removes only the iteration cutoff; provider request limits still apply.

  `recovery: []` opts ordinary and structured completions into safe errors with
  one wire attempt. Set `max_attempts` to opt into bounded resends. Local providers
  require explicit admission unless acceptance is `:no` from transport evidence.
  Eligible OpenAI failures may retry without a hook. No-hook local failures with
  ambiguous acceptance stop with `:admission_required`; this differs from a hook
  that ends without a decision (`:admission_no_decision`). See `Mojentic.LLM.Recovery`
  and RECOVERY-CONFORMANCE.md for admission, cancellation and policy options.
  Recovery limits govern resends; they never time out active generation.
  Streaming recovery covers both completion stream APIs. Add
  `trace_observer: fn event -> persist(event); :ok end` inside `recovery` to receive
  raw per-wire evidence from the Req HTTP boundary. Caller storage owns retention
  and access control; these events can contain credentials and model payloads.
  An observer exception, throw, exit or return other than `:ok` terminates the
  completion with `:capture_failed` and never authorizes another inference.
  See `Mojentic.LLM.Recovery` for capture limits.

  Invalid non-nil recovery policies return `Mojentic.LLM.CompletionError` with
  `category: :policy` and `reason: :unsupported_options` without dispatching HTTP.
  Recovery-enabled completions reject provider `"length"` termination before
  decoding structured content or executing tools. Broker and ChatSession retain
  the completion error and its cause; see `Mojentic.LLM.CompletionError`.

  `reasoning_effort` accepts `:disabled`, `:enabled`, `:low`, `:medium`, `:high`
  and `:xhigh`, with exact provider controls. `nil` leaves effort unknown.
  `reasoning_profile` selects an explicit `Mojentic.LLM.ReasoningProfile`;
  incompatible efforts or native history fail before HTTP. Model names never
  select a profile. `preserve_reasoning: true` retains completed native assistant
  reasoning across Broker tool continuations; its default is `false`. It does
  not enable thinking. oMLX also requests `preserve_thinking`; server settings
  can override that request. OpenAI rejects these new controls and native
  history, while its legacy low/medium/high controls remain available.

  Provides settings for temperature, context window size, and token limits.

  ## Examples

      iex> CompletionConfig.new()
      %CompletionConfig{temperature: 1.0, num_ctx: 32768, max_tokens: 16384, top_p: nil, top_k: nil, response_format: nil, reasoning_effort: nil, max_tool_iterations: 10}

      iex> CompletionConfig.new(temperature: 0.7, max_tokens: 1000)
      %CompletionConfig{temperature: 0.7, num_ctx: 32768, max_tokens: 1000, top_p: nil, top_k: nil, response_format: nil, reasoning_effort: nil, max_tool_iterations: 10}

      iex> CompletionConfig.new(top_p: 0.9, top_k: 40)
      %CompletionConfig{temperature: 1.0, num_ctx: 32768, max_tokens: 16384, top_p: 0.9, top_k: 40, response_format: nil, reasoning_effort: nil, max_tool_iterations: 10}

  """

  @type response_format :: %{
          type: :json_object | :text,
          schema: map() | nil
        }

  @type reasoning_effort :: :disabled | :enabled | :low | :medium | :high | :xhigh

  @type t :: %__MODULE__{
          temperature: float(),
          num_ctx: pos_integer(),
          max_tokens: pos_integer(),
          num_predict: integer() | nil,
          top_p: float() | nil,
          top_k: integer() | nil,
          response_format: response_format() | nil,
          reasoning_effort: reasoning_effort() | nil,
          reasoning_profile: Mojentic.LLM.ReasoningProfile.t() | nil,
          preserve_reasoning: boolean(),
          recovery: keyword() | nil,
          max_tool_iterations: non_neg_integer() | :infinity
        }

  defstruct reasoning_profile: nil,
            preserve_reasoning: false,
            recovery: nil,
            temperature: 1.0,
            num_ctx: 32_768,
            max_tokens: 16_384,
            num_predict: nil,
            top_p: nil,
            top_k: nil,
            response_format: nil,
            reasoning_effort: nil,
            max_tool_iterations: 10

  @doc """
  Creates a new configuration with optional overrides.

  ## Parameters

  - `opts`: Keyword list of options to override defaults

  ## Examples

      iex> CompletionConfig.new(temperature: 0.5)
      %CompletionConfig{temperature: 0.5, num_ctx: 32768, max_tokens: 16384, top_p: nil, top_k: nil, response_format: nil, reasoning_effort: nil, max_tool_iterations: 10}

      iex> CompletionConfig.new(top_p: 0.95)
      %CompletionConfig{temperature: 1.0, num_ctx: 32768, max_tokens: 16384, top_p: 0.95, top_k: nil, response_format: nil, reasoning_effort: nil, max_tool_iterations: 10}

      iex> CompletionConfig.new(response_format: %{type: :json_object, schema: nil})
      %CompletionConfig{temperature: 1.0, num_ctx: 32768, max_tokens: 16384, top_p: nil, top_k: nil, response_format: %{type: :json_object, schema: nil}, reasoning_effort: nil, max_tool_iterations: 10}

  """
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end
end
