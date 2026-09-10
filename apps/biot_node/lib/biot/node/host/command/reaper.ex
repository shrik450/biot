defmodule Biot.Node.Host.Command.Reaper do
  @moduledoc """
  Owns the operating system process group and the stderr file of every running host command.

  Invariant: a running command's group belongs to the process that started it. `setsid` puts the
  command in its own group so that one command's children can be ended together, which also means
  the virtual machine no longer ends them: a controller that crashes during a `nix build` would
  leave the build client behind. The reaper monitors the caller while the command runs and ends the
  group when the caller dies.

  `Biot.Node.Host.Command` hands over a group before the command in it can run, so no command ever
  runs unowned. The reaper ends a group before it forgets it, so ownership also outlasts the group.

  The caller ends its own command through `release/1` or `cancel/1`, so a command that finishes
  normally never reaches the monitor.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Watches the calling process until it releases or cancels this command. `process_group` is the
  group the command announced, and `stderr_path` is the file to remove when the command ends.
  """
  @spec watch(pos_integer(), Path.t()) :: reference()
  def watch(process_group, stderr_path) when is_integer(process_group) and process_group > 0 do
    GenServer.call(__MODULE__, {:watch, self(), process_group, stderr_path})
  end

  @doc "Forgets a command that ended on its own, and removes its stderr file."
  @spec release(reference()) :: :ok
  def release(ticket) when is_reference(ticket) do
    GenServer.call(__MODULE__, {:release, ticket})
  end

  @doc "Ends a running command's process group now, and removes its stderr file."
  @spec cancel(reference()) :: :ok
  def cancel(ticket) when is_reference(ticket) do
    GenServer.call(__MODULE__, {:cancel, ticket})
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:watch, caller, process_group, stderr_path}, _from, commands) do
    ticket = Process.monitor(caller)
    {:reply, ticket, Map.put(commands, ticket, {process_group, stderr_path})}
  end

  def handle_call({:release, ticket}, _from, commands) do
    {command, commands} = forget(ticket, commands)
    remove(command)
    {:reply, :ok, commands}
  end

  def handle_call({:cancel, ticket}, _from, commands) do
    {command, commands} = forget(ticket, commands)
    stop_group(command)
    remove(command)
    {:reply, :ok, commands}
  end

  @impl true
  def handle_info({:DOWN, ticket, :process, _pid, _reason}, commands) do
    {command, commands} = Map.pop(commands, ticket)
    stop_group(command)
    remove(command)
    {:noreply, commands}
  end

  defp forget(ticket, commands) do
    Process.demonitor(ticket, [:flush])
    Map.pop(commands, ticket)
  end

  defp stop_group(nil), do: :ok

  # A group that has already ended is normal on the cancel path, and what `kill` says about it is
  # not part of the node's output.
  defp stop_group({process_group, _stderr_path}) do
    System.cmd("kill", ["-TERM", "--", "-#{process_group}"], stderr_to_stdout: true)
    :ok
  end

  defp remove(nil), do: :ok

  defp remove({_process_group, stderr_path}) do
    Enum.each([stderr_path, stderr_path <> ".pipe"], &File.rm/1)

    :ok
  end
end
