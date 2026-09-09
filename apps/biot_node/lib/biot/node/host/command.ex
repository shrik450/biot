defmodule Biot.Node.Host.Command do
  @moduledoc "Runs one host command with a time limit and separate bounded output streams."

  alias Biot.Protocol.CanonicalUuid

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

  @type option ::
          {:cd, String.t()}
          | {:env, [{String.t(), String.t()}]}
          | {:timeout_ms, pos_integer()}
          | {:max_output_bytes, pos_integer()}

  @spec run(String.t(), String.t(), [String.t()], [option()]) ::
          {:ok, Result.t()}
          | {:error, :executable_not_found | :setsid_not_found | :timed_out | term()}
  def run(setsid_executable, executable, arguments, options \\ []) do
    with {:ok, path} <- executable_path(executable, :executable_not_found),
         {:ok, setsid_path} <- executable_path(setsid_executable, :setsid_not_found),
         {:ok, port, stderr_path, process_group_path} <-
           open(setsid_path, path, arguments, options) do
      collect(
        port,
        stderr_path,
        process_group_path,
        deadline(Keyword.get(options, :timeout_ms, 60_000)),
        Keyword.get(options, :max_output_bytes, 256_000),
        <<>>
      )
    end
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

  defp open(setsid_path, path, arguments, options) do
    token = CanonicalUuid.generate()
    stderr_path = Path.join(System.tmp_dir!(), "biot-command-#{token}.stderr")
    process_group_path = Path.join(System.tmp_dir!(), "biot-command-#{token}.pid")
    shell = "/bin/sh"

    shell_arguments = [
      "--wait",
      shell,
      "-c",
      "printf '%s\\n' \"$$\" >\"$BIOT_COMMAND_PROCESS_GROUP\"; \"$@\" 2>\"$BIOT_COMMAND_STDERR\"",
      "biot-command",
      path | arguments
    ]

    port_options = [
      :binary,
      :exit_status,
      :hide,
      args: Enum.map(shell_arguments, &String.to_charlist/1)
    ]

    port_options = add_directory(port_options, Keyword.get(options, :cd))

    environment =
      [
        {"BIOT_COMMAND_STDERR", stderr_path},
        {"BIOT_COMMAND_PROCESS_GROUP", process_group_path}
        | Keyword.get(options, :env, [])
      ]

    port_options = add_environment(port_options, environment)

    port = Port.open({:spawn_executable, String.to_charlist(setsid_path)}, port_options)
    {:ok, port, stderr_path, process_group_path}
  end

  defp collect(
         port,
         stderr_path,
         process_group_path,
         deadline,
         max_bytes,
         stdout
       ) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      stop_process_group(port, process_group_path)
      File.rm(stderr_path)
      File.rm(process_group_path)
      {:error, :timed_out}
    else
      receive do
        {^port, {:data, data}} ->
          stdout = append(stdout, data, max_bytes)

          collect(
            port,
            stderr_path,
            process_group_path,
            deadline,
            max_bytes,
            stdout
          )

        {^port, {:exit_status, status}} ->
          finish(status, stdout, stderr_path, process_group_path, max_bytes)
      after
        remaining ->
          stop_process_group(port, process_group_path)
          File.rm(stderr_path)
          File.rm(process_group_path)
          {:error, :timed_out}
      end
    end
  end

  defp finish(status, stdout, stderr_path, process_group_path, max_bytes) do
    stderr = read_tail(stderr_path, max_bytes)
    File.rm(stderr_path)
    File.rm(process_group_path)

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

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp stop_process_group(port, process_group_path) do
    case process_group_id(port, process_group_path) do
      {:ok, pid} -> System.cmd("kill", ["-TERM", "--", "-#{pid}"])
      :error -> {"", 0}
    end

    if Port.info(port), do: Port.close(port)
  end

  defp process_group_id(port, path) do
    with {:ok, content} <- File.read(path),
         {pid, ""} when pid > 0 <- Integer.parse(String.trim(content)) do
      {:ok, pid}
    else
      _error ->
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> {:ok, pid}
          nil -> :error
        end
    end
  end

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
