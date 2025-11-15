#!/usr/bin/env elixir

# Example demonstrating the file management tools
#
# This example shows how to use the FilesystemGateway and various file tools
# to interact with the filesystem safely within a sandboxed directory.

Code.require_file("../test/test_helper.exs", __DIR__)

alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.Ollama

alias Mojentic.LLM.Tools.{
  FilesystemGateway,
  ListFilesTool,
  ReadFileTool,
  WriteFileTool,
  ListAllFilesTool,
  FindFilesByGlobTool,
  FindFilesContainingTool,
  FindLinesMatchingTool,
  CreateDirectoryTool
}

# Create a temporary directory for the example
sandbox_dir = System.tmp_dir!() |> Path.join("mojentic_file_tool_example")
File.mkdir_p!(sandbox_dir)

IO.puts("Sandbox directory: #{sandbox_dir}")
IO.puts("")

# Create a FilesystemGateway
{:ok, fs} = FilesystemGateway.new(sandbox_dir)

# Create some example files
File.write!(Path.join(sandbox_dir, "example.txt"), "Hello, world!\nThis is an example file.\n")
File.write!(Path.join(sandbox_dir, "test.py"), "def main():\n    print('Hello')\n")

src_dir = Path.join(sandbox_dir, "src")
File.mkdir_p!(src_dir)
File.write!(Path.join(src_dir, "module.py"), "class MyClass:\n    pass\n")

IO.puts("Created example files")
IO.puts("")

# Example 1: List files in root directory
IO.puts("Example 1: List files in root directory")
list_tool = ListFilesTool.new(fs)
{:ok, files} = ListFilesTool.run(list_tool, %{"path" => "."})
IO.inspect(files, label: "Files in root")
IO.puts("")

# Example 2: Read a file
IO.puts("Example 2: Read a file")
read_tool = ReadFileTool.new(fs)
{:ok, content} = ReadFileTool.run(read_tool, %{"path" => "example.txt"})
IO.puts("Content of example.txt:")
IO.puts(content)
IO.puts("")

# Example 3: Write a file
IO.puts("Example 3: Write a file")
write_tool = WriteFileTool.new(fs)
{:ok, message} = WriteFileTool.run(write_tool, %{"path" => "output.txt", "content" => "New file content\n"})
IO.puts(message)
IO.puts("")

# Example 4: List all files recursively
IO.puts("Example 4: List all files recursively")
list_all_tool = ListAllFilesTool.new(fs)
{:ok, all_files} = ListAllFilesTool.run(list_all_tool, %{"path" => "."})
IO.inspect(all_files, label: "All files (recursive)")
IO.puts("")

# Example 5: Find files by glob pattern
IO.puts("Example 5: Find files by glob pattern")
glob_tool = FindFilesByGlobTool.new(fs)
{:ok, py_files} = FindFilesByGlobTool.run(glob_tool, %{"path" => ".", "pattern" => "**/*.py"})
IO.inspect(py_files, label: "Python files")
IO.puts("")

# Example 6: Find files containing pattern
IO.puts("Example 6: Find files containing pattern")
containing_tool = FindFilesContainingTool.new(fs)
{:ok, files_with_class} = FindFilesContainingTool.run(containing_tool, %{"path" => ".", "pattern" => "class"})
IO.inspect(files_with_class, label: "Files containing 'class'")
IO.puts("")

# Example 7: Find lines matching pattern
IO.puts("Example 7: Find lines matching pattern")
lines_tool = FindLinesMatchingTool.new(fs)
{:ok, matching_lines} = FindLinesMatchingTool.run(lines_tool, %{"path" => "src/module.py", "pattern" => "class"})
IO.inspect(matching_lines, label: "Lines containing 'class' in module.py")
IO.puts("")

# Example 8: Create a directory
IO.puts("Example 8: Create a directory")
mkdir_tool = CreateDirectoryTool.new(fs)
{:ok, mkdir_message} = CreateDirectoryTool.run(mkdir_tool, %{"path" => "new_directory"})
IO.puts(mkdir_message)
IO.puts("")

# Example 9: Use file tools with LLM
IO.puts("Example 9: Use file tools with LLM")
IO.puts("Setting up LLM broker with file tools...")

{:ok, gateway} = Ollama.new()
broker = Broker.new("qwen2.5:7b", gateway)

tools = [
  list_tool,
  read_tool,
  write_tool,
  list_all_tool,
  glob_tool,
  containing_tool,
  lines_tool,
  mkdir_tool
]

messages = [
  Message.system("You are a helpful assistant with access to file system tools. The sandbox root is #{sandbox_dir}."),
  Message.user("What Python files are in the sandbox? Read one of them and tell me what it does.")
]

IO.puts("Asking LLM: '#{List.last(messages).content}'")
IO.puts("")

case Broker.generate(broker, messages, tools: tools) do
  {:ok, response} ->
    IO.puts("LLM Response:")
    IO.puts(response.content)

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end

IO.puts("")

# Cleanup
IO.puts("Cleaning up sandbox directory...")
File.rm_rf!(sandbox_dir)
IO.puts("Done!")
