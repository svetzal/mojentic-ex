defmodule Mojentic.LLM.Tools.ToolColdLoadTest do
  use ExUnit.Case, async: false

  alias Mojentic.LLM.Tools.Tool

  @tag :tmp_dir
  test "loads a struct tool before selecting its instance descriptor", %{tmp_dir: directory} do
    module = Mojentic.Test.ColdDescriptorFixture

    [{^module, beam}] =
      Code.compile_quoted(
        quote do
          defmodule Mojentic.Test.ColdDescriptorFixture do
            defstruct [:name]
            def descriptor(tool), do: %{function: %{name: tool.name}}
            def descriptor, do: raise("an instance is required")
          end
        end
      )

    instance = struct(module, name: "instance-specific")
    File.write!(Path.join(directory, "#{module}.beam"), beam)
    Code.prepend_path(directory)

    on_exit(fn ->
      Code.delete_path(directory)
      :code.delete(module)
      :code.purge(module)
    end)

    :code.delete(module)
    :code.purge(module)
    assert :code.is_loaded(module) == false
    assert Tool.descriptor(instance) == %{function: %{name: "instance-specific"}}
  end
end
