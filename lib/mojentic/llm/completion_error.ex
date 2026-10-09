defmodule Mojentic.LLM.CompletionError do
  @moduledoc """
  Safe, single-attempt completion failure. `safe_metadata/1` is the serialization
  boundary; `cause/1` explicitly reveals the original provider or parser cause.
  Retry eligibility never grants permission to resend.
  """

  defstruct [
    :category,
    :provider,
    :operation,
    :http_status,
    :provider_code,
    :provider_request_id,
    :retry_after,
    :phase,
    :acceptance,
    :progress,
    :retry_eligible,
    :reason,
    :logical_request_id,
    :attempt_id,
    :private_cause,
    wire_attempt: 1,
    resend_permission: :not_granted,
    history: []
  ]

  @type category ::
          :transport | :http | :provider_response | :protocol | :cancellation | :client_timeout
  @type phase :: :connecting | :sending | :awaiting_headers | :streaming | :decoding | :unknown
  @type acceptance :: :yes | :no | :unknown
  @type semantic_progress :: %{
          content: boolean(),
          reasoning: boolean(),
          tool_fragments: non_neg_integer(),
          completed_tool_calls: non_neg_integer()
        }
  @type progress :: %{
          headers_received: boolean(),
          raw_bytes: non_neg_integer(),
          observed: semantic_progress(),
          delivered: semantic_progress()
        }
  @type retry_after ::
          :absent | :invalid | {:delay_seconds, non_neg_integer()} | {:http_date, String.t()}
  @type t :: %__MODULE__{
          category: category(),
          provider: :openai | :ollama | :omlx,
          operation: :complete | :complete_object,
          http_status: integer() | nil,
          provider_code: String.t() | nil,
          provider_request_id: String.t() | nil,
          retry_after: retry_after(),
          phase: phase(),
          acceptance: acceptance(),
          progress: progress(),
          retry_eligible: boolean(),
          reason: atom(),
          logical_request_id: String.t(),
          attempt_id: String.t(),
          wire_attempt: non_neg_integer(),
          resend_permission: :not_granted,
          history: [map()],
          private_cause: (-> term())
        }

  @doc "Returns only validated metadata, excluding the retained cause."
  @spec safe_metadata(t()) :: map()
  def safe_metadata(error) do
    error
    |> Map.from_struct()
    |> Map.delete(:private_cause)
    |> Map.update!(:retry_after, fn
      {kind, value} -> %{kind: kind, value: value}
      state -> state
    end)
  end

  @doc "Explicitly retrieves the original cause, which may contain secrets."
  @spec cause(t()) :: term()
  def cause(%__MODULE__{private_cause: cause}), do: cause.()
end

defimpl Inspect, for: Mojentic.LLM.CompletionError do
  import Inspect.Algebra

  def inspect(error, opts) do
    concat([
      "#CompletionError<",
      to_doc(Mojentic.LLM.CompletionError.safe_metadata(error), opts),
      ">"
    ])
  end
end

defimpl Jason.Encoder, for: Mojentic.LLM.CompletionError do
  def encode(error, opts) do
    error |> Mojentic.LLM.CompletionError.safe_metadata() |> Jason.Encode.map(opts)
  end
end
