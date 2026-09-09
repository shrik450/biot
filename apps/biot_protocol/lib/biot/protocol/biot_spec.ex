defmodule Biot.Protocol.BiotSpec do
  @moduledoc "The execution and access intent sent to an assigned node."

  alias Biot.Protocol.ExecutionSpec

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
  def parse(%{"execution" => execution, "access_revision" => access_revision})
      when is_integer(access_revision) and access_revision > 0 do
    case ExecutionSpec.parse(execution) do
      {:ok, execution} ->
        {:ok, %__MODULE__{execution: execution, access_revision: access_revision}}

      {:error, _reason} ->
        {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}
end
