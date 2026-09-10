defmodule Biot.Node.RuntimeLogs.Metadata do
  @moduledoc "Owns the runtime log metadata file and its incarnation guard."

  alias Biot.Node.Host.Config
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Paths
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.IncarnationId

  @type value :: {IncarnationId.t(), boolean()}

  @spec read(Config.t(), BiotId.t()) :: {:ok, value()} | {:error, term()}
  def read(%Config{} = config, %BiotId{} = biot_id) do
    with {:ok, encoded} <- File.read(Paths.runtime_log_metadata(config, biot_id)),
         {:ok, decoded} <- Jason.decode(encoded),
         {:ok, incarnation_id, truncated} <- parse(decoded) do
      {:ok, {incarnation_id, truncated}}
    end
  end

  @spec write(Config.t(), BiotId.t(), IncarnationId.t(), boolean()) :: :ok | {:error, term()}
  def write(
        %Config{} = config,
        %BiotId{} = biot_id,
        %IncarnationId{} = incarnation_id,
        truncated
      )
      when is_boolean(truncated) do
    metadata = %{
      "incarnation_id" => IncarnationId.to_string(incarnation_id),
      "truncated" => truncated
    }

    FileSystem.write_atomic(Paths.runtime_log_metadata(config, biot_id), Jason.encode!(metadata))
  end

  @spec mark_truncated(Config.t(), BiotId.t(), IncarnationId.t()) :: :ok | {:error, term()}
  def mark_truncated(
        %Config{} = config,
        %BiotId{} = biot_id,
        %IncarnationId{} = incarnation_id
      ) do
    case read(config, biot_id) do
      {:ok, {^incarnation_id, false}} -> write(config, biot_id, incarnation_id, true)
      {:ok, {^incarnation_id, true}} -> :ok
      {:ok, {_other_incarnation_id, _truncated}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp parse(%{"incarnation_id" => value, "truncated" => truncated} = metadata)
       when map_size(metadata) == 2 and is_binary(value) and is_boolean(truncated) do
    case IncarnationId.parse(value) do
      {:ok, incarnation_id} -> {:ok, incarnation_id, truncated}
      {:error, _reason} = error -> error
    end
  end

  defp parse(_value), do: {:error, :invalid_metadata}
end
