defmodule BiotWeb.TestFixtures do
  @moduledoc false

  alias Biot.Protocol.{BiotId, Digest, EnvironmentId, EnvironmentSelection, NodeId}
  alias Biot.Protocol.{Port, PrincipalId, RegistrationId, RepositorySource, SourceSelector}
  alias Biot.Server.Actor
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Biot, Environment, Node, Principal}

  @spec id(module(), integer()) :: struct()
  def id(module, number) do
    value =
      "00000000-0000-4000-8000-" <>
        (number |> Integer.to_string() |> String.pad_leading(12, "0"))

    {:ok, id} = module.parse(value)
    id
  end

  @spec principal(integer(), keyword()) :: Principal.t()
  def principal(number, options \\ []) do
    Repo.insert!(%Principal{
      id: id(PrincipalId, number),
      issuer: Keyword.get(options, :issuer, "https://issuer.example"),
      subject: Keyword.get(options, :subject, "subject-#{number}"),
      last_seen_email: Keyword.get(options, :email, "person-#{number}@example.test"),
      last_seen_name: Keyword.get(options, :name, "Person #{number}")
    })
  end

  @spec actor(Principal.t()) :: Actor.t()
  def actor(%Principal{id: id}), do: %Actor{principal_id: id}

  @spec port(integer()) :: Port.t()
  def port(value) do
    {:ok, port} = Port.parse(value)
    port
  end

  @spec node(integer(), keyword()) :: Node.t()
  def node(number, options \\ []) do
    Repo.insert!(%Node{
      id: id(NodeId, number),
      registration: id(RegistrationId, number + 1_000),
      peer_identity: String.duplicate("0", 63) <> Integer.to_string(number, 16),
      status: Keyword.get(options, :status, :enabled),
      platform: Keyword.get(options, :platform),
      max_biots: Keyword.get(options, :max_biots, 10)
    })
  end

  @spec biot(Principal.t(), Node.t(), integer(), keyword()) :: {Biot.t(), Environment.t()}
  def biot(owner, node, number, options \\ []) do
    biot_id = id(BiotId, number + 2_000)
    environment_id = id(EnvironmentId, number + 3_000)

    biot = %Biot{
      id: biot_id,
      name: Keyword.get(options, :name, "biot-#{number}"),
      owner_id: owner.id,
      node_id: node.id,
      repository: repository(),
      creation_fingerprint: Digest.compute(:creation_request_v1, "biot-#{number}"),
      desired_revision: Keyword.get(options, :desired_revision, 1),
      desired_state: Keyword.get(options, :desired_state, :running),
      desired_environment_id: environment_id,
      access_revision: Keyword.get(options, :access_revision, 1),
      direct_secret_exposure_possible:
        Keyword.get(options, :direct_secret_exposure_possible, false)
    }

    environment = %Environment{
      id: environment_id,
      biot_id: biot_id,
      selection: selection(),
      resolution: :unresolved
    }

    {:ok, {biot, environment}} =
      Repo.transaction(fn -> {Repo.insert!(biot), Repo.insert!(environment)} end)

    {biot, environment}
  end

  @spec repository() :: RepositorySource.t()
  def repository do
    {:ok, repository} = RepositorySource.parse("https://github.com/example/project.git")
    repository
  end

  @spec selection() :: EnvironmentSelection.t()
  def selection do
    %EnvironmentSelection{
      base_nixpkgs: SourceSelector.nixpkgs(),
      layers: [],
      project_context: nil
    }
  end
end
