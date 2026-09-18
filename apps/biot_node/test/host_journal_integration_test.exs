defmodule Biot.Node.HostJournalIntegrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Biot.Node.ReconcileFixtures

  alias Biot.Node.Allocation
  alias Biot.Node.Host
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Context
  alias Biot.Node.Journal
  alias Biot.Node.Journal.Migrator
  alias Biot.Node.Journal.Schema.Allocation, as: AllocationRow
  alias Biot.Node.Journal.Schema.Diagnostic, as: DiagnosticRow
  alias Biot.Node.Journal.Schema.LocalIntent, as: LocalIntentRow
  alias Biot.Node.Journal.Schema.RetryState, as: RetryStateRow
  alias Biot.Node.NetworkId
  alias Biot.Node.NodePrivatePath
  alias Biot.Node.Repo
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.Failure
  alias Biot.Protocol.Platform

  setup_all do
    data_root = temporary_directory("biot-node-journal")
    previous = Application.get_env(:biot_node, :data_root)
    Application.put_env(:biot_node, :data_root, data_root)

    start_supervised!(Repo)
    Migrator.migrate(log: false)

    on_exit(fn ->
      File.rm_rf!(data_root)

      if previous,
        do: Application.put_env(:biot_node, :data_root, previous),
        else: Application.delete_env(:biot_node, :data_root)
    end)

    {:ok, data_root: data_root}
  end

  setup do
    Repo.delete_all(Biot.Node.Journal.Schema.Installation)
    Repo.delete_all(Biot.Node.Journal.Schema.Resolution)
    Repo.delete_all(AllocationRow)
    Repo.delete_all(DiagnosticRow)
    Repo.delete_all(RetryStateRow)
    Repo.delete_all(LocalIntentRow)
    :ok
  end

  describe "retry journal" do
    test "retry writes use the stored desired revision" do
      biot = biot_spec(1)
      failure = failure()
      wake = DateTime.add(DateTime.utc_now(), 30, :second)

      assert Journal.retry_state(biot_id()) == nil
      assert Journal.record_attempt(biot_id(), 1, :prepare) == :superseded
      assert Journal.record_failure(biot_id(), 1, failure, wake) == :superseded
      assert Journal.clear_failure(biot_id(), 1) == :superseded

      assert {:ok, _intent} = Journal.put_intent(biot)
      assert Journal.record_attempt(biot_id(), 2, :prepare) == :superseded

      assert {:ok, attempted} = Journal.record_attempt(biot_id(), 1, :prepare)
      assert attempted.target_revision == 1
      assert attempted.attempts == %{prepare: 1}

      assert {:ok, failed} = Journal.record_failure(biot_id(), 1, failure, wake)
      assert failed.failure == failure
      assert failed.next_attempt_at == wake

      assert {:ok, cleared} = Journal.clear_failure(biot_id(), 1)
      assert cleared.attempts == %{prepare: 1}
      assert cleared.failure == nil
      assert cleared.next_attempt_at == nil
      assert Journal.retry_state(biot_id()) == cleared
    end

    test "put_intent keeps retry state for the same revision and drops it for a new revision" do
      assert {:ok, _intent} = Journal.put_intent(biot_spec(1))
      assert {:ok, retry} = Journal.record_attempt(biot_id(), 1, :resolve)
      assert {:ok, _intent} = Journal.put_intent(biot_spec(1))
      assert Journal.retry_state(biot_id()) == retry

      assert {:ok, _intent} = Journal.put_intent(biot_spec(2))
      assert Journal.retry_state(biot_id()) == nil
      assert Journal.intent(biot_id()).biot_spec.execution.desired.revision == 2
    end

    test "replace_intents deletes omitted intent and retry rows together" do
      assert {:ok, _intent} = Journal.put_intent(biot_spec(1))
      assert {:ok, _retry} = Journal.record_attempt(biot_id(), 1, :resolve)

      assert Journal.replace_intents([]) == {:ok, [biot_id()]}
      assert Journal.intent(biot_id()) == nil
      assert Journal.retry_state(biot_id()) == nil
    end

    test "put_destruction_report keeps the intent and deletes retry state" do
      report = destruction_report(1)
      assert {:ok, _intent} = Journal.put_intent(biot_spec(1))
      assert {:ok, _retry} = Journal.record_attempt(biot_id(), 1, :remove_data)

      assert {:ok, intent} = Journal.put_destruction_report(biot_id(), report)
      assert intent.destruction_report == report
      assert Journal.intent(biot_id()) == intent
      assert Journal.retry_state(biot_id()) == nil
    end

    test "put_intent keeps a stored destruction report" do
      report = destruction_report(1)
      assert {:ok, _intent} = Journal.put_intent(biot_spec(1))
      assert {:ok, _intent} = Journal.put_destruction_report(biot_id(), report)

      assert {:ok, intent} = Journal.put_intent(biot_spec(2))
      assert intent.biot_spec == biot_spec(2)
      assert intent.destruction_report == report
    end
  end

  describe "diagnostic journal" do
    test "same-key writes replace the row and return the replaced ID" do
      first = id(Biot.Protocol.PrivateDiagnosticId, 101)
      second = id(Biot.Protocol.PrivateDiagnosticId, 102)

      assert Journal.index_diagnostic(first, biot_id(), 1, :prepare, false, 5) == {:ok, []}
      assert Journal.index_diagnostic(second, biot_id(), 1, :prepare, true, 5) == {:ok, [first]}
      assert Journal.diagnostic_truncated(first) == :not_found
      assert Journal.diagnostic_truncated(second) == {:ok, true}
    end

    test "retention keeps the newest sequences across revisions" do
      ids = Enum.map(201..204, &id(Biot.Protocol.PrivateDiagnosticId, &1))

      assert Journal.index_diagnostic(Enum.at(ids, 0), biot_id(), 1, :resolve, false, 3) ==
               {:ok, []}

      assert Journal.index_diagnostic(Enum.at(ids, 1), biot_id(), 2, :prepare, false, 3) ==
               {:ok, []}

      assert Journal.index_diagnostic(Enum.at(ids, 2), biot_id(), 3, :install, false, 3) ==
               {:ok, []}

      assert Journal.index_diagnostic(Enum.at(ids, 3), biot_id(), 4, :start, false, 3) ==
               {:ok, [hd(ids)]}

      rows = Repo.all(from(row in DiagnosticRow, order_by: row.sequence))
      assert Enum.map(rows, & &1.diagnostic_id) == tl(ids)
      assert Enum.map(rows, & &1.sequence) == [2, 3, 4]
    end

    test "forget returns every indexed ID" do
      ids = Enum.map(301..303, &id(Biot.Protocol.PrivateDiagnosticId, &1))

      for {diagnostic_id, revision} <- Enum.zip(ids, 1..3) do
        assert Journal.index_diagnostic(diagnostic_id, biot_id(), revision, :start, false, 5) ==
                 {:ok, []}
      end

      assert {:ok, removed} = Journal.forget_diagnostics(biot_id())
      assert MapSet.new(removed) == MapSet.new(ids)
      assert Repo.all(DiagnosticRow) == []
    end

    test "replace_intents returns every omitted Biot ID" do
      other = id(BiotId, 402)
      assert {:ok, _intent} = Journal.put_intent(biot_spec(1))
      assert {:ok, _intent} = Journal.put_intent(biot_spec(1, other))

      assert {:ok, removed} = Journal.replace_intents([])
      assert MapSet.new(removed) == MapSet.new([biot_id(), other])
    end
  end

  test "the first unused UID range fills a gap before extending the journal", context do
    assert {:ok, _allocation} = Journal.put_allocation(allocation(context.data_root, 1, 100_000))
    assert {:ok, _allocation} = Journal.put_allocation(allocation(context.data_root, 2, 102_048))

    assert Journal.next_uid_start(100_000, 1_024, 103_072) == {:ok, 101_024}
    assert Journal.next_uid_start(100_000, 1_024, 102_048) == {:ok, 101_024}

    assert {:ok, _allocation} = Journal.put_allocation(allocation(context.data_root, 3, 101_024))
    assert Journal.next_uid_start(100_000, 1_024, 103_072) == {:error, :uid_ranges_exhausted}
  end

  test "release_allocation returns a typed error while owned records remain", context do
    allocation = allocation(context.data_root, 1, 100_000)
    assert {:ok, allocation} = Journal.put_allocation(allocation)
    assert {:ok, _resolution} = Journal.put_resolution(allocation.biot_id, e1(), manifest())

    assert Journal.delete_allocation(allocation) == {:error, :records_remain}
    assert Journal.allocation(allocation.biot_id) == allocation
  end

  test "the database restricts direct allocation deletion when a resolution remains", context do
    allocation = allocation(context.data_root, 1, 100_000)
    assert {:ok, _allocation} = Journal.put_allocation(allocation)
    assert {:ok, _resolution} = Journal.put_resolution(allocation.biot_id, e1(), manifest())

    row = Repo.get!(AllocationRow, allocation.biot_id)
    assert_raise Ecto.ConstraintError, fn -> Repo.delete!(row) end
    assert Journal.allocation(allocation.biot_id) == allocation
  end

  test "the database restricts direct allocation deletion when an installation remains",
       context do
    allocation = allocation(context.data_root, 1, 100_000)
    assert {:ok, _allocation} = Journal.put_allocation(allocation)
    assert {:ok, _installation} = Journal.put_installation(allocation, e1(), artifact(e1()))

    row = Repo.get!(AllocationRow, allocation.biot_id)
    assert_raise Ecto.ConstraintError, fn -> Repo.delete!(row) end
    assert Journal.allocation(allocation.biot_id) == allocation
  end

  test "release_environment rejects an environment owned by another biot", context do
    owner = allocation(context.data_root, 1, 100_000)
    caller = allocation(context.data_root, 2, 101_024)
    assert {:ok, _allocation} = Journal.put_allocation(owner)
    assert {:ok, _allocation} = Journal.put_allocation(caller)
    assert {:ok, _resolution} = Journal.put_resolution(owner.biot_id, e1(), manifest())

    action = {:release_environment, e1(), caller}
    host_context = %Context{biot_id: caller.biot_id, config: config(context.data_root)}

    assert {:error, %Biot.Node.Host.Outcome{outcome: :ownership_mismatch}} =
             Host.run(action, host_context)

    assert Journal.resolution(owner.biot_id, e1())
  end

  defp allocation(data_root, number, uid_start) do
    biot_id = id(BiotId, number)
    {:ok, private_path} = NodePrivatePath.parse(Path.join(data_root, "biot-#{number}"))

    %Allocation{
      biot_id: biot_id,
      uid_range: %{start: uid_start, count: 1_024},
      data_root: private_path,
      network_id: NetworkId.from_biot_id(biot_id),
      initialization: :uninitialized
    }
  end

  defp biot_spec(revision) do
    %BiotSpec{execution: spec(revision: revision), access_revision: revision}
  end

  defp destruction_report(revision) do
    %ExecutionReport{
      accepted_revision: revision,
      installed_environment_id: nil,
      container: :absent,
      data: :no_allocation,
      failure: nil,
      waiting_for: nil
    }
  end

  defp failure do
    %Failure{
      stage: :prepare,
      code: :preparation_failed,
      retry: :automatic,
      message: "the environment could not be built",
      diagnostic_ref: nil
    }
  end

  defp config(data_root) do
    {:ok, platform} = Platform.parse("x86_64-linux")
    project_root = Path.expand("../../..", __DIR__)

    struct!(Config,
      data_root: data_root,
      fetch_ca_bundle: nil,
      uid_range_base: 100_000,
      uid_range_count: 1_024,
      uid_range_limit: 165_536,
      git_executable: "git",
      podman_executable: "podman",
      setsid_executable: "setsid",
      mkfifo_executable: "mkfifo",
      head_executable: "head",
      cat_executable: "cat",
      sleep_executable: "sleep",
      podman_network_command: "slirp4netns",
      builder_image: "example.test/nix@sha256:#{String.duplicate("a", 64)}",
      build_support_dir: project_root,
      binary_cache_urls: ["https://cache.example.test"],
      binary_cache_keys: ["cache.example.test:key"],
      nixpkgs_repository: "https://github.com/NixOS/nixpkgs",
      nixpkgs_ref: "nixos-unstable",
      command_timeout_ms: 120_000,
      worker_timeout_ms: 120_000,
      command_max_output_bytes: 64_000,
      command_max_stderr_bytes: 64_000,
      runtime_log_max_bytes: 64_000,
      platform: platform
    )
  end

  defp biot_spec(revision, biot_id) do
    execution = %{spec(revision: revision) | biot_id: biot_id}
    %BiotSpec{execution: execution, access_revision: revision}
  end

  defp id(module, number) do
    value =
      "00000000-0000-4000-8000-#{number |> Integer.to_string() |> String.pad_leading(12, "0")}"

    {:ok, parsed} = module.parse(value)
    parsed
  end

  defp temporary_directory(prefix) do
    path = BiotTest.Temp.directory(prefix)
    File.mkdir_p!(path)
    path
  end
end
