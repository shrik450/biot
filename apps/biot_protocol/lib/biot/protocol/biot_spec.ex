defmodule Biot.Protocol.BiotSpec do
  @moduledoc "The execution and access intent sent to an assigned node."

  alias Biot.Protocol.ExecutionSpec
  alias Biot.Protocol.StrictMap

  @fields ["execution", "access_revision"]

  @enforce_keys [:execution, :access_revision]
  defstruct [:execution, :access_revision]

  @type t :: %__MODULE__{execution: ExecutionSpec.t(), access_revision: pos_integer()}

  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = spec) do
    %{
      "execution" => ExecutionSpec.encode(spec.execution),
      "access_revision" => spec.access_revision
    }
  end

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) do
    with {:ok, %{"execution" => execution, "access_revision" => access_revision}} <-
           StrictMap.fetch_exact(value, @fields),
         true <- is_integer(access_revision) and access_revision > 0,
         {:ok, execution} <- ExecutionSpec.parse(execution) do
      {:ok, %__MODULE__{execution: execution, access_revision: access_revision}}
    else
      _error -> {:error, :invalid_format}
    end
  end
end
