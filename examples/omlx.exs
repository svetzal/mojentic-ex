# oMLX Example
#
# Runs one chat turn against a local oMLX server and shows the model's
# thinking, its answer, and the provider evidence.
#
# Usage:
#   mix run examples/omlx.exs
#
# Configuration (read by the gateway):
#   OMLX_HOST     server address without /v1 (default: http://localhost:8000)
#   OMLX_API_KEY  bearer token, only when the server requires one
#   OMLX_MODEL    model to use (default: the first model the server lists)

alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.OMLX

host = System.get_env("OMLX_HOST") || "http://localhost:8000"
IO.puts("oMLX server: #{host}")

model =
  case System.get_env("OMLX_MODEL") do
    nil ->
      case OMLX.get_available_models() do
        {:ok, [first | _]} ->
          first

        {:ok, []} ->
          IO.puts("The server lists no models. Add one in the oMLX admin dashboard.")
          System.halt(1)

        {:error, reason} ->
          IO.puts("Could not list models: #{inspect(reason)}")
          IO.puts("Check that oMLX is running and that OMLX_HOST and OMLX_API_KEY are right.")
          System.halt(1)
      end

    name ->
      name
  end

IO.puts("Model: #{model}")
IO.puts("")

broker = Broker.new(model, OMLX)
messages = [Message.user("In one sentence, what is Elixir?")]

case Broker.generate_response(broker, messages) do
  {:ok, response} ->
    if response.thinking do
      IO.puts("Thinking:")
      IO.puts(String.trim(response.thinking))
      IO.puts("")
    end

    IO.puts("Answer:")
    IO.puts(String.trim(response.content || ""))
    IO.puts("")
    IO.puts("Finish reason: #{inspect(response.finish_reason)}")
    IO.puts("Provider model: #{inspect(response.model)}")
    IO.puts("Usage: #{inspect(response.usage)}")

    if response.finish_reason != "stop" do
      IO.puts("The response is incomplete, so the answer above is not a final answer.")
    end

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end
