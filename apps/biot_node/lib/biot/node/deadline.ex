defmodule Biot.Node.Deadline do
  @moduledoc "A monotonic deadline for the node's bounded reads."

  @spec from_timeout(pos_integer()) :: integer()
  def from_timeout(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  @spec remaining(integer()) :: pos_integer() | :timeout
  def remaining(deadline) do
    left = deadline - System.monotonic_time(:millisecond)
    if left <= 0, do: :timeout, else: left
  end
end
