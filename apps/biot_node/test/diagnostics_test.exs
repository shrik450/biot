defmodule Biot.Node.DiagnosticsTest do
  use ExUnit.Case, async: false

  alias Biot.Node.Diagnostics
  alias Biot.Protocol.PrivateDiagnosticId

  test "fetch honors the request limit and reports either source of truncation" do
    first = id(1)
    second = id(2)

    restart_diagnostics(max_entries: 2, max_entry_bytes: 6)
    assert :ok = Diagnostics.put(first, "123456789")
    assert Diagnostics.fetch(first, 10) == {:ok, {"123456", true}}

    assert :ok = Diagnostics.put(second, "abcdef")
    assert Diagnostics.fetch(second, 3) == {:ok, {"abc", true}}
    assert Diagnostics.fetch(id(99), 3) == :not_found
  end

  test "the bounded store evicts the oldest entry and refreshing an id keeps it" do
    first = id(3)
    second = id(4)
    third = id(5)

    restart_diagnostics(max_entries: 2)
    assert :ok = Diagnostics.put(first, "first")
    assert :ok = Diagnostics.put(second, "second")
    assert :ok = Diagnostics.put(first, "updated")
    assert :ok = Diagnostics.put(third, "third")

    assert Diagnostics.fetch(first, 20) == {:ok, {"updated", false}}
    assert Diagnostics.fetch(second, 20) == :not_found
    assert Diagnostics.fetch(third, 20) == {:ok, {"third", false}}
  end

  defp restart_diagnostics(options) do
    supervisor = Process.whereis(Biot.Node.Supervisor)
    :ok = Supervisor.terminate_child(supervisor, Diagnostics)
    :ok = Supervisor.delete_child(supervisor, Diagnostics)
    {:ok, _pid} = Supervisor.start_child(supervisor, {Diagnostics, options})

    on_exit(fn ->
      :ok = Supervisor.terminate_child(supervisor, Diagnostics)
      :ok = Supervisor.delete_child(supervisor, Diagnostics)
      {:ok, _pid} = Supervisor.start_child(supervisor, Diagnostics)
    end)
  end

  defp id(number) do
    value =
      "00000000-0000-4000-8000-" <>
        (number |> Integer.to_string() |> String.pad_leading(12, "0"))

    {:ok, diagnostic_id} = PrivateDiagnosticId.parse(value)
    diagnostic_id
  end
end
