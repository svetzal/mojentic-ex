defmodule Mojentic.LLM.Recovery.Capabilities do
  @moduledoc false

  @declarations %{
    openai: %{
      local_request_cancellation: %{
        value: :supported,
        endpoint: "POST https://api.openai.com/v1/chat/completions",
        documentation:
          "https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events",
        inspected_on: "2026-10-16",
        basis:
          "Chat Completions streaming documents interrupted or cancelled streams and potentially missing final usage; this is local stream cancellation only."
      },
      remote_request_cancellation: %{
        value: :unsupported,
        endpoint: "POST https://api.openai.com/v1/chat/completions",
        documentation:
          "https://developers.openai.com/api/reference/resources/chat/subresources/completions",
        inspected_on: "2026-10-16",
        basis:
          "The Chat Completions operation inventory has no remote cancel operation. Deleting a stored completion is not cancellation of inference."
      },
      request_status: %{
        value: :unsupported,
        endpoint: "POST https://api.openai.com/v1/chat/completions",
        documentation:
          "https://developers.openai.com/api/reference/resources/chat/subresources/completions",
        inspected_on: "2026-10-16",
        basis:
          "Retrieval requires store=true and a completion ID; it retrieves a stored result, not the status of an in-flight or ambiguously accepted POST."
      },
      idempotency: %{
        value: :unsupported,
        endpoint: "POST https://api.openai.com/v1/chat/completions",
        documentation:
          "https://developers.openai.com/api/reference/resources/chat/subresources/completions",
        inspected_on: "2026-10-16",
        basis:
          "The documented Chat Completions request parameters describe no idempotency facility for replaying this POST."
      },
      exact_attempt_termination: %{
        value: :unknown,
        endpoint: "POST https://api.openai.com/v1/chat/completions",
        documentation:
          "https://developers.openai.com/api/reference/resources/chat/subresources/completions",
        inspected_on: "2026-10-16",
        basis:
          "The documentation does not prove termination of one exact wire attempt; local stream closure is insufficient."
      }
    },
    ollama: %{
      local_request_cancellation: %{
        value: :supported,
        endpoint: "POST http://localhost:11434/api/chat",
        documentation: "https://github.com/ollama/ollama-js#abort",
        inspected_on: "2026-10-16",
        basis:
          "The provider SDK documents chat streaming and abort of streamed generations, raising AbortError locally; it does not attest to exact remote termination."
      },
      remote_request_cancellation: %{
        value: :unsupported,
        endpoint: "POST http://localhost:11434/api/chat",
        documentation: "https://docs.ollama.com/api/chat",
        inspected_on: "2026-10-16",
        basis:
          "The chat endpoint documents generation, with no remote request cancellation facility. keep_alive controls model residency, not one request."
      },
      request_status: %{
        value: :unsupported,
        endpoint: "POST http://localhost:11434/api/chat",
        documentation: "https://docs.ollama.com/api/chat",
        inspected_on: "2026-10-16",
        basis:
          "The chat request and response document no in-flight request status facility; done reports completion in the current response only."
      },
      idempotency: %{
        value: :unsupported,
        endpoint: "POST http://localhost:11434/api/chat",
        documentation: "https://docs.ollama.com/api/chat",
        inspected_on: "2026-10-16",
        basis: "The chat request documents no idempotency key or deduplicated resend facility."
      },
      exact_attempt_termination: %{
        value: :unknown,
        endpoint: "POST http://localhost:11434/api/chat",
        documentation: "https://docs.ollama.com/api/chat",
        inspected_on: "2026-10-16",
        basis:
          "The chat documentation does not prove termination of one exact wire attempt; SDK abort is not that evidence."
      }
    },
    omlx: %{
      local_request_cancellation: %{
        value: :unknown,
        endpoint: "POST http://localhost:8000/v1/chat/completions",
        documentation:
          "https://github.com/jundot/omlx/blob/53ab0e66d75fe46e3cfa7ed7a7762d3bbcf21e9c/README.md#api-compatibility",
        inspected_on: "2026-10-16",
        basis:
          "The API endpoint inventory documents streaming chat completion but does not describe local request cancellation; OpenAI protocol compatibility alone is ambiguous."
      },
      remote_request_cancellation: %{
        value: :unsupported,
        endpoint: "POST http://localhost:8000/v1/chat/completions",
        documentation:
          "https://github.com/jundot/omlx/blob/53ab0e66d75fe46e3cfa7ed7a7762d3bbcf21e9c/README.md#api-compatibility",
        inspected_on: "2026-10-16",
        basis:
          "The documented API endpoint inventory has no remote cancellation operation for chat completions; admin model management is not per-request cancellation."
      },
      request_status: %{
        value: :unsupported,
        endpoint: "POST http://localhost:8000/v1/chat/completions",
        documentation:
          "https://github.com/jundot/omlx/blob/53ab0e66d75fe46e3cfa7ed7a7762d3bbcf21e9c/README.md#api-compatibility",
        inspected_on: "2026-10-16",
        basis:
          "The documented API endpoint inventory has no chat request status operation; model listing and usage analytics are not in-flight request status."
      },
      idempotency: %{
        value: :unknown,
        endpoint: "POST http://localhost:8000/v1/chat/completions",
        documentation:
          "https://github.com/jundot/omlx/blob/53ab0e66d75fe46e3cfa7ed7a7762d3bbcf21e9c/README.md#api-compatibility",
        inspected_on: "2026-10-16",
        basis:
          "The endpoint inventory does not specify chat request headers or deduplication semantics, so idempotency is ambiguous."
      },
      exact_attempt_termination: %{
        value: :unknown,
        endpoint: "POST http://localhost:8000/v1/chat/completions",
        documentation:
          "https://github.com/jundot/omlx/blob/53ab0e66d75fe46e3cfa7ed7a7762d3bbcf21e9c/README.md#api-compatibility",
        inspected_on: "2026-10-16",
        basis:
          "The streaming endpoint documentation does not prove termination of one exact wire attempt."
      }
    }
  }

  def evidence(provider), do: Map.fetch!(@declarations, provider)

  def values(provider) do
    Map.new(evidence(provider), fn {capability, evidence} -> {capability, evidence.value} end)
  end
end
