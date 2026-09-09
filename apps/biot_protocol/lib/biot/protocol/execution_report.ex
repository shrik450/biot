defmodule Biot.Protocol.ExecutionReport do
  @moduledoc "The node-supplied execution facts stored as a biot observation."

  alias Biot.Protocol.ContainerState
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.Failure
  alias Biot.Protocol.IncarnationId
  alias Biot.Protocol.StrictMap

  @fields [
    "accepted_revision",
    "installed_environment_id",
    "container",
    "data",
    "failure"
  ]
  @present_container_fields ["state", "incarnation_id", "container_state"]
  @reported_failure_fields ["target_revision", "failure"]

  @data_states [:no_allocation, :unknown, :uninitialized, :present, :lost]
  @type data_state :: :no_allocation | :unknown | :uninitialized | :present | :lost

  @type container :: :unknown | :absent | {:present, IncarnationId.t(), ContainerState.t()}
  @type reported_failure :: nil | {pos_integer(), Failure.t()}

  @enforce_keys [
    :accepted_revision,
    :installed_environment_id,
    :container,
    :data,
    :failure
  ]
  defstruct [
    :accepted_revision,
    :installed_environment_id,
    :container,
    :data,
    :failure
  ]

  @type t :: %__MODULE__{
          accepted_revision: pos_integer(),
          installed_environment_id: EnvironmentId.t() | nil,
          container: container(),
          data: data_state(),
          failure: reported_failure()
        }

  @spec data_states() :: [data_state()]
  def data_states, do: @data_states

  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = report) do
    %{
      "accepted_revision" => report.accepted_revision,
      "installed_environment_id" => encode_environment_id(report.installed_environment_id),
      "container" => encode_container(report.container),
      "data" => Atom.to_string(report.data),
      "failure" => encode_failure(report.failure)
    }
  end

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(value) do
    with {:ok,
          %{
            "accepted_revision" => accepted_revision,
            "installed_environment_id" => installed_environment_id,
            "container" => container,
            "data" => data,
            "failure" => failure
          }} <- StrictMap.fetch_exact(value, @fields),
         true <- is_integer(accepted_revision) and accepted_revision > 0,
         {:ok, installed_environment_id} <- parse_environment_id(installed_environment_id),
         {:ok, container} <- parse_container(container),
         {:ok, data} <- parse_data(data),
         {:ok, failure} <- parse_failure(failure) do
      {:ok,
       %__MODULE__{
         accepted_revision: accepted_revision,
         installed_environment_id: installed_environment_id,
         container: container,
         data: data,
         failure: failure
       }}
    else
      _error -> {:error, :invalid_format}
    end
  end

  defp encode_environment_id(nil), do: nil
  defp encode_environment_id(environment_id), do: EnvironmentId.to_string(environment_id)

  defp parse_environment_id(nil), do: {:ok, nil}
  defp parse_environment_id(environment_id), do: EnvironmentId.parse(environment_id)

  @spec encode_container(container()) :: map()
  def encode_container(:unknown), do: %{"state" => "unknown"}
  def encode_container(:absent), do: %{"state" => "absent"}

  def encode_container({:present, incarnation_id, container_state}) do
    %{
      "state" => "present",
      "incarnation_id" => IncarnationId.to_string(incarnation_id),
      "container_state" => ContainerState.encode(container_state)
    }
  end

  @spec parse_container(term()) :: {:ok, container()} | {:error, :invalid_format}
  def parse_container(%{"state" => "unknown"} = container) do
    with {:ok, _container} <- StrictMap.fetch_exact(container, ["state"]), do: {:ok, :unknown}
  end

  def parse_container(%{"state" => "absent"} = container) do
    with {:ok, _container} <- StrictMap.fetch_exact(container, ["state"]), do: {:ok, :absent}
  end

  def parse_container(
        %{
          "state" => "present",
          "incarnation_id" => incarnation_id,
          "container_state" => container_state
        } = container
      ) do
    with {:ok, _container} <- StrictMap.fetch_exact(container, @present_container_fields),
         {:ok, incarnation_id} <- IncarnationId.parse(incarnation_id),
         {:ok, container_state} <- ContainerState.parse(container_state) do
      {:ok, {:present, incarnation_id, container_state}}
    end
  end

  def parse_container(_container), do: {:error, :invalid_format}

  defp parse_data(value) when is_binary(value) do
    case Enum.find(@data_states, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_format}
      data -> {:ok, data}
    end
  end

  defp parse_data(_value), do: {:error, :invalid_format}

  defp encode_failure(nil), do: nil

  defp encode_failure({target_revision, failure}) do
    %{"target_revision" => target_revision, "failure" => Failure.encode(failure)}
  end

  defp parse_failure(nil), do: {:ok, nil}

  defp parse_failure(
         %{"target_revision" => target_revision, "failure" => failure} = reported_failure
       ) do
    with {:ok, _reported_failure} <-
           StrictMap.fetch_exact(reported_failure, @reported_failure_fields),
         true <- is_integer(target_revision) and target_revision > 0,
         {:ok, failure} <- Failure.parse(failure) do
      {:ok, {target_revision, failure}}
    end
  end

  defp parse_failure(_failure), do: {:error, :invalid_format}
end
