defmodule Biot.Node.Backoff do
  @moduledoc """
  How long an automatic retry waits before the next attempt: the minimum delay doubled once per
  attempt already made, capped at the maximum. The first attempt waits the minimum.

  The delay is deterministic. One controller owns one biot, so there is no herd of retries to
  spread out, and a predictable delay is easier for an operator to reason about.
  """

  @spec delay(pos_integer(), pos_integer(), pos_integer()) :: pos_integer()
  def delay(attempt, minimum_ms, maximum_ms)
      when attempt >= 1 and minimum_ms > 0 and maximum_ms >= minimum_ms do
    min(minimum_ms * Integer.pow(2, attempt - 1), maximum_ms)
  end
end
