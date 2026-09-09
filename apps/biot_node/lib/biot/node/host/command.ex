defmodule Biot.Node.Host.Command do
  @moduledoc """
  Runs one host command with a time limit and separate bounded output streams.

  Every command runs through `setsid`, so it owns an operating system process group that can be
  ended as a whole. That group does not die with the virtual machine, so every command is watched
  by `Biot.Node.Host.Command.Reaper`, which ends the group if the calling process dies. `cancel/1`
  is how a live caller ends the group early: killing the Erlang process that runs a command would
  leave `nix build` or `git clone` running.

  Invariant: no command runs before the reaper owns its group. A shell under `setsid` announces the
  group and waits for a go line over the port; this module gives the group to the reaper and only
  then sends that line. A caller that dies during the handshake closes the port, so the shell reads
  the end of its input and exits without running the command.
  """

  alias Biot.Node.Host.Command.Reaper
  alias Biot.Protocol.CanonicalUuid

  @cancel :biot_command_cancel

  # `read` returning end of input means the caller died before it owned the group, so the command
  # must not start. `exec` keeps the announced group id: the command replaces the shell.
  @script """
  printf '%s\\n' "$$"
  read go || exit 0
  exec "$@" 2>"$BIOT_COMMAND_STDERR"
  """

  defmodule Result do
    @moduledoc "The result of one completed host command."

    @enforce_keys [:status, :stdout, :stderr]
    defstruct [:status, :stdout, :stderr]

    @type t :: %__MODULE__{
            status: non_neg_integer(),
            stdout: binary(),
            stderr: binary()
          }
  end

  defmodule Running do
    @moduledoc false

    @enforce_keys [:port, :stderr_path, :ticket]
    defstruct [:port, :stderr_path, :ticket]

    @type t :: %__MODULE__{port: port(), stderr_path: Path.t(), ticket: reference()}
  end

  @type option ::
          {:cd, String.t()}
          | {:env, [{String.t(), String.t()}]}
          | {:timeout_ms, pos_integer()}
          | {:max_output_bytes, pos_integer()}

  @spec run(String.t(), String.t(), [String.t()], [option()]) ::
          {:ok, Result.t()}
          | {:error,
             :executable_not_found
             | :setsid_not_found
             | :timed_out
             | :cancelled
             | :start_failed
             | term()}
  def run(setsid_executable, executable, arguments, options \\ []) do
    with {:ok, path} <- executable_path(executable, :executable_not_found),
         {:ok, setsid_path} <- executable_path(setsid_executable, :setsid_not_found) do
      deadline = deadline(Keyword.get(options, :timeout_ms, 60_000))
      max_bytes = Keyword.get(options, :max_output_bytes, 256_000)

      with {:ok, running, stdout} <- start(setsid_path, path, arguments, options, deadline) do
        collect(running, deadline, max_bytes, append(<<>>, stdout, max_bytes))
      end
    end
  end

  @doc """
  Stops the command running in another process, along with its process group. The command returns
  `{:error, :cancelled}`; a process that is between two commands cancels the next one it starts.
  """
  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    send(pid, @cancel)
    :ok
  end

  @spec diagnostic(Result.t()) :: binary()
  def diagnostic(%Result{stderr: stderr, stdout: stdout}) do
    if stderr == "", do: stdout, else: stderr
  end

  defp executable_path(executable, missing) do
    case System.find_executable(executable) do
      nil -> {:error, missing}
      path -> {:ok, path}
    end
  end

  @spec start(Path.t(), Path.t(), [String.t()], [option()], integer()) ::
          {:ok, Running.t(), binary()} | {:error, :timed_out | :cancelled | :start_failed}
  defp start(setsid_path, path, arguments, options, deadline) do
    stderr_path = Path.join(System.tmp_dir!(), "biot-command-#{CanonicalUuid.generate()}")

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(setsid_path)},
        port_options(path, arguments, stderr_path, options)
      )

    with {:ok, process_group, stdout} <- handshake(port, <<>>, deadline) do
      ticket = Reaper.watch(process_group, stderr_path)
      go(port)
      {:ok, %Running{port: port, stderr_path: stderr_path, ticket: ticket}, stdout}
    end
  end

  defp port_options(path, arguments, stderr_path, options) do
    shell_arguments = ["--wait", "/bin/sh", "-c", @script, "biot-command", path | arguments]
    environment = [{"BIOT_COMMAND_STDERR", stderr_path} | Keyword.get(options, :env, [])]

    [:binary, :exit_status, :hide, args: Enum.map(shell_arguments, &String.to_charlist/1)]
    |> add_directory(Keyword.get(options, :cd))
    |> add_environment(environment)
  end

  # The first line of the port's output is the shell's process group. Everything after it is the
  # command's own output, because the command starts only after the go line.
  defp handshake(port, buffer, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      give_up(port, :timed_out)
    else
      receive do
        @cancel ->
          give_up(port, :cancelled)

        {^port, {:data, data}} ->
          first_line(port, buffer <> data, deadline)

        {^port, {:exit_status, _status}} ->
          give_up(port, :start_failed)
      after
        remaining -> give_up(port, :timed_out)
      end
    end
  end

  defp first_line(port, buffer, deadline) do
    case String.split(buffer, "\n", parts: 2) do
      [_unfinished_line] -> handshake(port, buffer, deadline)
      [line, stdout] -> announced_group(port, line, stdout)
    end
  end

  defp announced_group(port, line, stdout) do
    case Integer.parse(line) do
      {process_group, ""} when process_group > 0 -> {:ok, process_group, stdout}
      _unexpected -> give_up(port, :start_failed)
    end
  end

  # A shell that is gone already cannot run the command, and `collect/4` reports the exit status it
  # left behind.
  defp go(port) do
    if Port.info(port), do: Port.command(port, "go\n")
    :ok
  end

  defp give_up(port, reason) do
    close(port)
    {:error, reason}
  end

  defp collect(%Running{port: port} = running, deadline, max_bytes, stdout) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      abandon(running, :timed_out)
    else
      receive do
        @cancel ->
          abandon(running, :cancelled)

        {^port, {:data, data}} ->
          collect(running, deadline, max_bytes, append(stdout, data, max_bytes))

        {^port, {:exit_status, status}} ->
          finish(running, status, stdout, max_bytes)
      after
        remaining ->
          abandon(running, :timed_out)
      end
    end
  end

  defp abandon(%Running{} = running, reason) do
    :ok = Reaper.cancel(running.ticket)
    close(running.port)
    {:error, reason}
  end

  defp finish(%Running{} = running, status, stdout, max_bytes) do
    stderr = read_tail(running.stderr_path, max_bytes)
    :ok = Reaper.release(running.ticket)

    {:ok, %Result{status: status, stdout: stdout, stderr: stderr}}
  end

  defp read_tail(path, max_bytes) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          {:ok, size} = :file.position(file, :eof)
          bytes = min(size, max_bytes)
          {:ok, _position} = :file.position(file, size - bytes)
          IO.binread(file, bytes)
        after
          File.close(file)
        end

      {:error, :enoent} ->
        ""

      {:error, reason} ->
        "could not read command stderr: #{inspect(reason)}"
    end
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp append(output, data, max_bytes) do
    combined = output <> data

    if byte_size(combined) > max_bytes do
      start = byte_size(combined) - max_bytes
      binary_part(combined, start, max_bytes)
    else
      combined
    end
  end

  defp add_directory(options, nil), do: options
  defp add_directory(options, directory), do: [{:cd, String.to_charlist(directory)} | options]

  defp add_environment(options, environment) do
    encoded =
      Enum.map(environment, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    [{:env, encoded} | options]
  end
end
