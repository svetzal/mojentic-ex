defmodule Mojentic.TestSupport.StreamEvidence do
  @moduledoc false

  # Recovery lifecycle/history snapshots precede terminal stream measurements.
  # Preserve every policy/provider field in existing identity assertions. The
  # first-token executable contract independently asserts all terminal timings.
  def recovery_snapshot(error) do
    error
    |> Mojentic.LLM.CompletionError.safe_metadata()
    |> Map.update!(
      :metadata,
      &Map.drop(&1, [:time_to_first_token_ms, :first_token_kind, :request_duration_ms])
    )
  end
end
