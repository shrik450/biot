defmodule Biot.Server.PreviewHandoff.Finished do
  @moduledoc "A consumed handoff: the clear preview token and where to redirect."

  alias Biot.Protocol.SameOriginPath

  @enforce_keys [:token, :return_path]
  defstruct [:token, :return_path]

  @type t :: %__MODULE__{token: String.t(), return_path: SameOriginPath.t()}
end
