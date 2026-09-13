defmodule Biot.Protocol.StreamFailure do
  @moduledoc """
  The closed set of reasons a node refuses or ends one stream.

  `stale_access` covers both an obsolete and a future revision: the server must reread policy before
  it retries with any revision other than the one it already applied. `too_many_streams` is the
  node's own bound, and it never says which bound was reached.
  """

  @reasons ~w(unknown_biot stale_access agent_unreachable port_not_listening too_many_streams)a

  @type t ::
          :unknown_biot
          | :stale_access
          | :agent_unreachable
          | :port_not_listening
          | :too_many_streams

  @spec reasons() :: [t()]
  def reasons, do: @reasons

  @spec to_string(t()) :: String.t()
  def to_string(reason) when reason in @reasons, do: Atom.to_string(reason)

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) when is_binary(value) do
    case Enum.find(@reasons, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_format}
      reason -> {:ok, reason}
    end
  end

  def parse(_value), do: {:error, :invalid_format}
end
