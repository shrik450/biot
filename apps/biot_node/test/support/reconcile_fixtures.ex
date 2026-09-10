defmodule Biot.Node.ReconcileFixtures do
  @moduledoc """
  Named builders for the values the pure reconciliation core reads, so every test states only the
  facts it is about. Each builder returns a well-formed value: `state/1` starts from a biot that
  owns nothing and takes overrides for the facts under test.
  """

  alias Biot.Node.Allocation
  alias Biot.Node.ArtifactId
  alias Biot.Node.Diagnostic
  alias Biot.Node.InspectionFailure
  alias Biot.Node.Installation
  alias Biot.Node.NetworkId
  alias Biot.Node.NodePrivatePath
  alias Biot.Node.NodeState
  alias Biot.Node.Resolution
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.ExecutionSpec
  alias Biot.Protocol.IncarnationId
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.PinnedSource
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector

  @uuid "00000000-0000-4000-8000-0000000000"

  def biot_id, do: parse!(BiotId, @uuid <> "b1")
  def other_biot_id, do: parse!(BiotId, @uuid <> "b2")

  def e1, do: parse!(EnvironmentId, @uuid <> "e1")
  def e2, do: parse!(EnvironmentId, @uuid <> "e2")
  def e3, do: parse!(EnvironmentId, @uuid <> "e3")

  def incarnation, do: parse!(IncarnationId, @uuid <> "c1")
  def next_incarnation, do: parse!(IncarnationId, @uuid <> "c2")
  def network, do: parse!(NetworkId, @uuid <> "f1")

  def data_root, do: parse!(NodePrivatePath, "/var/lib/biot/allocations/b1")
  def snapshot_path, do: parse!(NodePrivatePath, "/var/lib/biot/resolutions/e1")

  def artifact(environment_id) do
    parse!(ArtifactId, "/nix/store/biot-env-" <> EnvironmentId.to_string(environment_id))
  end

  def repository, do: parse!(RepositorySource, "https://example.com/app.git")

  def selection do
    %EnvironmentSelection{
      base_nixpkgs: SourceSelector.nixpkgs(),
      layers: [],
      project_context: nil
    }
  end

  def manifest do
    nar_hash = "sha256-" <> Base.encode64(:binary.copy(<<7>>, 32))
    pinned = parse!(PinnedSource, "nixpkgs#" <> String.duplicate("a", 40) <> "#" <> nar_hash)
    Manifest.build(pinned, [], nil)
  end

  @doc "An allocation whose initialization completed, which is what `{:present, _}` data means."
  def allocation do
    %Allocation{
      biot_id: biot_id(),
      uid_range: %{start: 500_000, count: 65_536},
      data_root: data_root(),
      network_id: network(),
      initialization: :complete
    }
  end

  @doc "An allocation that has never been initialized, which is what `{:uninitialized, _}` means."
  def fresh_allocation, do: %Allocation{allocation() | initialization: :uninitialized}

  def installation(environment_id) do
    %Installation{
      biot_id: biot_id(),
      environment_id: environment_id,
      artifact_id: artifact(environment_id)
    }
  end

  def resolution(environment_id) do
    %Resolution{
      environment_id: environment_id,
      manifest: manifest(),
      snapshot_path: snapshot_path()
    }
  end

  def inspection(resource, reason \\ :unavailable) do
    %InspectionFailure{
      resource: resource,
      reason: reason,
      detail: Diagnostic.text("the host could not be read")
    }
  end

  @doc "A live container this biot owns, running one environment."
  def running(environment_id), do: container(biot_id(), environment_id, :running)

  @doc "A container this biot owns that has exited."
  def exited(environment_id, status), do: container(biot_id(), environment_id, {:exited, status})

  @doc "A container another biot owns, which this biot may never remove."
  def foreign(environment_id), do: container(other_biot_id(), environment_id, :running)

  def container(owner, environment_id, container_state) do
    {:present,
     %{
       incarnation_id: incarnation(),
       biot_id: owner,
       environment_id: environment_id,
       state: container_state
     }}
  end

  @doc """
  The derived state of a biot that owns nothing yet. Overrides name the facts under test, such as
  `state(data: {:present, allocation()}, container: running(e1()))`.
  """
  def state(overrides \\ []) do
    struct!(
      %NodeState{
        data: :no_allocation,
        resolutions: %{},
        installation: nil,
        container: :absent,
        prepared: %{},
        pending_exit: nil,
        failure: nil
      },
      overrides
    )
  end

  @doc """
  Server intent for this biot. `state:` is the desired execution state, `environment_id:` the
  desired environment, and `revision:` the desired revision a recorded failure is compared against.
  """
  def spec(overrides \\ []) do
    desired_state = Keyword.get(overrides, :state, :running)
    environment_id = Keyword.get(overrides, :environment_id, e1())
    revision = Keyword.get(overrides, :revision, 1)

    %ExecutionSpec{
      biot_id: Keyword.get(overrides, :biot_id, biot_id()),
      repository: repository(),
      desired: %Desired{
        revision: revision,
        state: desired_state,
        environment_id: environment_id
      },
      environment: %{id: environment_id, selection: selection()}
    }
  end

  @doc "The state of a biot running `environment_id` with everything settled behind it."
  def settled(environment_id) do
    state(
      data: {:present, allocation()},
      resolutions: %{environment_id => {:present, resolution(environment_id)}},
      installation: {:present, installation(environment_id)},
      container: running(environment_id),
      prepared: %{environment_id => {:present, artifact(environment_id)}}
    )
  end

  defp parse!(module, value) do
    {:ok, parsed} = module.parse(value)
    parsed
  end
end
