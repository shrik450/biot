defmodule Biot.Protocol.Liveness do
  @moduledoc "Matches heartbeat responses without owning timers or sockets."

  @spec response_matches?(String.t() | nil, String.t()) :: boolean()
  def response_matches?(challenge, challenge) when is_binary(challenge), do: true
  def response_matches?(_expected, _received), do: false
end
