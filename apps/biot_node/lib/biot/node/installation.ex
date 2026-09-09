defmodule Biot.Node.Installation do
  @moduledoc """
  The node's record of which prepared artifact one biot's allocation currently runs. It is the
  handoff between the allocation and the replaceable environment, and a container may use only the
  artifact this record names.
  """

  alias Biot.Node.ArtifactId
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentId

  @enforce_keys [:biot_id, :environment_id, :artifact_id]
  defstruct [:biot_id, :environment_id, :artifact_id]

  @type t :: %__MODULE__{
          biot_id: BiotId.t(),
          environment_id: EnvironmentId.t(),
          artifact_id: ArtifactId.t()
        }
end
