defmodule BiotTest.Temp do
  @moduledoc """
  Names scratch paths that no other run of the suite can collide with.

  `System.unique_integer/1` is unique inside one VM only. Every run starts the counter over, so a
  directory an aborted run left behind has the name the next run would pick, and the next run reads
  it as its own; that is how seven browser tests were once reported invalid instead of failing.
  The timestamp and the pid keep runs apart, and the unique integer keeps two calls inside one run
  apart, because two calls can land in the same microsecond.

  The name is not under `Biot` because a test that aliases the Biot schema — the schema really is
  called `Biot` — resolves any `Biot.Something` reference through that alias.
  """

  @doc "A scratch directory for a test's own files. Its depth does not matter."
  @spec directory(String.t()) :: String.t()
  def directory(prefix) do
    Path.join(System.tmp_dir!(), name(prefix))
  end

  @doc """
  A scratch directory a node may hand to its containers, where `directory/1` will not do.

  Use it for anything the node bind-mounts or roots itself in: either of its two roots, and any
  file it mounts into a worker. `System.tmp_dir!/0` is wrong for those, because it is whatever
  `TMPDIR` says and `nix develop` sets that to a per-shell directory that fails them twice over:

    * It is mode 0700, so a container's mapped user cannot traverse into it and every bind mount
      below it is denied with `crun: openat /proc/self/cwd: Permission denied`.
    * It is long, and a node's agent socket sits below its runtime root, where Linux caps a Unix
      socket path at 108 bytes including its terminating NUL.

  `/tmp` answers both: it is world-traversable and it is four bytes. Keep the prefix short when
  the result is a runtime root, because that is the one with bytes to spend.
  """
  @spec node_root(String.t()) :: String.t()
  def node_root(prefix) do
    Path.join("/tmp", name(prefix))
  end

  defp name(prefix), do: "#{prefix}-#{suffix()}"

  defp suffix do
    Enum.map_join(
      [System.system_time(:microsecond), pid(), System.unique_integer([:positive])],
      "-",
      &Integer.to_string(&1, 36)
    )
  end

  defp pid, do: System.pid() |> String.to_integer()
end
