defmodule Biot.Node.Host do
  @moduledoc "Inspects one Biot's host resources and runs one reconciliation action."

  alias Biot.Node.Action
  alias Biot.Node.Allocation
  alias Biot.Node.Host.Allocation, as: HostAllocation
  alias Biot.Node.Host.Container
  alias Biot.Node.Host.Context
  alias Biot.Node.Host.Environment
  alias Biot.Node.Host.FetchCredentials
  alias Biot.Node.Host.Inspection
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Host.Secrets
  alias Biot.Node.Host.Worker
  alias Biot.Node.Journal
  alias Biot.Node.SecretRequest
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SecretOutcome

  @typedoc """
  What one action answers.

  `{:waiting_for, source}` is neither success nor failure: the action reached a source it cannot
  read without a credential the node does not hold. Nothing is wrong and nothing can proceed, so
  the controller records the wait rather than a failure and spends no retry budget on it.
  """
  @type result :: :ok | {:waiting_for, RepositorySource.t()} | {:error, Outcome.t()}

  @spec context(BiotId.t()) :: {:ok, Context.t()} | {:error, term()}
  def context(%BiotId{} = biot_id), do: Context.from_application(biot_id)

  @spec inspect_state(BiotId.t(), Context.t()) :: Inspection.t()
  def inspect_state(%BiotId{} = biot_id, %Context{biot_id: biot_id, config: config}) do
    allocation = Journal.allocation(biot_id)
    resolution_rows = Journal.resolutions(biot_id)
    prepared = Environment.prepared(config, biot_id, resolution_rows)
    container = Container.state(config, biot_id)

    %Inspection{
      data: data(config, allocation),
      resolutions: Environment.resolutions(config, biot_id, resolution_rows),
      installation: Environment.installation(Journal.installation(biot_id), prepared),
      container: container,
      prepared: prepared
    }
  end

  @doc """
  Ends any build worker this allocation still owns and confirms it is gone.

  A controller calls this before its first reconciliation, because a worker that outlived its
  controller holds the store the next action writes.
  """
  @spec recover(Context.t()) :: result()
  def recover(%Context{biot_id: biot_id, config: config}) do
    Worker.cancel(config, biot_id)
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

  def run({:prepare, environment_id, manifest, allocation}, %Context{} = context) do
    Environment.prepare(context, environment_id, manifest, allocation)
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

  def run({:release_environment, environment_id, allocation}, %Context{} = context) do
    Environment.release(context, environment_id, allocation)
  end

  def run({:remove_data, allocation}, %Context{} = context) do
    HostAllocation.remove_data(context, allocation)
  end

  def run({:release_allocation, allocation}, %Context{} = context) do
    HostAllocation.release(context, allocation)
  end

  @doc """
  Answers one secret or fetch credential request against this biot's allocation.

  A request reads the allocation rather than establishing one, which is the difference between
  this and `run/2`: an action converges on the resources the biot should have, while a request
  only uses the ones it already has.
  """
  @spec serve(SecretRequest.operation(), Context.t()) ::
          SecretOutcome.t() | SecretOutcome.listing()
  def serve(operation, %Context{biot_id: biot_id, config: config}) do
    case Journal.allocation(biot_id) do
      nil -> :no_allocation
      %Allocation{} = allocation -> serve_allocated(operation, config, allocation)
    end
  end

  defp serve_allocated({:deliver_secret, name, value}, config, allocation) do
    Secrets.write(config, allocation, name, value)
  end

  defp serve_allocated({:remove_secret, name}, config, allocation) do
    Secrets.remove(config, allocation, name)
  end

  defp serve_allocated(:list_secrets, config, allocation) do
    Secrets.list(config, allocation)
  end

  defp serve_allocated({:deliver_fetch_credential, source, value}, config, allocation) do
    FetchCredentials.put(config, allocation, source, value)
  end

  defp serve_allocated({:remove_fetch_credential, source}, config, allocation) do
    FetchCredentials.remove(config, allocation, source)
  end

  defp data(_config, nil), do: :no_allocation
  defp data(config, allocation), do: HostAllocation.state(config, allocation)
end
