defmodule Biot.Node.Resolution do
  @moduledoc """
  The node's record of one environment's frozen inputs. The node owns the resolution bytes and
  reports the manifest to the server, which never sends it back.
  """

  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.Manifest

  @enforce_keys [:environment_id, :manifest]
  defstruct [:environment_id, :manifest]

  @type t :: %__MODULE__{
          environment_id: EnvironmentId.t(),
          manifest: Manifest.t()
        }
end
