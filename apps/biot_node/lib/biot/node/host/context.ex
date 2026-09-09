defmodule Biot.Node.Host.Context do
  @moduledoc "The host configuration and Biot ownership boundary for one controller."

  alias Biot.Node.Host.Config
  alias Biot.Protocol.BiotId

  @enforce_keys [:biot_id, :config]
  defstruct [:biot_id, :config]

  @type t :: %__MODULE__{biot_id: BiotId.t(), config: Config.t()}

  @spec from_application(BiotId.t()) :: {:ok, t()} | {:error, term()}
  def from_application(%BiotId{} = biot_id) do
    with {:ok, config} <- Config.from_application() do
      {:ok, %__MODULE__{biot_id: biot_id, config: config}}
    end
  end
end
