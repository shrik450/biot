defmodule BiotTest.Temp do
  @moduledoc """
  Names a scratch path that no other run of the suite can collide with.

  `System.unique_integer/1` is unique inside one VM only. Every run starts the counter over, so a
  directory an aborted run left behind has the name the next run would pick, and the next run reads
  it as its own; that is how seven browser tests were once reported invalid instead of failing.
  The timestamp and the pid keep runs apart, and the unique integer keeps two calls inside one run
  apart, because two calls can land in the same microsecond.

  The three parts are written in base 36 to keep the name short, and short is a requirement rather
  than a nicety: a node's agent socket lives under this directory, and the whole Unix socket path
  must stay under 108 bytes including its terminating NUL. A character spent here is one the
  socket cannot use.

  The name is not under `Biot` because a test that aliases the Biot schema — the schema really is
  called `Biot` — resolves any `Biot.Something` reference through that alias.
  """

  @spec directory(String.t()) :: String.t()
  def directory(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{suffix()}")
  end

  defp suffix do
    Enum.map_join(
      [System.system_time(:microsecond), pid(), System.unique_integer([:positive])],
      "-",
      &Integer.to_string(&1, 36)
    )
  end

  defp pid, do: System.pid() |> String.to_integer()
end
