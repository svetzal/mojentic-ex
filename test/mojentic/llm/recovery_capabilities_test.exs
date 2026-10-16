defmodule Mojentic.LLM.RecoveryCapabilitiesTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Recovery

  @external_resource "test/contracts/recovery_capabilities_v1.json"
  @contract Jason.decode!(File.read!(@external_resource))
  @keys [
    :local_request_cancellation,
    :remote_request_cancellation,
    :request_status,
    :idempotency,
    :exact_attempt_termination
  ]
  @values [:supported, :unsupported, :unknown]

  test "v1 contract names every maintained adapter and all five declarations" do
    assert @contract["contract"] == "recovery-capabilities-v1"

    assert Enum.sort(Enum.map(@contract["cases"], &{&1["provider"], &1["capability"]})) ==
             Enum.sort(
               for provider <- ~w(openai ollama omlx),
                   key <- @keys,
                   do: {provider, Atom.to_string(key)}
             )
  end

  for entry <- @contract["cases"] do
    @provider String.to_existing_atom(entry["provider"])
    @capability String.to_existing_atom(entry["capability"])
    @expected entry["evidence"]

    test "v1 #{@provider} #{@capability} declares #{@expected["value"]} with exact inspected evidence" do
      declarations = Recovery.capabilities(@provider)
      evidence = Recovery.capability_evidence(@provider)
      actual = Map.fetch!(evidence, @capability)

      assert Enum.sort(Map.keys(declarations)) == Enum.sort(@keys)
      assert Enum.sort(Map.keys(evidence)) == Enum.sort(@keys)
      assert Map.fetch!(declarations, @capability) in @values
      assert Atom.to_string(Map.fetch!(declarations, @capability)) == @expected["value"]
      assert actual.value == Map.fetch!(declarations, @capability)

      assert Map.new(actual, fn {key, value} -> {Atom.to_string(key), value} end)
             |> Map.update!("value", &Atom.to_string/1) == @expected
    end
  end

  for provider <- [:openai, :ollama, :omlx] do
    test "#{provider} retains atom values and unknown exact-attempt termination" do
      assert Recovery.capabilities(unquote(provider)).exact_attempt_termination == :unknown

      assert Enum.all?(Recovery.capabilities(unquote(provider)), fn {key, value} ->
               is_atom(key) and value in @values
             end)
    end
  end

  test "unsupported providers retain the existing function-clause boundary" do
    assert_raise FunctionClauseError, fn -> Recovery.capabilities(:anthropic) end
    assert_raise FunctionClauseError, fn -> Recovery.capability_evidence(:anthropic) end
  end
end
