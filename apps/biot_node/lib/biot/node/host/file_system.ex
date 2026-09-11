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

  @doc """
  Publishes one file into a directory it shares with its own temporary name.

  The content is written under a temporary name in the same directory, `prepare` gives the file
  whatever permissions and ownership it needs, and the rename publishes it. A reader therefore sees
  the previous file or a complete one that is already handed over, and never one the node is still
  preparing. Staying in the same directory is what makes the rename atomic.

  The caller owns what the file contains, what `prepare` does to it, and what a failure means; this
  owns only the order those happen in.
  """
  @spec publish(String.t(), String.t(), iodata(), (String.t() -> :ok | {:error, term()})) ::
          :ok | {:error, term()}
  def publish(directory, name, content, prepare) when is_function(prepare, 1) do
    temporary = Path.join(directory, ".#{CanonicalUuid.generate()}.tmp")

    with :ok <- File.write(temporary, content, [:binary, :exclusive]),
         :ok <- prepare.(temporary),
         :ok <- File.rename(temporary, Path.join(directory, name)) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  @doc "Removes one file. A file that is already gone is the state the caller asked for."
  @spec unlink(String.t()) :: :ok | {:error, term()}
  def unlink(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
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
