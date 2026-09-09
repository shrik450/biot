defmodule Biot.Protocol.EnvironmentSelection do
  @moduledoc "The source selection used to define an environment."

  alias Biot.Protocol.RelativeDirectory
  alias Biot.Protocol.SourceSelector

  @enforce_keys [:base_nixpkgs, :layers, :project_context]
  defstruct [:base_nixpkgs, :layers, :project_context]

  @type t :: %__MODULE__{
          base_nixpkgs: SourceSelector.t(),
          layers: [SourceSelector.t()],
          project_context: RelativeDirectory.t() | nil
        }
end
