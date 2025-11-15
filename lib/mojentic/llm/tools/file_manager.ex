defmodule Mojentic.LLM.Tools.FilesystemGateway do
  @moduledoc """
  A gateway for interacting with the filesystem within a sandboxed base path.

  This module provides safe filesystem operations that are restricted to a
  specific base directory, preventing path traversal attacks.
  """

  defstruct [:base_path]

  @type t :: %__MODULE__{
          base_path: String.t()
        }

  @doc """
  Creates a new FilesystemGateway with the specified base path.
  """
  @spec new(String.t()) :: {:ok, t()} | {:error, String.t()}
  def new(base_path) do
    case File.dir?(base_path) do
      true -> {:ok, %__MODULE__{base_path: Path.expand(base_path)}}
      false -> {:error, "Base path #{base_path} is not a directory"}
    end
  end

  @doc """
  Resolves a path relative to the base path and ensures it stays within the sandbox.
  """
  @spec resolve_path(t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_path(%__MODULE__{base_path: base_path}, path) do
    resolved = Path.join(base_path, path) |> Path.expand()
    normalized_base = Path.expand(base_path)

    if String.starts_with?(resolved, normalized_base) do
      {:ok, resolved}
    else
      {:error, "Path #{path} attempts to escape the sandbox"}
    end
  end

  @doc """
  Lists files in a directory (non-recursive).
  """
  @spec ls(t(), String.t()) :: {:ok, list(String.t())} | {:error, String.t()}
  def ls(%__MODULE__{base_path: base_path} = fs, path) do
    with {:ok, resolved_path} <- resolve_path(fs, path),
         {:ok, files} <- File.ls(resolved_path) do
      relative_files =
        files
        |> Enum.map(fn file ->
          Path.join(resolved_path, file)
          |> Path.relative_to(base_path)
        end)

      {:ok, relative_files}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "File error: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists all files recursively in a directory.
  """
  @spec list_all_files(t(), String.t()) :: {:ok, list(String.t())} | {:error, String.t()}
  def list_all_files(%__MODULE__{base_path: base_path} = fs, path) do
    with {:ok, resolved_path} <- resolve_path(fs, path) do
      files = collect_files_recursively(resolved_path, base_path)
      {:ok, files}
    end
  end

  defp collect_files_recursively(dir, base_path) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full_path = Path.join(dir, entry)

          if File.dir?(full_path) do
            collect_files_recursively(full_path, base_path)
          else
            [Path.relative_to(full_path, base_path)]
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Finds files matching a glob pattern.
  """
  @spec find_files_by_glob(t(), String.t(), String.t()) ::
          {:ok, list(String.t())} | {:error, String.t()}
  def find_files_by_glob(%__MODULE__{base_path: base_path} = fs, path, pattern) do
    with {:ok, resolved_path} <- resolve_path(fs, path) do
      glob_pattern = Path.join(resolved_path, pattern)

      files =
        glob_pattern
        |> Path.wildcard()
        |> Enum.map(&Path.relative_to(&1, base_path))

      {:ok, files}
    end
  end

  @doc """
  Finds files containing text matching a regex pattern.
  """
  @spec find_files_containing(t(), String.t(), String.t()) ::
          {:ok, list(String.t())} | {:error, String.t()}
  def find_files_containing(%__MODULE__{base_path: base_path} = fs, path, pattern) do
    with {:ok, resolved_path} <- resolve_path(fs, path),
         {:ok, regex} <- Regex.compile(pattern) do
      files = find_matching_files(resolved_path, regex, base_path)
      {:ok, files}
    else
      {:error, {reason, _}} ->
        {:error, "Invalid regex pattern: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_matching_files(dir, regex, base_path) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full_path = Path.join(dir, entry)

          cond do
            File.dir?(full_path) ->
              find_matching_files(full_path, regex, base_path)

            File.regular?(full_path) ->
              case File.read(full_path) do
                {:ok, content} ->
                  if Regex.match?(regex, content) do
                    [Path.relative_to(full_path, base_path)]
                  else
                    []
                  end

                {:error, _} ->
                  []
              end

            true ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Finds all lines in a file matching a regex pattern.
  """
  @spec find_lines_matching(t(), String.t(), String.t(), String.t()) ::
          {:ok, list(map())} | {:error, String.t()}
  def find_lines_matching(fs, path, file_name, pattern) do
    with {:ok, resolved_path} <- resolve_path(fs, path),
         {:ok, regex} <- Regex.compile(pattern) do
      file_path = Path.join(resolved_path, file_name)

      case File.read(file_path) do
        {:ok, content} ->
          matching_lines =
            content
            |> String.split("\n")
            |> Enum.with_index(1)
            |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
            |> Enum.map(fn {line, line_number} ->
              %{line_number: line_number, content: line}
            end)

          {:ok, matching_lines}

        {:error, reason} ->
          {:error, "Error reading file #{file_name}: #{inspect(reason)}"}
      end
    else
      {:error, {reason, _}} ->
        {:error, "Invalid regex pattern: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads the content of a file.
  """
  @spec read(t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(fs, path, file_name) do
    with {:ok, resolved_path} <- resolve_path(fs, path) do
      file_path = Path.join(resolved_path, file_name)

      case File.read(file_path) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, "Error reading file: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Writes content to a file.
  """
  @spec write(t(), String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def write(fs, path, file_name, content) do
    with {:ok, resolved_path} <- resolve_path(fs, path) do
      file_path = Path.join(resolved_path, file_name)

      case File.write(file_path, content) do
        :ok -> :ok
        {:error, reason} -> {:error, "Error writing file: #{inspect(reason)}"}
      end
    end
  end
end

defmodule Mojentic.LLM.Tools.ListFilesTool do
  @moduledoc """
  Tool for listing files in a directory (non-recursive).
  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.FilesystemGateway

  defstruct [:fs]

  @type t :: %__MODULE__{
          fs: FilesystemGateway.t()
        }

  @spec new(FilesystemGateway.t()) :: t()
  def new(fs), do: %__MODULE__{fs: fs}

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "list_files",
        description:
          "List files in the specified directory (non-recursive), optionally filtered by extension. Use this when you need to see what files are available in a specific directory without including subdirectories.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description:
                "The path relative to the sandbox root to list files from. For example, '.' for the root directory, 'src' for the src directory, or 'docs/images' for a nested directory."
            },
            extension: %{
              type: "string",
              description:
                "The file extension to filter by (e.g., '.py', '.txt', '.md'). If not provided, all files will be listed. For example, using '.py' will only list Python files in the directory."
            }
          },
          additionalProperties: false,
          required: ["path"]
        }
      }
    }
  end

  @impl true
  def run(%__MODULE__{fs: fs}, args) do
    path = Map.get(args, "path")
    extension = Map.get(args, "extension")

    case FilesystemGateway.ls(fs, path) do
      {:ok, files} ->
        filtered =
          if extension do
            Enum.filter(files, &String.ends_with?(&1, extension))
          else
            files
          end

        {:ok, filtered}

      {:error, reason} ->
        {:error, "Error listing files in '#{path}': #{reason}"}
    end
  end
end

defmodule Mojentic.LLM.Tools.ReadFileTool do
  @moduledoc """
  Tool for reading the entire content of a file.
  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.FilesystemGateway

  defstruct [:fs]

  @type t :: %__MODULE__{
          fs: FilesystemGateway.t()
        }

  @spec new(FilesystemGateway.t()) :: t()
  def new(fs), do: %__MODULE__{fs: fs}

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "read_file",
        description:
          "Read the entire content of a file as a string. Use this when you need to access or analyze the complete contents of a file.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description:
                "The full relative path including the filename of the file to read. For example, 'README.md' for a file in the root directory, 'src/main.py' for a file in the src directory, or 'docs/images/diagram.png' for a file in a nested directory."
            }
          },
          additionalProperties: false,
          required: ["path"]
        }
      }
    }
  end

  @impl true
  def run(%__MODULE__{fs: fs}, args) do
    path = Map.get(args, "path")
    {directory, file_name} = split_path(path)

    case FilesystemGateway.read(fs, directory, file_name) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Error reading file '#{path}': #{reason}"}
    end
  end

  defp split_path(path) do
    directory = Path.dirname(path)
    file_name = Path.basename(path)
    {directory, file_name}
  end
end

defmodule Mojentic.LLM.Tools.WriteFileTool do
  @moduledoc """
  Tool for writing content to a file, completely overwriting any existing content.
  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.FilesystemGateway

  defstruct [:fs]

  @type t :: %__MODULE__{
          fs: FilesystemGateway.t()
        }

  @spec new(FilesystemGateway.t()) :: t()
  def new(fs), do: %__MODULE__{fs: fs}

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "write_file",
        description:
          "Write content to a file, completely overwriting any existing content. Use this when you want to replace the entire contents of a file with new content.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description:
                "The full relative path including the filename where the file should be written. For example, 'output.txt' for a file in the root directory, 'src/main.py' for a file in the src directory, or 'docs/images/diagram.png' for a file in a nested directory."
            },
            content: %{
              type: "string",
              description:
                "The content to write to the file. This will completely replace any existing content in the file. For example, 'Hello, world!' for a simple text file, or a JSON string for a configuration file."
            }
          },
          additionalProperties: false,
          required: ["path", "content"]
        }
      }
    }
  end

  @impl true
  def run(%__MODULE__{fs: fs}, args) do
    path = Map.get(args, "path")
    content = Map.get(args, "content")
    {directory, file_name} = split_path(path)

    case FilesystemGateway.write(fs, directory, file_name, content) do
      :ok -> {:ok, "Successfully wrote to #{path}"}
      {:error, reason} -> {:error, "Error writing to file '#{path}': #{reason}"}
    end
  end

  defp split_path(path) do
    directory = Path.dirname(path)
    file_name = Path.basename(path)
    {directory, file_name}
  end
end

defmodule Mojentic.LLM.Tools.ListAllFilesTool do
  @moduledoc """
  Tool for listing all files recursively in a directory.
  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.FilesystemGateway

  defstruct [:fs]

  @type t :: %__MODULE__{
          fs: FilesystemGateway.t()
        }

  @spec new(FilesystemGateway.t()) :: t()
  def new(fs), do: %__MODULE__{fs: fs}

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "list_all_files",
        description:
          "List all files recursively in the specified directory, including files in subdirectories. Use this when you need a complete inventory of all files in a directory and its subdirectories.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description:
                "The path relative to the sandbox root to list files from recursively. For example, '.' for the root directory and all subdirectories, 'src' for the src directory and all its subdirectories, or 'docs/images' for a nested directory and its subdirectories."
            }
          },
          additionalProperties: false,
          required: ["path"]
        }
      }
    }
  end

  @impl true
  def run(%__MODULE__{fs: fs}, args) do
    path = Map.get(args, "path")

    case FilesystemGateway.list_all_files(fs, path) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, "Error listing files recursively in '#{path}': #{reason}"}
    end
  end
end

defmodule Mojentic.LLM.Tools.FindFilesByGlobTool do
  @moduledoc """
  Tool for finding files matching a glob pattern.
  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.FilesystemGateway

  defstruct [:fs]

  @type t :: %__MODULE__{
          fs: FilesystemGateway.t()
        }

  @spec new(FilesystemGateway.t()) :: t()
  def new(fs), do: %__MODULE__{fs: fs}

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "find_files_by_glob",
        description:
          "Find files matching a glob pattern in the specified directory. Use this when you need to locate files with specific patterns in their names or paths (e.g., all Python files with '*.py' or all text files in any subdirectory with '**/*.txt').",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description:
                "The path relative to the sandbox root to search in. For example, '.' for the root directory, 'src' for the src directory, or 'docs/images' for a nested directory."
            },
            pattern: %{
              type: "string",
              description:
                "The glob pattern to match files against. Examples: '*.py' for all Python files in the specified directory, '**/*.txt' for all text files in the specified directory and any subdirectory, or '**/*test*.py' for all Python files with 'test' in their name in the specified directory and any subdirectory."
            }
          },
          additionalProperties: false,
          required: ["path", "pattern"]
        }
      }
    }
  end

  @impl true
  def run(%__MODULE__{fs: fs}, args) do
    path = Map.get(args, "path")
    pattern = Map.get(args, "pattern")

    case FilesystemGateway.find_files_by_glob(fs, path, pattern) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, "Error finding files with pattern '#{pattern}' in '#{path}': #{reason}"}
    end
  end
end

defmodule Mojentic.LLM.Tools.FindFilesContainingTool do
  @moduledoc """
  Tool for finding files containing text matching a regex pattern.
  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.FilesystemGateway

  defstruct [:fs]

  @type t :: %__MODULE__{
          fs: FilesystemGateway.t()
        }

  @spec new(FilesystemGateway.t()) :: t()
  def new(fs), do: %__MODULE__{fs: fs}

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "find_files_containing",
        description:
          "Find files containing text matching a regex pattern in the specified directory. Use this when you need to search for specific content across multiple files, such as finding all files that contain a particular function name or text string.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description:
                "The path relative to the sandbox root to search in. For example, '.' for the root directory, 'src' for the src directory, or 'docs/images' for a nested directory."
            },
            pattern: %{
              type: "string",
              description:
                "The regex pattern to search for in files. Examples: 'function\\s+main' to find files containing a main function, 'import\\s+os' to find files importing the os module, or 'TODO|FIXME' to find files containing TODO or FIXME comments. The pattern uses Elixir's Regex module syntax."
            }
          },
          additionalProperties: false,
          required: ["path", "pattern"]
        }
      }
    }
  end

  @impl true
  def run(%__MODULE__{fs: fs}, args) do
    path = Map.get(args, "path")
    pattern = Map.get(args, "pattern")

    case FilesystemGateway.find_files_containing(fs, path, pattern) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, "Error finding files containing pattern '#{pattern}' in '#{path}': #{reason}"}
    end
  end
end

defmodule Mojentic.LLM.Tools.FindLinesMatchingTool do
  @moduledoc """
  Tool for finding all lines in a file matching a regex pattern.
  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.FilesystemGateway

  defstruct [:fs]

  @type t :: %__MODULE__{
          fs: FilesystemGateway.t()
        }

  @spec new(FilesystemGateway.t()) :: t()
  def new(fs), do: %__MODULE__{fs: fs}

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "find_lines_matching",
        description:
          "Find all lines in a file matching a regex pattern, returning both line numbers and content. Use this when you need to locate specific patterns within a single file and need to know exactly where they appear.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description:
                "The full relative path including the filename of the file to search in. For example, 'README.md' for a file in the root directory, 'src/main.py' for a file in the src directory, or 'docs/images/diagram.png' for a file in a nested directory."
            },
            pattern: %{
              type: "string",
              description:
                "The regex pattern to match lines against. Examples: 'def\\s+\\w+' to find all function definitions, 'class\\s+\\w+' to find all class definitions, or 'TODO|FIXME' to find all TODO or FIXME comments. The pattern uses Elixir's Regex module syntax."
            }
          },
          additionalProperties: false,
          required: ["path", "pattern"]
        }
      }
    }
  end

  @impl true
  def run(%__MODULE__{fs: fs}, args) do
    path = Map.get(args, "path")
    pattern = Map.get(args, "pattern")
    {directory, file_name} = split_path(path)

    case FilesystemGateway.find_lines_matching(fs, directory, file_name, pattern) do
      {:ok, lines} -> {:ok, lines}
      {:error, reason} -> {:error, "Error finding lines matching pattern '#{pattern}' in file '#{path}': #{reason}"}
    end
  end

  defp split_path(path) do
    directory = Path.dirname(path)
    file_name = Path.basename(path)
    {directory, file_name}
  end
end

defmodule Mojentic.LLM.Tools.CreateDirectoryTool do
  @moduledoc """
  Tool for creating a new directory.
  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.FilesystemGateway

  defstruct [:fs]

  @type t :: %__MODULE__{
          fs: FilesystemGateway.t()
        }

  @spec new(FilesystemGateway.t()) :: t()
  def new(fs), do: %__MODULE__{fs: fs}

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "create_directory",
        description:
          "Create a new directory at the specified path. If the directory already exists, this operation will succeed without error. Use this when you need to create a directory structure before writing files to it.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description:
                "The relative path where the directory should be created. For example, 'new_folder' for a directory in the root, 'src/new_folder' for a directory in the src directory, or 'docs/images/new_folder' for a nested directory. Parent directories will be created automatically if they don't exist."
            }
          },
          additionalProperties: false,
          required: ["path"]
        }
      }
    }
  end

  @impl true
  def run(%__MODULE__{fs: fs}, args) do
    path = Map.get(args, "path")

    case FilesystemGateway.resolve_path(fs, path) do
      {:ok, resolved_path} ->
        case File.mkdir_p(resolved_path) do
          :ok -> {:ok, "Successfully created directory '#{path}'"}
          {:error, reason} -> {:error, "Error creating directory '#{path}': #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
