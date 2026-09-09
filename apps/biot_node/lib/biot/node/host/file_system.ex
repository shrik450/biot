defmodule Biot.Node.Host.FileSystem do
  @moduledoc "Owns atomic node-private file writes and filesystem inspection results."

  alias Biot.Protocol.CanonicalUuid

  @type fact(value) :: :absent | {:present, value} | {:error, File.posix() | term()}

  @spec directory(String.t()) :: fact(:directory)
  def directory(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> {:present, :directory}
      {:ok, %File.Stat{}} -> {:error, :not_a_directory}
      {:error, :enoent} -> :absent
      {:error, reason} -> {:error, reason}
    end
  end

  @spec read(String.t()) :: fact(binary())
  def read(path) do
    case File.read(path) do
      {:ok, content} -> {:present, content}
      {:error, :enoent} -> :absent
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write_atomic(String.t(), iodata()) :: :ok | {:error, term()}
  def write_atomic(path, content) do
    temporary = path <> ".#{CanonicalUuid.generate()}.tmp"

    # The rename publishes one complete file and replaces an older derived copy atomically.
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, content, [:binary, :exclusive]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(temporary)
        error
    end
  end

  @spec remove_tree(String.t()) :: :ok | {:error, term()}
  def remove_tree(path) do
    case File.rm_rf(path) do
      {:ok, _paths} -> :ok
      {:error, reason, failed_path} -> {:error, {reason, failed_path}}
    end
  end

  @spec ensure_directories([String.t()]) :: :ok | {:error, term()}
  def ensure_directories(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.mkdir_p(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {reason, path}}}
      end
    end)
  end
end
