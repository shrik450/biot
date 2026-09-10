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
  """
  @type metadata :: %{stage: Failure.stage(), cancellable?: boolean()}

  @doc "Every fact about one action, in one place: adding an action adds one clause here."
  @spec metadata(t()) :: metadata()
  def metadata({:allocate, _biot_id}), do: %{stage: :allocate, cancellable?: false}

  def metadata({:initialize, _allocation, _repository}),
    do: %{stage: :initialize, cancellable?: false}

  def metadata({:resolve, _environment_id, _selection, _allocation}) do
    %{stage: :resolve, cancellable?: true}
  end

  def metadata({:prepare, _environment_id, _manifest}), do: %{stage: :prepare, cancellable?: true}
  def metadata({:retire, _incarnation_id}), do: %{stage: :retire, cancellable?: false}

  def metadata({:install, _allocation, _artifact_id, _environment_id}) do
    %{stage: :install, cancellable?: false}
  end

  def metadata({:start, _allocation, _installation}), do: %{stage: :start, cancellable?: true}

  def metadata({:release_environment, _environment_id}) do
    %{stage: :release_environment, cancellable?: false}
  end

  def metadata({:remove_data, _allocation}), do: %{stage: :remove_data, cancellable?: false}

  def metadata({:release_allocation, _allocation}) do
    %{stage: :release_allocation, cancellable?: false}
  end

  @spec stage(t()) :: Failure.stage()
  def stage(action), do: metadata(action).stage

  @spec cancellable?(t()) :: boolean()
  def cancellable?(action), do: metadata(action).cancellable?
end
