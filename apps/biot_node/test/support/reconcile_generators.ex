defmodule Biot.Node.ReconcileGenerators do
  @moduledoc """
  Generators over every variant of the reconciliation inputs, and validators for the result shapes
  `Biot.Node.Reconcile.next/3` declares. The generators keep each derived state well formed: an
  uninitialized allocation never carries a completion marker, and a resolution entry always
  describes its own environment.
  """

  import ExUnitProperties
  import StreamData

  alias Biot.Node.Allocation
  alias Biot.Node.ArtifactId
  alias Biot.Node.BlockReason
  alias Biot.Node.InspectionFailure
  alias Biot.Node.Installation
  alias Biot.Node.NodeState
  alias Biot.Node.ReconcileFixtures, as: Fixtures
  alias Biot.Node.Retry
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.Failure
  alias Biot.Protocol.IncarnationId
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.RepositorySource

  @reasons [
    :host_unavailable,
    {:container_exited, 137},
    :invalid_source,
    :resolution_failed,
    :build_failed,
    :invalid_configuration,
    :lost_data,
    :ownership_mismatch
  ]

  @stages ~w(allocate initialize resolve prepare install start retire release_environment remove_data release_allocation)a

  def environment_id, do: member_of([Fixtures.e1(), Fixtures.e2(), Fixtures.e3()])

  @doc "Every subset of this biot's environments, so a map keyed by them holds 0 to 3 entries."
  def environment_subset do
    member_of([
      [],
      [Fixtures.e1()],
      [Fixtures.e2()],
      [Fixtures.e3()],
      [Fixtures.e1(), Fixtures.e2()],
      [Fixtures.e1(), Fixtures.e3()],
      [Fixtures.e2(), Fixtures.e3()],
      [Fixtures.e1(), Fixtures.e2(), Fixtures.e3()]
    ])
  end

  def data_state do
    one_of([
      constant(:no_allocation),
      constant({:unknown, Fixtures.allocation(), Fixtures.inspection(:allocation)}),
      constant({:uninitialized, Fixtures.fresh_allocation()}),
      constant({:present, Fixtures.allocation()}),
      constant({:lost, Fixtures.allocation()})
    ])
  end

  def installation_state do
    one_of([
      constant(nil),
      map(
        environment_id(),
        &{:unknown, Fixtures.installation(&1), Fixtures.inspection(:installation)}
      ),
      map(environment_id(), &{:present, Fixtures.installation(&1)}),
      map(environment_id(), &{:lost, Fixtures.installation(&1)})
    ])
  end

  def resolution_state(environment_id) do
    one_of([
      constant({:unknown, Fixtures.resolution(environment_id), Fixtures.inspection(:resolution)}),
      constant({:present, Fixtures.resolution(environment_id)}),
      constant({:lost, Fixtures.resolution(environment_id)})
    ])
  end

  def resolutions do
    bind(environment_subset(), fn environment_ids ->
      environment_ids
      |> Enum.map(fn id -> map(resolution_state(id), &{id, &1}) end)
      |> fixed_list()
      |> map(&Map.new/1)
    end)
  end

  def container_state do
    one_of([constant(:running), map(integer(0..255), &{:exited, &1})])
  end

  def container do
    one_of([
      constant(:absent),
      constant({:unknown, Fixtures.inspection(:container)}),
      gen all(
            environment_id <- environment_id(),
            owner <- member_of([Fixtures.biot_id(), Fixtures.other_biot_id()]),
            container_state <- container_state()
          ) do
        Fixtures.container(owner, environment_id, container_state)
      end
    ])
  end

  def prepared do
    bind(environment_subset(), fn environment_ids ->
      environment_ids
      |> Enum.map(fn id ->
        map(
          member_of([
            :absent,
            {:unknown, Fixtures.inspection(:prepared)},
            {:present, Fixtures.artifact(id)}
          ]),
          &{id, &1}
        )
      end)
      |> fixed_list()
      |> map(&Map.new/1)
    end)
  end

  def pending_exit do
    one_of([
      constant(nil),
      map(integer(0..255), &%{incarnation_id: Fixtures.incarnation(), exit_status: &1})
    ])
  end

  def failure do
    gen all(reason <- member_of(@reasons), stage <- member_of(@stages)) do
      Retry.failure(reason, stage)
    end
  end

  def recorded_failure do
    one_of([
      constant(nil),
      gen all(revision <- integer(1..3), failure <- failure()) do
        {revision, failure}
      end
    ])
  end

  def node_state do
    gen all(
          data <- data_state(),
          resolutions <- resolutions(),
          installation <- installation_state(),
          container <- container(),
          prepared <- prepared(),
          pending_exit <- pending_exit(),
          failure <- recorded_failure()
        ) do
      %NodeState{
        data: data,
        resolutions: resolutions,
        installation: installation,
        container: container,
        prepared: prepared,
        pending_exit: pending_exit,
        failure: failure
      }
    end
  end

  def execution_spec do
    gen all(
          desired_state <- member_of(Desired.states()),
          environment_id <- environment_id(),
          revision <- integer(1..3)
        ) do
      Fixtures.spec(state: desired_state, environment_id: environment_id, revision: revision)
    end
  end

  @action_tags ~w(allocate initialize resolve prepare retire install start release_environment remove_data release_allocation)a

  @doc "Every action, or only those with the given tags, so a test can name the set it means."
  def action(tags \\ @action_tags) do
    one_of(Enum.map(tags, &tagged_action/1))
  end

  defp tagged_action(:allocate), do: constant({:allocate, Fixtures.biot_id()})

  defp tagged_action(:initialize) do
    constant({:initialize, Fixtures.fresh_allocation(), Fixtures.repository()})
  end

  defp tagged_action(:resolve) do
    map(environment_id(), &{:resolve, &1, Fixtures.selection(), Fixtures.allocation()})
  end

  defp tagged_action(:prepare),
    do: map(environment_id(), &{:prepare, &1, Fixtures.manifest(), Fixtures.allocation()})

  defp tagged_action(:retire), do: constant({:retire, Fixtures.incarnation()})

  defp tagged_action(:install) do
    map(environment_id(), &{:install, Fixtures.allocation(), Fixtures.artifact(&1), &1})
  end

  defp tagged_action(:start) do
    map(environment_id(), &{:start, Fixtures.allocation(), Fixtures.installation(&1)})
  end

  defp tagged_action(:release_environment),
    do: map(environment_id(), &{:release_environment, &1, Fixtures.allocation()})

  defp tagged_action(:remove_data), do: constant({:remove_data, Fixtures.allocation()})

  defp tagged_action(:release_allocation),
    do: constant({:release_allocation, Fixtures.allocation()})

  def current_action, do: one_of([constant(nil), action()])

  @doc "Whether a result is one of the five shapes `Reconcile.next/3` declares."
  def valid_result?(:settled), do: true
  def valid_result?(:cancel_current), do: true
  def valid_result?({:run, action}), do: valid_action?(action)
  def valid_result?({:blocked, reason}), do: valid_block_reason?(reason)
  def valid_result?({:failed, %Failure{}}), do: true
  def valid_result?(_other), do: false

  @doc "Whether a term is one of the ten actions `Biot.Node.Action` declares, with its own fields."
  @spec valid_action?(term()) :: boolean()
  def valid_action?({:allocate, %BiotId{}}), do: true
  def valid_action?({:initialize, %Allocation{}, %RepositorySource{}}), do: true

  def valid_action?({:resolve, %EnvironmentId{}, %EnvironmentSelection{}, %Allocation{}}),
    do: true

  def valid_action?({:prepare, %EnvironmentId{}, %Manifest{}, %Allocation{}}), do: true
  def valid_action?({:retire, %IncarnationId{}}), do: true

  def valid_action?({:install, %Allocation{}, %ArtifactId{}, %EnvironmentId{}}), do: true
  def valid_action?({:start, %Allocation{}, %Installation{}}), do: true
  def valid_action?({:release_environment, %EnvironmentId{}, %Allocation{}}), do: true
  def valid_action?({:remove_data, %Allocation{}}), do: true
  def valid_action?({:release_allocation, %Allocation{}}), do: true
  def valid_action?(_other), do: false

  @doc "Whether a term is one of the three block reasons `#{inspect(BlockReason)}` declares."
  @spec valid_block_reason?(term()) :: boolean()
  def valid_block_reason?({:inspection, %InspectionFailure{}}), do: true
  def valid_block_reason?({:current_action, action}), do: valid_action?(action)
  def valid_block_reason?({:recorded_failure, %Failure{}}), do: true
  def valid_block_reason?(_other), do: false
end
