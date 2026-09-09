defmodule Biot.Node.DataRootLock do
  @moduledoc """
  Holds the configured data root with the operating system's `flock(2)` lock.

  A long-lived `flock` port owns the open lock file and holds an exclusive, non-blocking advisory
  lock until this process stops. The node supervisor starts this process before the journal. A
  second node therefore gets `Biot.Node.DataRootLock.Error` before it can load or change resources.
  A PID file cannot give this guarantee because PID reuse and a crash can leave stale state.
  """

  use GenServer

  alias Biot.Node.Host.Paths

  defmodule Error do
    @moduledoc "A typed failure to take exclusive ownership of a data root."

    @enforce_keys [:path, :reason]
    defexception [:path, :reason]

    @type t :: %__MODULE__{path: String.t(), reason: :already_locked | :unavailable}

    @impl true
    def message(%__MODULE__{path: path, reason: :already_locked}) do
      "the node data root is already locked: #{path}"
    end

    def message(%__MODULE__{path: path, reason: :unavailable}) do
      "the node data root lock is unavailable: #{path}"
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl true
  def init(options) do
    root = Keyword.get(options, :data_root, Application.fetch_env!(:biot_node, :data_root))

    executable =
      Keyword.get(
        options,
        :executable,
        Application.get_env(:biot_node, :flock_executable, "flock")
      )

    lock_path = Paths.lock(root)

    with :ok <- File.mkdir_p(root),
         {:ok, executable_path} <- executable_path(executable),
         {:ok, port} <- open_lock(executable_path, lock_path),
         :ok <- await_lock(port, lock_path) do
      {:ok, %{port: port, path: lock_path}}
    else
      {:error, %Error{} = error} -> {:stop, error}
      {:error, _reason} -> {:stop, %Error{path: lock_path, reason: :unavailable}}
    end
  end

  @impl true
  def handle_info({_port, {:exit_status, _status}}, state) do
    {:stop, %Error{path: state.path, reason: :unavailable}, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp executable_path(executable) do
    case System.find_executable(executable) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  defp open_lock(executable, lock_path) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :hide,
          :stderr_to_stdout,
          {:line, 64},
          args:
            Enum.map(
              [
                "--exclusive",
                "--nonblock",
                lock_path,
                "/bin/sh",
                "-c",
                "printf 'locked\\n'; cat >/dev/null"
              ],
              &String.to_charlist/1
            )
        ]
      )

    {:ok, port}
  end

  defp await_lock(port, lock_path) do
    receive do
      {^port, {:data, {:eol, "locked"}}} -> :ok
      {^port, {:exit_status, 1}} -> {:error, %Error{path: lock_path, reason: :already_locked}}
      {^port, {:exit_status, _status}} -> {:error, %Error{path: lock_path, reason: :unavailable}}
    after
      5_000 ->
        Port.close(port)
        {:error, %Error{path: lock_path, reason: :unavailable}}
    end
  end
end
