defmodule Biot.Node.Host do
  @moduledoc "Inspects one Biot's host resources and runs one reconciliation action."

  alias Biot.Node.Action
  alias Biot.Node.Host.Allocation, as: HostAllocation
  alias Biot.Node.Host.Container
  alias Biot.Node.Host.Context
  alias Biot.Node.Host.Environment
  alias Biot.Node.Host.Inspection
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Journal
  alias Biot.Protocol.BiotId

  @type result :: :ok | {:error, Outcome.t()}

  @spec context(BiotId.t()) :: {:ok, Context.t()} | {:error, term()}
  def context(%BiotId{} = biot_id), do: Context.from_application(biot_id)

  @spec inspect_state(BiotId.t(), Context.t()) :: Inspection.t()
  def inspect_state(%BiotId{} = biot_id, %Context{biot_id: biot_id, config: config}) do
    allocation = Journal.allocation(biot_id)
    resolution_rows = Journal.resolutions(biot_id)
    prepared = Environment.prepared(config, resolution_rows)

    %Inspection{
      data: data(config, allocation),
      resolutions: Environment.resolutions(config, resolution_rows),
      installation: Environment.installation(Journal.installation(biot_id), prepared),
      container: Container.state(config, biot_id),
      prepared: prepared
    }
  end

  @spec run(Action.t(), Context.t()) :: result()
  def run({:allocate, biot_id}, %Context{biot_id: biot_id} = context) do
    HostAllocation.allocate(context)
  end

  def run({:initialize, allocation, repository}, %Context{} = context) do
    HostAllocation.initialize(context, allocation, repository)
  end

  def run({:resolve, environment_id, selection, allocation}, %Context{} = context) do
    Environment.resolve(context, environment_id, selection, allocation)
  end

  def run({:prepare, environment_id, manifest}, %Context{} = context) do
    Environment.prepare(context, environment_id, manifest)
  end

  def run({:retire, incarnation_id}, %Context{} = context) do
    Container.retire(context, incarnation_id)
  end

  def run({:install, allocation, artifact_id, environment_id}, %Context{} = context) do
    Environment.install(context, allocation, artifact_id, environment_id)
  end

  def run({:start, allocation, installation}, %Context{} = context) do
    Container.start(context, allocation, installation)
  end

  def run({:release_environment, environment_id}, %Context{} = context) do
    Environment.release(context, environment_id)
  end

  def run({:remove_data, allocation}, %Context{} = context) do
    HostAllocation.remove_data(context, allocation)
  end

  def run({:release_allocation, allocation}, %Context{} = context) do
    HostAllocation.release(context, allocation)
  end

  defp data(_config, nil), do: :no_allocation
  defp data(config, allocation), do: HostAllocation.state(config, allocation)
end
