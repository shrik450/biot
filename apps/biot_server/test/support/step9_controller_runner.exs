defmodule Biot.Server.Step9ControllerRunner do
  @moduledoc false

  alias Biot.Node.Controllers
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Paths
  alias Biot.Node.Journal
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.ExecutionSpec
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector
  alias Biot.Server.Actor
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Create
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Node
  alias Biot.Server.Schema.Observation
  alias Biot.Server.Schema.Principal

  def run do
    prove_lost_create_response()
    prove_startup_and_retry()
  end

  defp prove_lost_create_response do
    principal = Repo.all(Principal) |> hd()
    node = Repo.all(Node) |> hd()
    actor = %Actor{principal_id: principal.id}
    biot_id = id(BiotId)
    command = create_command(node.id)

    {:ok, first} = Biots.create(actor, biot_id, command)
    {:ok, ^first} = Biots.create(actor, biot_id, command)

    allocation =
      eventually_value(fn ->
        case Journal.allocation(biot_id) do
          %{initialization: :complete} = allocation -> allocation
          _allocation -> nil
        end
      end)

    {:ok, config} = Config.from_application()
    checkout = Paths.checkout(config, biot_id)
    "step 9 project checkout\n" = File.read!(Path.join(checkout, "README.md"))
    false = File.exists?(Paths.checkout_staging(config, biot_id))

    receive do
    after
      500 -> :ok
    end

    %{initialization: initialization} = Journal.allocation(biot_id)
    ^initialization = allocation.initialization
    {:ok, destroyed} = Biots.destroy(actor, biot_id)

    true =
      eventually(fn ->
        case Repo.get(Observation, biot_id) do
          %{accepted_revision: revision, data: :no_allocation} -> revision == destroyed.revision
          _observation -> false
        end
      end)
  end

  defp prove_startup_and_retry do
    first = id(BiotId)
    second = id(BiotId)
    {:ok, _intent} = Journal.put_intent(spec(first))
    {:ok, _intent} = Journal.put_intent(spec(second))

    :ok = Supervisor.terminate_child(Biot.Node.Supervisor, Controllers)
    {:ok, _controllers} = Supervisor.restart_child(Biot.Node.Supervisor, Controllers)

    true =
      eventually(fn ->
        running = MapSet.new(Controllers.running(), &elem(&1, 0))
        MapSet.subset?(MapSet.new([first, second]), running)
      end)

    retried = id(BiotId)
    {:ok, _intent} = Journal.put_intent(spec(retried))
    previous = Application.get_env(:biot_node, :uid_range_count)
    Application.put_env(:biot_node, :uid_range_count, nil)
    {:error, {^retried, _reason}} = Controllers.intent_changed(retried)
    Application.put_env(:biot_node, :uid_range_count, previous)

    true =
      eventually(fn ->
        Enum.any?(Controllers.running(), fn {biot_id, _pid} -> biot_id == retried end)
      end)

    {:ok, _removed} = Journal.replace_intents([])
    :ok = Controllers.synchronized([])
    true = eventually(fn -> Controllers.running() == [] end)
  end

  defp create_command(node_id) do
    %Create{
      name: "lost-response-#{System.unique_integer([:positive])}",
      repository: repository("https://sources.biot.test/project"),
      environment: selection(),
      node_id: node_id
    }
  end

  defp spec(biot_id) do
    environment_id = id(EnvironmentId)

    %BiotSpec{
      execution: %ExecutionSpec{
        biot_id: biot_id,
        repository: repository("https://sources.biot.test/project"),
        desired: %Desired{revision: 1, state: :destroyed, environment_id: environment_id},
        environment: %{id: environment_id, selection: selection()}
      },
      access_revision: 1
    }
  end

  defp selection do
    %EnvironmentSelection{
      base_nixpkgs: SourceSelector.nixpkgs(),
      layers: [],
      project_context: nil
    }
  end

  defp repository(url) do
    {:ok, repository} = RepositorySource.parse(url)
    repository
  end

  defp id(module) do
    {:ok, id} = module.parse(Ecto.UUID.generate())
    id
  end

  defp eventually(function, attempts \\ 3_000)
  defp eventually(_function, 0), do: false

  defp eventually(function, attempts) do
    if function.() do
      true
    else
      receive do
      after
        100 -> eventually(function, attempts - 1)
      end
    end
  end

  defp eventually_value(function, attempts \\ 3_000)
  defp eventually_value(_function, 0), do: nil

  defp eventually_value(function, attempts) do
    case function.() do
      nil ->
        receive do
        after
          100 -> eventually_value(function, attempts - 1)
        end

      value ->
        value
    end
  end
end

database = System.fetch_env!("BIOT_STEP9_TEST_DATABASE")
repo_options = Application.fetch_env!(:biot_server, Biot.Server.Repo)

Application.put_env(
  :biot_server,
  Biot.Server.Repo,
  repo_options
  |> Keyword.put(:database, database)
  |> Keyword.put(:ownership_timeout, 900_000)
)

{:ok, _applications} = Application.ensure_all_started(:ecto_sqlite3)
migrations = Application.app_dir(:biot_server, "priv/repo/migrations")

{:ok, _result, _applications} =
  Ecto.Migrator.with_repo(Biot.Server.Repo, fn repo ->
    Ecto.Migrator.run(repo, migrations, :up, all: true, log: false)
  end)

{:ok, _applications} = Application.ensure_all_started(:biot_server)
Code.require_file(Path.join(__DIR__, "step9_full_proof.exs"))
Application.stop(:biot_node)
Code.require_file(Path.join(__DIR__, "step14_controller_proof.exs"))
