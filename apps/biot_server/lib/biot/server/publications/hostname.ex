defmodule Biot.Server.Publications.Hostname do
  @moduledoc "Allocates random publication hostnames."

  alias Biot.Protocol.Hostname

  @spec allocate() :: Hostname.t()
  def allocate do
    label = :crypto.strong_rand_bytes(16) |> Base.encode32(case: :lower, padding: false)
    {:ok, hostname} = Hostname.parse(label)
    hostname
  end
end
