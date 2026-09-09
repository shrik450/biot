defmodule Biot.Server.Biots.Create do
  @moduledoc "The parsed inputs that create one biot."

  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.RepositorySource

  @enforce_keys [:name, :repository, :environment, :node_id]
  defstruct [:name, :repository, :environment, :node_id, initial_state: :running]

  @type t :: %__MODULE__{
          name: String.t(),
          repository: RepositorySource.t(),
          environment: EnvironmentSelection.t(),
          node_id: NodeId.t() | :default,
          initial_state: :running | :stopped
        }
end
