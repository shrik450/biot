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

  `run/5` waits for a command that ends. `open/5` hands a `Stream` to a caller that reads a command
  which does not, such as an event stream, and that caller ends its ownership with `close/1`. Both
  start the command the same way, so both leave the group with the reaper.
  """

  alias Biot.Node.Host.Command.Reaper
  alias Biot.Protocol.CanonicalUuid

  @cancel :biot_command_cancel
  @default_max_stderr_bytes 256_000
  @stderr_reader_grace_ms 100

  # The wrapper waits for the reaper's go line, then starts the reader first because a read-only
  # fifo open blocks until a writer arrives. The command runs while `head` saves the bound, then
  # `exec` makes the drain use the reader's own PID. A trapped signal interrupts `wait`, so the
  # guard can end a reader held by a grandchild; before `head` starts, TERM finds no child to
  # forward to. Ending the reader can lose buffered bytes, but a guard-ended reader reports
  # complete output. The wrapper then exits with the command's status, and only the reaper removes
  # the capture files.
  @script """
  printf '%s\\n' "$$"
  read go || exit 0
  stderr_pipe="$BIOT_COMMAND_STDERR.pipe"
  {
    exec 3<"$stderr_pipe"
    trap '
      kill "$reader_child" 2>/dev/null
      wait "$reader_child" 2>/dev/null
      exit 0
    ' TERM
    "$BIOT_COMMAND_HEAD" -c "$BIOT_COMMAND_STDERR_CAPTURE_BYTES" <&3 >"$BIOT_COMMAND_STDERR" &
    reader_child=$!
    wait "$reader_child"
    exec "$BIOT_COMMAND_CAT" <&3 >/dev/null
  } &
  stderr_reader=$!
  "$@" 2>"$stderr_pipe" &
  command=$!
  wait "$command"
  status=$?
  {
    "$BIOT_COMMAND_SLEEP" #{@stderr_reader_grace_ms / 1_000}
    kill "$stderr_reader" 2>/dev/null
  } &
  reader_guard=$!
  wait "$stderr_reader" 2>/dev/null
  kill "$reader_guard" 2>/dev/null
  wait "$reader_guard" 2>/dev/null
  exit "$status"
  """

  defmodule Result do
    @moduledoc "The result of one completed host command."

    @enforce_keys [:status, :stdout, :stderr, :stdout_truncated, :stderr_truncated]
    defstruct [:status, :stdout, :stderr, :stdout_truncated, :stderr_truncated]

    @type t :: %__MODULE__{
            status: non_neg_integer(),
            stdout: binary(),
            stderr: binary(),
            stdout_truncated: boolean(),
            stderr_truncated: boolean()
          }
  end

  defmodule Stream do
    @moduledoc """
    One running host command the caller owns: the port that carries its output and exit status, the
    file its stderr goes to, and the reaper ticket that holds its process group.

    The caller owns the command until it ends that ownership through `Biot.Node.Host.Command`.
    """

    @enforce_keys [:port, :stderr_path, :max_stderr_bytes, :ticket]
    defstruct [:port, :stderr_path, :max_stderr_bytes, :ticket]

    @type t :: %__MODULE__{
            port: port(),
            stderr_path: Path.t(),
            max_stderr_bytes: pos_integer(),
            ticket: reference()
          }
  end

  @type capture_tools :: %{
          mkfifo: Path.t(),
          head: Path.t(),
          cat: Path.t(),
          sleep: Path.t()
        }

  @type option ::
          {:cd, String.t()}
          | {:env, [{String.t(), String.t()}]}
          | {:timeout_ms, pos_integer()}
          | {:max_output_bytes, pos_integer()}
          | {:max_stderr_bytes, pos_integer()}

  @spec run(String.t(), capture_tools(), String.t(), [String.t()], [option()]) ::
          {:ok, Result.t()}
          | {:error,
             :executable_not_found
             | :setsid_not_found
             | :timed_out
             | :cancelled
             | :start_failed
             | :stderr_capture_failed
             | term()}
  def run(setsid_executable, capture_tools, executable, arguments, options) do
    max_bytes = Keyword.get(options, :max_output_bytes, 256_000)

    with {:ok, stream, stdout, deadline} <-
           launch(setsid_executable, capture_tools, executable, arguments, options) do
      {stdout, stdout_truncated} = append(<<>>, stdout, max_bytes)
      collect(stream, deadline, max_bytes, stdout, stdout_truncated)
    end
  end

  @doc """
  Starts a command whose output the caller reads itself, and gives the caller the command.

  The caller receives `{stream.port, {:data, data}}` for output and
  `{stream.port, {:exit_status, status}}` when the command ends. The reaper ends the command's
  group when the caller dies, so a command that never ends on its own still belongs to one live
  process. A caller that stays alive across commands calls `close/1` for each one that ends.
  """
  @spec open(String.t(), capture_tools(), String.t(), [String.t()], [option()]) ::
          {:ok, Stream.t()}
          | {:error,
             :executable_not_found
             | :setsid_not_found
             | :timed_out
             | :cancelled
             | :start_failed
             | :stderr_capture_failed}
  def open(setsid_executable, capture_tools, executable, arguments, options) do
    with {:ok, stream, _stdout, _deadline} <-
           launch(setsid_executable, capture_tools, executable, arguments, options) do
      {:ok, stream}
    end
  end

  @doc """
  Ends the caller's ownership of a command that has stopped: the reaper forgets its process group
  and removes its stderr file. A caller that outlives its commands would otherwise grow one reaper
  record and one file per command.
  """
  @spec close(Stream.t()) :: :ok
  def close(%Stream{} = stream), do: Reaper.release(stream.ticket)

  @doc """
  Stops the command running in another process, along with its process group. The command returns
  `{:error, :cancelled}`; a process that is between two commands cancels the next one it starts.
  """
  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    send(pid, @cancel)
    :ok
  end

  # The command starts only after the go line, so nothing has written output yet and the handshake
  # leftover is empty. `run/5` still folds it in, because the port protocol allows it.
  defp launch(setsid_executable, capture_tools, executable, arguments, options) do
    with {:ok, path} <- executable_path(executable, :executable_not_found),
         {:ok, setsid_path} <- executable_path(setsid_executable, :setsid_not_found) do
      deadline = deadline(Keyword.get(options, :timeout_ms, 60_000))

      with {:ok, stream, stdout} <-
             start(setsid_path, path, arguments, options, capture_tools, deadline) do
        {:ok, stream, stdout, deadline}
      end
    end
  end

  defp executable_path(executable, missing) do
    case System.find_executable(executable) do
      nil -> {:error, missing}
      path -> {:ok, path}
    end
  end

  @spec start(
          Path.t(),
          Path.t(),
          [String.t()],
          [option()],
          capture_tools(),
          integer()
        ) ::
          {:ok, Stream.t(), binary()}
          | {:error, :timed_out | :cancelled | :start_failed | :stderr_capture_failed}
  defp start(setsid_path, path, arguments, options, capture_tools, deadline) do
    stderr_path = Path.join(System.tmp_dir!(), "biot-command-#{CanonicalUuid.generate()}")

    with :ok <- create_stderr_pipe(capture_tools.mkfifo, stderr_path) do
      start_port(
        setsid_path,
        path,
        arguments,
        options,
        capture_tools,
        stderr_path,
        deadline
      )
    end
  end

  @spec start_port(
          Path.t(),
          Path.t(),
          [String.t()],
          [option()],
          capture_tools(),
          Path.t(),
          integer()
        ) ::
          {:ok, Stream.t(), binary()}
          | {:error, :timed_out | :cancelled | :start_failed}
  defp start_port(
         setsid_path,
         path,
         arguments,
         options,
         tools,
         stderr_path,
         deadline
       ) do
    max_stderr_bytes = Keyword.get(options, :max_stderr_bytes, @default_max_stderr_bytes)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(setsid_path)},
        port_options(path, arguments, stderr_path, options, tools, max_stderr_bytes)
      )

    case handshake(port, <<>>, deadline) do
      {:ok, process_group, stdout} ->
        ticket = Reaper.watch(process_group, stderr_path)
        go(port)

        stream = %Stream{
          port: port,
          stderr_path: stderr_path,
          max_stderr_bytes: max_stderr_bytes,
          ticket: ticket
        }

        {:ok, stream, stdout}

      {:error, _reason} = error ->
        File.rm(stderr_path <> ".pipe")
        error
    end
  end

  defp create_stderr_pipe(mkfifo, stderr_path) do
    case System.cmd(mkfifo, [stderr_path <> ".pipe"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :stderr_capture_failed}
    end
  end

  @spec port_options(
          Path.t(),
          [String.t()],
          Path.t(),
          [option()],
          capture_tools(),
          pos_integer()
        ) :: [term()]
  defp port_options(path, arguments, stderr_path, options, tools, max_stderr_bytes) do
    shell_arguments = ["--wait", "/bin/sh", "-c", @script, "biot-command", path | arguments]

    environment =
      Keyword.get(options, :env, []) ++
        [
          {"BIOT_COMMAND_STDERR", stderr_path},
          # The extra byte records overflow in the capture itself without exposing it in Result.
          {"BIOT_COMMAND_STDERR_CAPTURE_BYTES", Integer.to_string(max_stderr_bytes + 1)},
          {"BIOT_COMMAND_HEAD", tools.head},
          {"BIOT_COMMAND_CAT", tools.cat},
          {"BIOT_COMMAND_SLEEP", tools.sleep}
        ]

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

  # A shell that is gone already cannot run the command, and `collect/5` reports the exit status it
  # left behind.
  defp go(port) do
    if Port.info(port), do: Port.command(port, "go\n")
    :ok
  end

  defp give_up(port, reason) do
    close_port(port)
    {:error, reason}
  end

  defp collect(
         %Stream{port: port} = stream,
         deadline,
         max_bytes,
         stdout,
         stdout_truncated
       ) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      abandon(stream, :timed_out)
    else
      receive do
        @cancel ->
          abandon(stream, :cancelled)

        {^port, {:data, data}} ->
          {stdout, truncated} = append(stdout, data, max_bytes)
          collect(stream, deadline, max_bytes, stdout, stdout_truncated or truncated)

        {^port, {:exit_status, status}} ->
          finish(stream, status, stdout, stdout_truncated)
      after
        remaining ->
          abandon(stream, :timed_out)
      end
    end
  end

  defp abandon(%Stream{} = stream, reason) do
    :ok = Reaper.cancel(stream.ticket)
    close_port(stream.port)
    {:error, reason}
  end

  # The stderr file is read before ownership ends, because ending it removes the file.
  defp finish(%Stream{} = stream, status, stdout, stdout_truncated) do
    {stderr, stderr_truncated} = read_stderr(stream.stderr_path, stream.max_stderr_bytes)
    :ok = close(stream)

    {:ok,
     %Result{
       status: status,
       stdout: stdout,
       stderr: stderr,
       stdout_truncated: stdout_truncated,
       stderr_truncated: stderr_truncated
     }}
  end

  defp read_stderr(path, max_bytes) do
    case File.read(path) do
      {:ok, content} ->
        if byte_size(content) > max_bytes do
          {binary_part(content, 0, max_bytes), true}
        else
          {content, false}
        end

      {:error, :enoent} ->
        {"", false}

      {:error, reason} ->
        {"could not read command stderr: #{inspect(reason)}", false}
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp append(output, data, max_bytes) do
    combined = output <> data

    if byte_size(combined) > max_bytes do
      start = byte_size(combined) - max_bytes
      {binary_part(combined, start, max_bytes), true}
    else
      {combined, false}
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
