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

    caller =
      spawn(fn ->
        Command.run("setsid", capture_tools(), "sleep", ["99137"], timeout_ms: 20_000)
      end)

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
    task =
      Task.async(fn ->
        Command.run("setsid", capture_tools(), "sleep", ["99139"], timeout_ms: 20_000)
      end)

    process_ids = eventually_value(fn -> present_process_ids("sleep 99139") end)
    started = System.monotonic_time(:millisecond)

    assert :ok = Command.cancel(task.pid)
    assert Task.await(task, 5_000) == {:error, :cancelled}
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert eventually(fn -> ended?(process_ids) end)
  end

  test "stderr stays at capture bound plus one while the writer keeps running" do
    script =
      "i=0; while [ $i -lt 100 ]; do printf '0123456789abcdef' >&2; i=$((i + 1)); sleep 0.02; done"

    task =
      Task.async(fn ->
        Command.run("setsid", capture_tools(), "/bin/sh", ["-c", script],
          timeout_ms: 10_000,
          max_stderr_bytes: 127
        )
      end)

    {_group, stderr_path} = eventually_value(&running_command/0)
    assert eventually(fn -> file_size(stderr_path) == 128 end)
    assert Process.alive?(task.pid)
    Process.sleep(100)
    assert file_size(stderr_path) == 128

    assert {:ok, result} = Task.await(task, 10_000)
    assert byte_size(result.stderr) == 127
    assert result.stderr_truncated
    assert :sys.get_state(Command.Reaper) == %{}
    refute File.exists?(stderr_path)
    refute File.exists?(stderr_path <> ".pipe")
  end

  test "stderr truncation is false at the exact bound and true after overflow" do
    assert {:ok, exact} =
             Command.run("setsid", capture_tools(), "/bin/sh", ["-c", "printf 1234 >&2"],
               max_stderr_bytes: 4
             )

    assert exact.stderr == "1234"
    refute exact.stderr_truncated

    assert {:ok, overflow} =
             Command.run("setsid", capture_tools(), "/bin/sh", ["-c", "printf 12345 >&2"],
               max_stderr_bytes: 4
             )

    assert overflow.stderr == "1234"
    assert overflow.stderr_truncated
  end

  test "a grandchild holding stderr open leaves no capture reader" do
    started = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        Command.run(
          "setsid",
          capture_tools(),
          "/bin/sh",
          ["-c", "(/bin/sleep 3 >/dev/null) &"],
          timeout_ms: 10_000
        )
      end)

    {process_group, _stderr_path} = eventually_value(&running_command/0)
    assert {:ok, result} = Task.await(task, 2_000)
    assert System.monotonic_time(:millisecond) - started < 2_000
    assert result.stderr == ""
    refute result.stderr_truncated

    readers = process_group_commands(process_group) |> Enum.filter(&(&1 in ["head", "cat"]))
    assert readers == []
  end

  test "the stderr drain replaces its reader shell and is ended after the command" do
    script = "printf 12345 >&2; (/bin/sleep 3 >/dev/null) & /bin/sleep 1"

    task =
      Task.async(fn ->
        Command.run("setsid", capture_tools(), "/bin/sh", ["-c", script],
          timeout_ms: 10_000,
          max_stderr_bytes: 4
        )
      end)

    {process_group, _stderr_path} = eventually_value(&running_command/0)
    cat = eventually_value(fn -> direct_child(process_group, "cat") end)
    assert is_integer(cat)
    assert {:ok, result} = Task.await(task, 2_000)
    assert result.stderr == "1234"
    assert result.stderr_truncated
    assert eventually(fn -> process_ended?(Integer.to_string(cat)) end)

    readers = process_group_commands(process_group) |> Enum.filter(&(&1 in ["head", "cat"]))
    assert readers == []
  end

  test "a failed fifo setup returns its own error and leaves no reaper record" do
    before = MapSet.new(Path.wildcard(Path.join(System.tmp_dir!(), "biot-command-*")))
    tools = %{capture_tools() | mkfifo: "/bin/false"}

    assert Command.run("setsid", tools, "/bin/true", [], []) ==
             {:error, :stderr_capture_failed}

    assert :sys.get_state(Command.Reaper) == %{}
    after_files = MapSet.new(Path.wildcard(Path.join(System.tmp_dir!(), "biot-command-*")))
    assert MapSet.difference(after_files, before) == MapSet.new()
  end

  test "cancellation removes the fifo and stderr capture file" do
    task =
      Task.async(fn ->
        Command.run("setsid", capture_tools(), "sleep", ["99141"], timeout_ms: 20_000)
      end)

    {_group, stderr_path} = eventually_value(&running_command/0)
    assert :ok = Command.cancel(task.pid)
    assert Task.await(task, 5_000) == {:error, :cancelled}
    assert :sys.get_state(Command.Reaper) == %{}
    refute File.exists?(stderr_path)
    refute File.exists?(stderr_path <> ".pipe")
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

  defp ended?(process_ids), do: Enum.all?(process_ids, &process_ended?/1)

  defp process_ended?(process_id) do
    case File.read("/proc/#{process_id}/stat") do
      {:ok, stat} -> stat |> String.split() |> Enum.at(2) == "Z"
      {:error, :enoent} -> true
      {:error, _reason} -> false
    end
  end

  defp running_command do
    case :sys.get_state(Command.Reaper) |> Map.values() do
      [{process_group, stderr_path}] -> {process_group, stderr_path}
      _other -> nil
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      {:error, _reason} -> nil
    end
  end

  defp process_group_commands(process_group) do
    {output, _status} =
      System.cmd("ps", ["-o", "comm=", "-g", Integer.to_string(process_group)],
        stderr_to_stdout: true
      )

    String.split(output, "\n", trim: true) |> Enum.map(&Path.basename/1)
  end

  defp direct_child(process_group, command) do
    {output, _status} =
      System.cmd(
        "ps",
        ["-o", "pid=", "-o", "ppid=", "-o", "comm=", "-g", Integer.to_string(process_group)],
        stderr_to_stdout: true
      )

    Enum.find_value(
      String.split(output, "\n", trim: true),
      &direct_child_row(&1, process_group, command)
    )
  end

  defp direct_child_row(row, process_group, command) do
    case String.split(row) do
      [pid, parent, executable] ->
        if parent == Integer.to_string(process_group) and Path.basename(executable) == command,
          do: String.to_integer(pid)

      _fields ->
        nil
    end
  end

  defp capture_tools do
    %{mkfifo: "mkfifo", head: "head", cat: "cat", sleep: "sleep"}
  end

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
