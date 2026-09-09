defmodule Biot.Protocol.ExecutionSpec do
  @moduledoc "The complete server-owned execution intent sent to an assigned node."

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.RepositorySource

  @enforce_keys [:biot_id, :repository, :desired, :environment]
  defstruct [:biot_id, :repository, :desired, :environment]

  @type environment :: %{id: EnvironmentId.t(), selection: EnvironmentSelection.t()}
  @type t :: %__MODULE__{
          biot_id: BiotId.t(),
          repository: RepositorySource.t(),
          desired: Desired.t(),
          environment: environment()
        }

  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = spec) do
    %{
      "biot_id" => BiotId.to_string(spec.biot_id),
      "repository" => RepositorySource.to_string(spec.repository),
      "desired" => Desired.encode(spec.desired),
      "environment" => %{
        "id" => EnvironmentId.to_string(spec.environment.id),
        "selection" => EnvironmentSelection.encode(spec.environment.selection)
      }
    }
  end

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(%{
        "biot_id" => biot_id,
        "repository" => repository,
        "desired" => desired,
        "environment" => %{"id" => environment_id, "selection" => selection}
      }) do
    with {:ok, biot_id} <- BiotId.parse(biot_id),
         {:ok, repository} <- RepositorySource.parse(repository),
         {:ok, desired} <- Desired.parse(desired),
         {:ok, environment_id} <- EnvironmentId.parse(environment_id),
         true <- desired.environment_id == environment_id,
         {:ok, selection} <- EnvironmentSelection.parse(selection) do
      {:ok,
       %__MODULE__{
         biot_id: biot_id,
         repository: repository,
         desired: desired,
         environment: %{id: environment_id, selection: selection}
       }}
    else
      _error -> {:error, :invalid_format}
    end
  end

  def parse(_value), do: {:error, :invalid_format}
end
