defmodule Biot.Server.TestFixtures do
  @moduledoc false

  alias Biot.Protocol.BiotId
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.Digest
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.Failure
  alias Biot.Protocol.Hostname
  alias Biot.Protocol.IncarnationId
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.OperationId
  alias Biot.Protocol.OrphanedAllocation
  alias Biot.Protocol.PinnedSource
  alias Biot.Protocol.Port
  alias Biot.Protocol.PrincipalId
  alias Biot.Protocol.RegistrationId
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector
  alias Biot.Server.Actor
  alias Biot.Server.Biots.Create
  alias Biot.Server.Nodes.Registration
  alias Biot.Server.Repo
  alias Biot.Server.Schema.AccessObservation
  alias Biot.Server.Schema.Biot, as: BiotSchema
  alias Biot.Server.Schema.Environment
  alias Biot.Server.Schema.Node
  alias Biot.Server.Schema.NodeObservation
  alias Biot.Server.Schema.Observation
  alias Biot.Server.Schema.Principal

  def id(module, number) do
    value =
      "00000000-0000-4000-8000-" <>
        (number |> Integer.to_string() |> String.pad_leading(12, "0"))

    {:ok, id} = module.parse(value)
    id
  end

  def principal(number, opts \\ []) do
    Repo.insert!(%Principal{
      id: id(PrincipalId, number),
      issuer: Keyword.get(opts, :issuer, "https://issuer.example"),
      subject: Keyword.get(opts, :subject, "subject-#{number}"),
      last_seen_email: Keyword.get(opts, :email, "person-#{number}@example.test"),
      last_seen_name: Keyword.get(opts, :name, "Person #{number}")
    })
  end

  def registration(number, opts \\ []) do
    %Registration{
      node_id: id(NodeId, number),
      registration_id: id(RegistrationId, number + 1_000),
      peer_identity: peer_identity(number),
      max_biots: Keyword.get(opts, :max_biots, 10),
      status: Keyword.get(opts, :status, :enabled)
    }
  end

  def node(number, opts \\ []) do
    registration = registration(number, opts)

    Repo.insert!(%Node{
      id: registration.node_id,
      registration: registration.registration_id,
      peer_identity: registration.peer_identity,
      max_biots: registration.max_biots,
      status: registration.status,
      platform: Keyword.get(opts, :platform)
    })
  end

  def biot(owner, node, number, opts \\ []) do
    biot_id = id(BiotId, number + 2_000)
    environment_id = id(EnvironmentId, number + 3_000)

    biot = %BiotSchema{
      id: biot_id,
      name: Keyword.get(opts, :name, "biot-#{number}"),
      owner_id: owner.id,
      node_id: node.id,
      repository: repository(),
      creation_fingerprint: Digest.compute(:creation_request_v1, "biot-#{number}"),
      desired_revision: Keyword.get(opts, :desired_revision, 1),
      desired_state: Keyword.get(opts, :desired_state, :running),
      desired_environment_id: environment_id,
      access_revision: Keyword.get(opts, :access_revision, 1),
      direct_secret_exposure_possible: Keyword.get(opts, :direct_secret_exposure_possible, false)
    }

    environment = %Environment{
      id: environment_id,
      biot_id: biot_id,
      selection: Keyword.get(opts, :selection, selection()),
      resolution: Keyword.get(opts, :resolution, :unresolved)
    }

    {:ok, {biot, environment}} =
      Repo.transaction(fn ->
        inserted_biot = Repo.insert!(biot)
        inserted_environment = Repo.insert!(environment)
        {inserted_biot, inserted_environment}
      end)

    {biot, environment}
  end

  def observation(biot, number, opts \\ []) do
    Repo.insert!(%Observation{
      biot_id: biot.id,
      connection_id: Keyword.get(opts, :connection_id, id(ConnectionId, number + 5_000)),
      received_at: DateTime.utc_now(),
      accepted_revision: Keyword.get(opts, :accepted_revision, 1),
      installed_environment_id: Keyword.get(opts, :installed_environment_id),
      container: Keyword.get(opts, :container, :unknown),
      data: Keyword.get(opts, :data, :unknown),
      failure: Keyword.get(opts, :failure)
    })
  end

  def access_observation(biot, number, opts \\ []) do
    Repo.insert!(%AccessObservation{
      biot_id: biot.id,
      connection_id: Keyword.get(opts, :connection_id, id(ConnectionId, number + 5_000)),
      applied_access_revision: Keyword.get(opts, :applied_access_revision, 1)
    })
  end

  def actor(%Principal{} = principal), do: %Actor{principal_id: principal.id}

  def node_observation(node, number, opts \\ []) do
    Repo.insert!(%NodeObservation{
      node_id: node.id,
      connection_id: Keyword.get(opts, :connection_id, id(ConnectionId, number + 5_000)),
      received_at: Keyword.get(opts, :received_at, DateTime.utc_now()),
      orphaned_allocations: Keyword.get(opts, :orphaned_allocations, [])
    })
  end

  def orphaned_allocation(number) do
    %OrphanedAllocation{
      biot_id: id(BiotId, number + 2_000),
      uid_range: %{start: 100_000 + number * 65_536, count: 65_536}
    }
  end

  def create_command(opts \\ []) do
    %Create{
      name: Keyword.get(opts, :name, "created-biot"),
      repository: Keyword.get(opts, :repository, repository()),
      environment: Keyword.get(opts, :environment, selection()),
      node_id: Keyword.get(opts, :node_id, :default),
      initial_state: Keyword.get(opts, :initial_state, :running)
    }
  end

  def execution_report(opts \\ []) do
    %ExecutionReport{
      accepted_revision: Keyword.get(opts, :accepted_revision, 1),
      installed_environment_id: Keyword.get(opts, :installed_environment_id),
      container: Keyword.get(opts, :container, :unknown),
      data: Keyword.get(opts, :data, :unknown),
      failure: Keyword.get(opts, :failure),
      waiting_for: nil
    }
  end

  def running_container(number \\ 1) do
    {:present, id(IncarnationId, number + 6_000), :running}
  end

  def connection_id(number), do: id(ConnectionId, number + 5_000)

  def selection(opts \\ []) do
    %EnvironmentSelection{
      base_nixpkgs: SourceSelector.nixpkgs(),
      layers: Keyword.get(opts, :layers, []),
      project_context: Keyword.get(opts, :project_context)
    }
  end

  def manifest(opts \\ []) do
    revision = String.duplicate(Keyword.get(opts, :revision_digit, "a"), 40)
    nar_hash = "sha256-" <> Base.encode64(:binary.copy(<<1>>, 32))
    {:ok, pinned} = PinnedSource.pin(SourceSelector.nixpkgs(), revision, nar_hash)
    Manifest.build(pinned, [], nil)
  end

  def repository(url \\ "https://github.com/example/project.git") do
    {:ok, repository} = RepositorySource.parse(url)
    repository
  end

  def failure do
    %Failure{
      stage: :start,
      code: :container_failed,
      retry: :automatic,
      message: "container did not start",
      diagnostic_ref: nil
    }
  end

  def port(number) do
    {:ok, port} = Port.parse(number)
    port
  end

  def hostname(number) do
    {:ok, hostname} = Hostname.parse("preview-#{number}")
    hostname
  end

  def operation_id(number), do: id(OperationId, number + 4_000)

  def peer_identity(number) do
    number
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(64, "0")
  end
end
