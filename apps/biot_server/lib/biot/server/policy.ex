defmodule Biot.Server.Policy do
  @moduledoc "Defines the shared result contract for policy commands."

  alias Biot.Protocol.NodeId
  alias Biot.Server.CommandError
  alias Biot.Server.Policy.{Applied, Unchanged}

  @type enforcement :: :applied | {:pending, NodeId.t()}
  @type result :: {:ok, Applied.t() | Unchanged.t()} | {:error, CommandError.t()}
end
