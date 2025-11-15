defmodule Mojentic.LLM.Tools.FileManagerTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Tools.FilesystemGateway
  alias Mojentic.LLM.Tools.CreateDirectoryTool
  alias Mojentic.LLM.Tools.FindFilesByGlobTool
  alias Mojentic.LLM.Tools.FindFilesContainingTool
  alias Mojentic.LLM.Tools.FindLinesMatchingTool
  alias Mojentic.LLM.Tools.ListAllFilesTool
  alias Mojentic.LLM.Tools.ListFilesTool
  alias Mojentic.LLM.Tools.ReadFileTool
  alias Mojentic.LLM.Tools.WriteFileTool

  setup do
    # Create a temporary directory for testing
    base_path = System.tmp_dir!() |> Path.join("mojentic_file_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(base_path)

    on_exit(fn ->
      File.rm_rf!(base_path)
    end)

    {:ok, fs} = FilesystemGateway.new(base_path)
    %{fs: fs, base_path: base_path}
  end

  describe "FilesystemGateway.new/1" do
    test "creates gateway with valid directory path", %{base_path: base_path} do
      assert {:ok, %FilesystemGateway{base_path: path}} = FilesystemGateway.new(base_path)
      assert String.contains?(path, "mojentic_file_test")
    end

    test "returns error for non-existent directory" do
      assert {:error, msg} = FilesystemGateway.new("/nonexistent/path")
      assert String.contains?(msg, "not a directory")
    end
  end

  describe "FilesystemGateway.resolve_path/2" do
    test "resolves valid relative paths", %{fs: fs} do
      assert {:ok, path} = FilesystemGateway.resolve_path(fs, "test.txt")
      assert String.ends_with?(path, "test.txt")
    end

    test "prevents path traversal attacks", %{fs: fs} do
      assert {:error, msg} = FilesystemGateway.resolve_path(fs, "../../../etc/passwd")
      assert String.contains?(msg, "escape the sandbox")
    end

    test "handles nested paths", %{fs: fs} do
      assert {:ok, path} = FilesystemGateway.resolve_path(fs, "sub/dir/file.txt")
      assert String.ends_with?(path, "sub/dir/file.txt")
    end
  end

  describe "FilesystemGateway.ls/2" do
    test "lists files in directory", %{fs: fs, base_path: base_path} do
      File.write!(Path.join(base_path, "file1.txt"), "content")
      File.write!(Path.join(base_path, "file2.txt"), "content")

      assert {:ok, files} = FilesystemGateway.ls(fs, ".")
      assert length(files) == 2
      assert "file1.txt" in files
      assert "file2.txt" in files
    end

    test "returns error for non-existent directory", %{fs: fs} do
      assert {:error, msg} = FilesystemGateway.ls(fs, "nonexistent")
      assert String.contains?(msg, "error")
    end

    test "lists files in subdirectory", %{fs: fs, base_path: base_path} do
      subdir = Path.join(base_path, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "nested.txt"), "content")

      assert {:ok, files} = FilesystemGateway.ls(fs, "subdir")
      assert "subdir/nested.txt" in files
    end
  end

  describe "FilesystemGateway.list_all_files/2" do
    test "recursively lists all files", %{fs: fs, base_path: base_path} do
      File.write!(Path.join(base_path, "root.txt"), "content")
      subdir = Path.join(base_path, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "nested.txt"), "content")

      assert {:ok, files} = FilesystemGateway.list_all_files(fs, ".")
      assert length(files) == 2
      assert "root.txt" in files
      assert "subdir/nested.txt" in files
    end

    test "returns empty list for empty directory", %{fs: fs} do
      assert {:ok, []} = FilesystemGateway.list_all_files(fs, ".")
    end

    test "handles deeply nested structures", %{fs: fs, base_path: base_path} do
      deep_path = Path.join([base_path, "a", "b", "c"])
      File.mkdir_p!(deep_path)
      File.write!(Path.join(deep_path, "deep.txt"), "content")

      assert {:ok, files} = FilesystemGateway.list_all_files(fs, ".")
      assert "a/b/c/deep.txt" in files
    end
  end

  describe "FilesystemGateway.find_files_by_glob/3" do
    test "finds files matching pattern", %{fs: fs, base_path: base_path} do
      File.write!(Path.join(base_path, "test.txt"), "content")
      File.write!(Path.join(base_path, "test.md"), "content")
      File.write!(Path.join(base_path, "other.txt"), "content")

      assert {:ok, files} = FilesystemGateway.find_files_by_glob(fs, ".", "test.*")
      assert length(files) == 2
      assert "test.txt" in files
      assert "test.md" in files
    end

    test "handles recursive glob patterns", %{fs: fs, base_path: base_path} do
      subdir = Path.join(base_path, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(base_path, "root.txt"), "content")
      File.write!(Path.join(subdir, "nested.txt"), "content")

      assert {:ok, files} = FilesystemGateway.find_files_by_glob(fs, ".", "**/*.txt")
      assert length(files) == 2
    end
  end

  describe "FilesystemGateway.find_files_containing/3" do
    test "finds files containing text pattern", %{fs: fs, base_path: base_path} do
      File.write!(Path.join(base_path, "match.txt"), "contains needle here")
      File.write!(Path.join(base_path, "nomatch.txt"), "no pattern here")

      assert {:ok, files} = FilesystemGateway.find_files_containing(fs, ".", "needle")
      assert ["match.txt"] = files
    end

    test "handles regex patterns", %{fs: fs, base_path: base_path} do
      File.write!(Path.join(base_path, "test1.txt"), "function test()")
      File.write!(Path.join(base_path, "test2.txt"), "function other()")
      File.write!(Path.join(base_path, "test3.txt"), "no functions")

      assert {:ok, files} = FilesystemGateway.find_files_containing(fs, ".", "function\\s+\\w+")
      assert length(files) == 2
    end

    test "returns error for invalid regex", %{fs: fs} do
      assert {:error, msg} = FilesystemGateway.find_files_containing(fs, ".", "[invalid(")
      assert String.contains?(msg, "regex")
    end

    test "searches recursively", %{fs: fs, base_path: base_path} do
      subdir = Path.join(base_path, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "nested.txt"), "find this")

      assert {:ok, files} = FilesystemGateway.find_files_containing(fs, ".", "find this")
      assert ["subdir/nested.txt"] = files
    end
  end

  describe "FilesystemGateway.find_lines_matching/4" do
    test "finds matching lines with line numbers", %{fs: fs, base_path: base_path} do
      content = """
      line 1
      match this line
      line 3
      another match line
      """

      File.write!(Path.join(base_path, "test.txt"), content)

      assert {:ok, matches} = FilesystemGateway.find_lines_matching(fs, ".", "test.txt", "match")
      assert length(matches) == 2
      assert %{line_number: 2, content: "match this line"} in matches
      assert %{line_number: 4, content: "another match line"} in matches
    end

    test "returns empty list when no matches", %{fs: fs, base_path: base_path} do
      File.write!(Path.join(base_path, "test.txt"), "no patterns here")

      assert {:ok, []} = FilesystemGateway.find_lines_matching(fs, ".", "test.txt", "needle")
    end

    test "handles regex patterns", %{fs: fs, base_path: base_path} do
      content = """
      def function1():
      class MyClass:
      def function2():
      """

      File.write!(Path.join(base_path, "test.txt"), content)

      assert {:ok, matches} = FilesystemGateway.find_lines_matching(fs, ".", "test.txt", "def\\s+")
      assert length(matches) == 2
    end

    test "returns error for invalid regex", %{fs: fs, base_path: base_path} do
      File.write!(Path.join(base_path, "test.txt"), "content")

      assert {:error, msg} = FilesystemGateway.find_lines_matching(fs, ".", "test.txt", "[invalid")
      assert String.contains?(msg, "regex")
    end

    test "returns error for non-existent file", %{fs: fs} do
      assert {:error, msg} = FilesystemGateway.find_lines_matching(fs, ".", "nonexistent.txt", "pattern")
      assert String.contains?(msg, "Error reading file")
    end
  end

  describe "FilesystemGateway.read/3" do
    test "reads file content", %{fs: fs, base_path: base_path} do
      content = "Hello, World!"
      File.write!(Path.join(base_path, "test.txt"), content)

      assert {:ok, ^content} = FilesystemGateway.read(fs, ".", "test.txt")
    end

    test "returns error for non-existent file", %{fs: fs} do
      assert {:error, msg} = FilesystemGateway.read(fs, ".", "nonexistent.txt")
      assert String.contains?(msg, "Error reading file")
    end

    test "reads from subdirectory", %{fs: fs, base_path: base_path} do
      subdir = Path.join(base_path, "subdir")
      File.mkdir_p!(subdir)
      content = "nested content"
      File.write!(Path.join(subdir, "nested.txt"), content)

      assert {:ok, ^content} = FilesystemGateway.read(fs, "subdir", "nested.txt")
    end
  end

  describe "FilesystemGateway.write/4" do
    test "writes content to file", %{fs: fs, base_path: base_path} do
      content = "New content"
      assert :ok = FilesystemGateway.write(fs, ".", "new.txt", content)

      written = File.read!(Path.join(base_path, "new.txt"))
      assert written == content
    end

    test "overwrites existing file", %{fs: fs, base_path: base_path} do
      File.write!(Path.join(base_path, "test.txt"), "old")
      assert :ok = FilesystemGateway.write(fs, ".", "test.txt", "new")

      assert File.read!(Path.join(base_path, "test.txt")) == "new"
    end

    test "writes to subdirectory", %{fs: fs, base_path: base_path} do
      subdir = Path.join(base_path, "subdir")
      File.mkdir_p!(subdir)

      assert :ok = FilesystemGateway.write(fs, "subdir", "nested.txt", "content")
      assert File.read!(Path.join(subdir, "nested.txt")) == "content"
    end

    test "returns error for invalid path", %{fs: fs} do
      assert {:error, msg} = FilesystemGateway.write(fs, "../escape", "test.txt", "content")
      assert String.contains?(msg, "sandbox")
    end
  end

  describe "ListFilesTool" do
    test "has correct descriptor" do
      fs = %FilesystemGateway{base_path: "/tmp"}
      tool = ListFilesTool.new(fs)
      descriptor = ListFilesTool.descriptor()

      assert descriptor[:type] == "function"
      assert descriptor[:function][:name] == "list_files"
      assert is_binary(descriptor[:function][:description])
    end

    test "lists files in directory", %{fs: fs, base_path: base_path} do
      File.write!(Path.join(base_path, "file1.txt"), "content")
      File.write!(Path.join(base_path, "file2.md"), "content")

      tool = ListFilesTool.new(fs)
      assert {:ok, files} = ListFilesTool.run(tool, %{"path" => "."})
      assert length(files) == 2
    end

    test "filters by extension", %{fs: fs, base_path: base_path} do
      File.write!(Path.join(base_path, "file1.txt"), "content")
      File.write!(Path.join(base_path, "file2.md"), "content")
      File.write!(Path.join(base_path, "file3.txt"), "content")

      tool = ListFilesTool.new(fs)
      assert {:ok, files} = ListFilesTool.run(tool, %{"path" => ".", "extension" => ".txt"})
      assert length(files) == 2
      assert Enum.all?(files, &String.ends_with?(&1, ".txt"))
    end

    test "returns error for invalid path", %{fs: fs} do
      tool = ListFilesTool.new(fs)
      assert {:error, msg} = ListFilesTool.run(tool, %{"path" => "nonexistent"})
      assert String.contains?(msg, "Error listing files")
    end
  end

  describe "ReadFileTool" do
    test "has correct descriptor" do
      descriptor = ReadFileTool.descriptor()

      assert descriptor[:type] == "function"
      assert descriptor[:function][:name] == "read_file"
    end

    test "reads file content", %{fs: fs, base_path: base_path} do
      content = "File content here"
      File.write!(Path.join(base_path, "test.txt"), content)

      tool = ReadFileTool.new(fs)
      assert {:ok, ^content} = ReadFileTool.run(tool, %{"path" => "test.txt"})
    end

    test "reads file from subdirectory", %{fs: fs, base_path: base_path} do
      subdir = Path.join(base_path, "subdir")
      File.mkdir_p!(subdir)
      content = "nested"
      File.write!(Path.join(subdir, "nested.txt"), content)

      tool = ReadFileTool.new(fs)
      assert {:ok, ^content} = ReadFileTool.run(tool, %{"path" => "subdir/nested.txt"})
    end

    test "returns error for non-existent file", %{fs: fs} do
      tool = ReadFileTool.new(fs)
      assert {:error, msg} = ReadFileTool.run(tool, %{"path" => "nonexistent.txt"})
      assert String.contains?(msg, "Error reading file")
    end
  end

  describe "WriteFileTool" do
    test "has correct descriptor" do
      descriptor = WriteFileTool.descriptor()

      assert descriptor[:type] == "function"
      assert descriptor[:function][:name] == "write_file"
    end

    test "writes content to file", %{fs: fs, base_path: base_path} do
      tool = WriteFileTool.new(fs)
      content = "New file content"

      assert {:ok, msg} = WriteFileTool.run(tool, %{"path" => "new.txt", "content" => content})
      assert String.contains?(msg, "Successfully wrote")

      assert File.read!(Path.join(base_path, "new.txt")) == content
    end

    test "writes to nested path", %{fs: fs, base_path: base_path} do
      subdir = Path.join(base_path, "subdir")
      File.mkdir_p!(subdir)

      tool = WriteFileTool.new(fs)
      assert {:ok, _msg} = WriteFileTool.run(tool, %{"path" => "subdir/file.txt", "content" => "test"})

      assert File.read!(Path.join(subdir, "file.txt")) == "test"
    end

    test "overwrites existing file", %{fs: fs, base_path: base_path} do
      File.write!(Path.join(base_path, "test.txt"), "old")

      tool = WriteFileTool.new(fs)
      assert {:ok, _msg} = WriteFileTool.run(tool, %{"path" => "test.txt", "content" => "new"})

      assert File.read!(Path.join(base_path, "test.txt")) == "new"
    end
  end

  describe "ListAllFilesTool" do
    test "has correct descriptor" do
      descriptor = ListAllFilesTool.descriptor()

      assert descriptor[:type] == "function"
      assert descriptor[:function][:name] == "list_all_files"
    end

    test "lists all files recursively", %{fs: fs, base_path: base_path} do
      File.write!(Path.join(base_path, "root.txt"), "content")
      subdir = Path.join(base_path, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "nested.txt"), "content")

      tool = ListAllFilesTool.new(fs)
      assert {:ok, files} = ListAllFilesTool.run(tool, %{"path" => "."})
      assert length(files) == 2
      assert "root.txt" in files
      assert "subdir/nested.txt" in files
    end
  end

  describe "FindFilesByGlobTool" do
    test "has correct descriptor" do
      descriptor = FindFilesByGlobTool.descriptor()

      assert descriptor[:type] == "function"
      assert descriptor[:function][:name] == "find_files_by_glob"
    end

    test "finds files by glob pattern", %{fs: fs, base_path: base_path} do
      File.write!(Path.join(base_path, "test1.txt"), "content")
      File.write!(Path.join(base_path, "test2.txt"), "content")
      File.write!(Path.join(base_path, "other.md"), "content")

      tool = FindFilesByGlobTool.new(fs)
      assert {:ok, files} = FindFilesByGlobTool.run(tool, %{"path" => ".", "pattern" => "*.txt"})
      assert length(files) == 2
    end
  end

  describe "FindFilesContainingTool" do
    test "has correct descriptor" do
      descriptor = FindFilesContainingTool.descriptor()

      assert descriptor[:type] == "function"
      assert descriptor[:function][:name] == "find_files_containing"
    end

    test "finds files containing pattern", %{fs: fs, base_path: base_path} do
      File.write!(Path.join(base_path, "match.txt"), "contains target text")
      File.write!(Path.join(base_path, "nomatch.txt"), "other content")

      tool = FindFilesContainingTool.new(fs)
      assert {:ok, files} = FindFilesContainingTool.run(tool, %{"path" => ".", "pattern" => "target"})
      assert ["match.txt"] = files
    end

    test "returns error for invalid regex", %{fs: fs} do
      tool = FindFilesContainingTool.new(fs)
      assert {:error, msg} = FindFilesContainingTool.run(tool, %{"path" => ".", "pattern" => "[invalid"})
      assert String.contains?(msg, "Error finding files")
    end
  end

  describe "FindLinesMatchingTool" do
    test "has correct descriptor" do
      descriptor = FindLinesMatchingTool.descriptor()

      assert descriptor[:type] == "function"
      assert descriptor[:function][:name] == "find_lines_matching"
    end

    test "finds matching lines", %{fs: fs, base_path: base_path} do
      content = "line 1\nmatch here\nline 3\nmatch again"
      File.write!(Path.join(base_path, "test.txt"), content)

      tool = FindLinesMatchingTool.new(fs)
      assert {:ok, matches} = FindLinesMatchingTool.run(tool, %{"path" => "test.txt", "pattern" => "match"})
      assert length(matches) == 2
    end
  end

  describe "CreateDirectoryTool" do
    test "has correct descriptor" do
      descriptor = CreateDirectoryTool.descriptor()

      assert descriptor[:type] == "function"
      assert descriptor[:function][:name] == "create_directory"
    end

    test "creates directory", %{fs: fs, base_path: base_path} do
      tool = CreateDirectoryTool.new(fs)
      assert {:ok, msg} = CreateDirectoryTool.run(tool, %{"path" => "newdir"})
      assert String.contains?(msg, "Successfully created")

      assert File.dir?(Path.join(base_path, "newdir"))
    end

    test "creates nested directories", %{fs: fs, base_path: base_path} do
      tool = CreateDirectoryTool.new(fs)
      assert {:ok, _msg} = CreateDirectoryTool.run(tool, %{"path" => "a/b/c"})

      assert File.dir?(Path.join([base_path, "a", "b", "c"]))
    end

    test "succeeds if directory already exists", %{fs: fs, base_path: base_path} do
      newdir = Path.join(base_path, "existing")
      File.mkdir_p!(newdir)

      tool = CreateDirectoryTool.new(fs)
      assert {:ok, _msg} = CreateDirectoryTool.run(tool, %{"path" => "existing"})
    end

    test "returns error for path traversal", %{fs: fs} do
      tool = CreateDirectoryTool.new(fs)
      assert {:error, msg} = CreateDirectoryTool.run(tool, %{"path" => "../escape"})
      assert String.contains?(msg, "sandbox")
    end
  end
end
