defmodule Biot.Node.Action do
  @moduledoc """
  The host effects reconciliation may ask for, and the facts about each one that the pure core and
  the controller must agree on. Every action names its own resources, so running it twice converges
  instead of creating a second resource.
  """

  alias Biot.Node.Allocation
  alias Biot.Node.ArtifactId
  alias Biot.Node.Installation
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.Failure
  alias Biot.Protocol.IncarnationId
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.RepositorySource

  @typedoc """
  `release_environment` gives back both the prepared artifact and the resolution snapshot of one
  environment, because a released environment needs neither.
  """
  @type t ::
          {:allocate, BiotId.t()}
          | {:initialize, Allocation.t(), RepositorySource.t()}
          | {:resolve, EnvironmentId.t(), EnvironmentSelection.t(), Allocation.t()}
          | {:prepare, EnvironmentId.t(), Manifest.t()}
          | {:retire, IncarnationId.t()}
          | {:install, Allocation.t(), ArtifactId.t(), EnvironmentId.t()}
          | {:start, Allocation.t(), Installation.t()}
          | {:release_environment, EnvironmentId.t()}
          | {:remove_data, Allocation.t()}
          | {:release_allocation, Allocation.t()}

  @typedoc """
  Everything the rest of the node needs to know about an action without matching its shape:

    * `stage` names the lifecycle stage a failure of it belongs to.
    * `cancellable?` says whether a stop or a destruction may cancel it rather than wait for it.
      Preparation and a start have no value once execution is meant to end, and a preparation can
      take minutes.
    * `requires_control?` says whether the node needs a live control link before it begins. These
      four produce state the server must learn about; giving resources back needs no link.
    * `environments` lists the environments whose resources the action needs, so reclamation never
      releases one out from under a running action.
  """
  @type metadata :: %{
          stage: Failure.stage(),
          cancellable?: boolean(),
          requires_control?: boolean(),
          environments: [EnvironmentId.t()]
        }

  @doc "Every fact about one action, in one place: adding an action adds one clause here."
  @spec metadata(t()) :: metadata()
  def metadata({:allocate, _biot_id}) do
    %{stage: :allocate, cancellable?: false, requires_control?: false, environments: []}
  end

  def metadata({:initialize, _allocation, _repository}) do
    %{stage: :initialize, cancellable?: false, requires_control?: false, environments: []}
  end

  def metadata({:resolve, environment_id, _selection, _allocation}) do
    %{
      stage: :resolve,
      cancellable?: true,
      requires_control?: true,
      environments: [environment_id]
    }
  end

  def metadata({:prepare, environment_id, _manifest}) do
    %{
      stage: :prepare,
      cancellable?: true,
      requires_control?: true,
      environments: [environment_id]
    }
  end

  def metadata({:retire, _incarnation_id}) do
    %{stage: :retire, cancellable?: false, requires_control?: false, environments: []}
  end

  def metadata({:install, _allocation, _artifact_id, environment_id}) do
    %{
      stage: :install,
      cancellable?: false,
      requires_control?: true,
      environments: [environment_id]
    }
  end

  def metadata({:start, _allocation, %Installation{environment_id: environment_id}}) do
    %{stage: :start, cancellable?: true, requires_control?: true, environments: [environment_id]}
  end

  def metadata({:release_environment, environment_id}) do
    %{
      stage: :release_environment,
      cancellable?: false,
      requires_control?: false,
      environments: [environment_id]
    }
  end

  def metadata({:remove_data, _allocation}) do
    %{stage: :remove_data, cancellable?: false, requires_control?: false, environments: []}
  end

  def metadata({:release_allocation, _allocation}) do
    %{stage: :release_allocation, cancellable?: false, requires_control?: false, environments: []}
  end

  @spec stage(t()) :: Failure.stage()
  def stage(action), do: metadata(action).stage

  @spec cancellable?(t()) :: boolean()
  def cancellable?(action), do: metadata(action).cancellable?

  @spec requires_control?(t()) :: boolean()
  def requires_control?(action), do: metadata(action).requires_control?

  @spec environments(t()) :: [EnvironmentId.t()]
  def environments(action), do: metadata(action).environments
end
