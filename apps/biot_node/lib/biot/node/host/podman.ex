defmodule Biot.Node.Host.Podman do
  @moduledoc "Runs Podman commands and asks whether a named resource exists."

  alias Biot.Node.Allocation
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Host.Paths

  @type resource :: :container | :network

  @doc """
  Runs one Podman command. `timeout_ms` is an option because build work and inspection are not the
  same scale of wait.
  """
  @spec run(Config.t(), [String.t()], [Command.option()]) ::
          {:ok, Command.Result.t()} | {:error, :executable_not_found | :setsid_not_found | term()}
  def run(config, arguments, options \\ []) do
    Command.run(
      config.setsid_executable,
      Config.capture_tools(config),
      config.podman_executable,
      ["--module", Paths.podman_config(config) | arguments],
      Keyword.merge(
        [
          timeout_ms: config.command_timeout_ms,
          max_output_bytes: config.command_max_output_bytes,
          max_stderr_bytes: config.command_max_stderr_bytes
        ],
        options
      )
    )
  end

  @doc "Starts a Podman command the caller reads itself, such as the container event stream."
  @spec open(Config.t(), [String.t()]) ::
          {:ok, Command.Stream.t()} | {:error, :executable_not_found | :setsid_not_found | term()}
  def open(config, arguments) do
    Command.open(
      config.setsid_executable,
      Config.capture_tools(config),
      config.podman_executable,
      ["--module", Paths.podman_config(config) | arguments],
      timeout_ms: config.command_timeout_ms,
      max_stderr_bytes: config.command_max_stderr_bytes
    )
  end

  @doc "Starts a Podman command with both output streams sent to the caller."
  @spec open_combined(Config.t(), [String.t()]) ::
          {:ok, Command.Stream.t()} | {:error, :executable_not_found | :setsid_not_found | term()}
  def open_combined(config, arguments) do
    Command.open(
      config.setsid_executable,
      Config.capture_tools(config),
      "/bin/sh",
      [
        "-c",
        "exec \"$@\" 2>&1",
        "biot-podman",
        config.podman_executable,
        "--module",
        Paths.podman_config(config)
        | arguments
      ],
      timeout_ms: config.command_timeout_ms,
      max_stderr_bytes: config.command_max_stderr_bytes
    )
  end

  @doc """
  Gives a tree to one allocation's mapped user, which is what lets its containers write there.

  Paths already owned are left alone, so repeating this costs one stat per path.
  """
  @spec grant(Config.t(), Allocation.t(), [String.t()]) :: :ok | {:error, Outcome.t()}
  def grant(config, %Allocation{} = allocation, paths) do
    mapped_start = Allocation.subordinate_start(allocation, config.uid_range_base)

    case owned_by_all?(paths, mapped_start) do
      {:ok, true} -> :ok
      {:ok, false} -> chown(config, "#{mapped_start}:#{mapped_start}", paths)
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  @doc """
  Takes ownership of a tree a container wrote back to the node's own user.

  Everything under an allocation is owned by its mapped subordinate range while it is in use, so
  the node cannot remove it until this runs. `podman unshare` enters the same mapping Podman gives
  the containers, which is where those IDs are the node user's to change.

  Ownership alone is not enough: a Nix store directory is read only even to its owner, so the
  write permission has to come back with it or the tree still cannot be removed.
  """
  @spec reclaim(Config.t(), String.t()) :: :ok | {:error, Outcome.t()}
  def reclaim(config, path) do
    case FileSystem.directory(path) do
      :absent ->
        :ok

      {:present, :directory} ->
        reclaim_present(config, path)

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp reclaim_present(config, path) do
    with :ok <- chown(config, "0:0", [path]) do
      unshare(config, ["chmod", "-R", "u+w", path])
    end
  end

  @doc """
  Gives a tree to one allocation's mapped user while the node keeps read access through the group.

  A source credential is the one thing both have to read: the fetch worker runs as the allocation's
  user, and the node's own checkout clone runs as the node. Ownership alone cannot say that, so the
  group does, and the file's mode is what decides that the group may only read.

  Inside `podman unshare` the invoking user's UID and primary GID map to zero, so naming group zero
  here names the node's own primary group on the host without knowing what it is.
  """
  @spec share(Config.t(), Allocation.t(), [String.t()]) :: :ok | {:error, Outcome.t()}
  def share(config, %Allocation{} = allocation, paths) do
    mapped_start = Allocation.subordinate_start(allocation, config.uid_range_base)
    chown(config, "#{mapped_start}:0", paths)
  end

  defp chown(config, owner, paths), do: unshare(config, ["chown", "-R", owner | paths])

  defp unshare(config, arguments) do
    case run(config, ["unshare" | arguments]) do
      {:ok, %Command.Result{status: 0}} ->
        :ok

      {:ok, %Command.Result{} = result} ->
        {:error, Outcome.from_command(:host_unavailable, result)}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  # The node sees an allocation's files under its own subordinate IDs, and `podman unshare` is
  # where those IDs are the ones it can set.
  defp owned_by_all?(paths, owner) do
    Enum.reduce_while(paths, {:ok, true}, fn path, {:ok, true} ->
      case File.stat(path) do
        {:ok, %File.Stat{uid: ^owner, gid: ^owner}} -> {:cont, {:ok, true}}
        {:ok, %File.Stat{}} -> {:halt, {:ok, false}}
        {:error, reason} -> {:halt, {:error, {reason, path}}}
      end
    end)
  end

  @doc """
  Whether a named container or network exists. `podman <resource> exists` answers with its exit
  status alone: 0 is present, 1 is absent, and anything else is an error that is neither.
  """
  @spec exists(Config.t(), resource(), String.t()) ::
          :present | :absent | {:error, Command.Result.t() | term()}
  def exists(config, resource, name) do
    case run(config, [Atom.to_string(resource), "exists", name]) do
      {:ok, %Command.Result{status: 0}} -> :present
      {:ok, %Command.Result{status: 1}} -> :absent
      {:ok, %Command.Result{} = result} -> {:error, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
