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

  @doc """
  The physical path `path` names, with every symlink in it followed.

  A relative symlink means different things to the kernel and to `File.cp_r/3`: the kernel resolves
  it against the directory that physically holds it, while `File.cp_r/3` resolves it lexically
  against the path it was reached by. A directory reached through another symlink therefore copies
  its inner links from the wrong base. Resolving once here means every later call sees the physical
  directory and the two agree. `path` is absolute; only the final physical path is normalized,
  because normalizing the input first would collapse a `..` that the kernel resolves physically.
  """
  @spec real_path(String.t()) :: String.t()
  def real_path(path), do: path |> resolve(0) |> Path.expand()

  # Each component is checked in turn, so the link is whichever component is one rather than a guess
  # about the shape of the path. `physical` holds only components already followed; the kernel's own
  # limit is 40 links, so a longer chain is left for the caller's operation to fail on.
  defp resolve(path, depth) when depth >= 40, do: path

  defp resolve(path, depth) do
    ["/" | components] = Path.split(path)
    follow("/", components, depth)
  end

  defp follow(physical, [], _depth), do: physical

  defp follow(physical, [component | rest], depth) do
    candidate = Path.join(physical, component)

    case :file.read_link(candidate) do
      {:ok, target} ->
        target = if Path.type(target) == :absolute, do: target, else: Path.join(physical, target)
        resolve(Path.join([target | rest]), depth + 1)

      _not_a_link ->
        follow(candidate, rest, depth)
    end
  end
end
