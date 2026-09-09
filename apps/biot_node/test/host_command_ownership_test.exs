defmodule Biot.Node.Host.CommandOwnershipTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Biot.Node.Host.Command

  @moduletag :linux
  @moduletag timeout: 30_000

  test "a caller killed between the group announcement and go leaves no process" do
    reaper = Process.whereis(Command.Reaper)
    :sys.suspend(reaper)
    on_exit(fn -> safe_resume(reaper) end)

    caller = spawn(fn -> Command.run("setsid", "sleep", ["99137"], timeout_ms: 20_000) end)

    assert {:watch, ^caller, process_group, stderr_path} =
             eventually_value(fn -> queued_watch(reaper, caller) end)

    assert command_line(process_group) == "/bin/sh -c"

    Process.exit(caller, :kill)
    :sys.resume(reaper)

    assert eventually(fn -> not Process.alive?(caller) end)
    assert eventually(fn -> not File.exists?("/proc/#{process_group}") end)
    assert process_ids("sleep 99137") == []
    refute File.exists?(stderr_path)
  end

  test "cancellation returns promptly and removes the whole process group" do
    task = Task.async(fn -> Command.run("setsid", "sleep", ["99139"], timeout_ms: 20_000) end)
    process_ids = eventually_value(fn -> present_process_ids("sleep 99139") end)
    started = System.monotonic_time(:millisecond)

    assert :ok = Command.cancel(task.pid)
    assert Task.await(task, 5_000) == {:error, :cancelled}
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert eventually(fn -> gone?(process_ids) end)
  end

  defp queued_watch(reaper, caller) do
    {:messages, messages} = Process.info(reaper, :messages)

    Enum.find_value(messages, fn
      {:"$gen_call", _from, {:watch, ^caller, process_group, stderr_path}} ->
        {:watch, caller, process_group, stderr_path}

      _message ->
        nil
    end)
  end

  defp command_line(process_group) do
    case File.read("/proc/#{process_group}/cmdline") do
      {:ok, content} ->
        content |> String.split(<<0>>, trim: true) |> Enum.take(2) |> Enum.join(" ")

      {:error, _reason} ->
        nil
    end
  end

  defp present_process_ids(pattern) do
    case process_ids(pattern) do
      [] -> nil
      ids -> ids
    end
  end

  defp process_ids(pattern) do
    {output, _status} = System.cmd("pgrep", ["-f", pattern], stderr_to_stdout: true)
    String.split(output, "\n", trim: true)
  end

  defp gone?(process_ids), do: Enum.all?(process_ids, &(not File.exists?("/proc/#{&1}")))

  defp eventually(function, attempts \\ 200)
  defp eventually(_function, 0), do: false

  defp eventually(function, attempts) do
    if function.() do
      true
    else
      receive do
      after
        20 -> eventually(function, attempts - 1)
      end
    end
  end

  defp eventually_value(function, attempts \\ 200)
  defp eventually_value(_function, 0), do: nil

  defp eventually_value(function, attempts) do
    case function.() do
      nil ->
        receive do
        after
          20 -> eventually_value(function, attempts - 1)
        end

      value ->
        value
    end
  end

  defp safe_resume(pid) do
    :sys.resume(pid)
  catch
    :exit, _reason -> :ok
  end
end
