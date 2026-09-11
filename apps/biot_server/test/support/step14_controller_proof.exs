# This proof prints structured evidence for the outer ExUnit assertions.
# credo:disable-for-this-file Credo.Check.Warning.IoInspect
defmodule Biot.Step14Evidence do
  @moduledoc false

  alias Biot.Node.Action
  alias Biot.Node.ArtifactId
  alias Biot.Node.BiotController
  alias Biot.Node.Control.Connection, as: NodeConnection
  alias Biot.Node.Control.Outbox
  alias Biot.Node.Controllers
  alias Biot.Node.Diagnostics
  alias Biot.Node.Host
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Command.Reaper
  alias Biot.Node.Host.Container
  alias Biot.Node.Host.ContainerEvents
  alias Biot.Node.Host.Environment, as: HostEnvironment
  alias Biot.Node.Host.Names
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.Podman
  alias Biot.Node.Installation
  alias Biot.Node.Journal
  alias Biot.Node.Journal.Schema.Allocation, as: AllocationRow
  alias Biot.Node.Journal.Schema.Diagnostic, as: DiagnosticRow
  alias Biot.Node.Observation
  alias Biot.Node.Reconcile
  alias Biot.Node.Repo, as: NodeRepo
  alias Biot.Node.RetryState
  alias Biot.Node.RuntimeLogs
  alias Biot.Node.StorePath
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.Certificates
  alias Biot.Protocol.ConnectionId
  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.ExecutionSpec
  alias Biot.Protocol.Failure
  alias Biot.Protocol.Frame
  alias Biot.Protocol.Message
  alias Biot.Protocol.Platform
  alias Biot.Protocol.RegistrationId
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector
  alias Biot.Protocol.Wire

  @project_root File.cwd!()
  @work Path.join(
          System.tmp_dir!(),
          "biot-step14-controller-proof-#{System.unique_integer([:positive])}"
        )
  @data_root Path.join(@work, "data")
  @repositories Path.join(@work, "git")
  @certificates Path.join(@work, "certificates")
  @database Path.join(@data_root, "journal.sqlite3")

  @observation_interval_ms 600_000
  @short_interval_ms 4_000
  @events_retry_ms 1_000
  @backoff_min_ms 5_000
  @backoff_max_ms 8_000
  @timeout 5_000
  @lifecycle_timeout_ms 600_000

  def run do
    Process.flag(:trap_exit, true)
    cleanup()
    configure()
    start_dependencies()
    fixtures = build_fixtures()
    supervisor = start_node_components()

    try do
      source_checks()
      first = lifecycle_check(fixtures)
      runtime_log_check(supervisor)
      event_check(first)
      second = second_biot_check(fixtures)
      isolation_check(first, second)
      event_reader_check(second)
      prepared_check(first)
      marker_check(first)
      retry_check()
      superseded_effect_check(fixtures)
      revision_reset_check()
      commit_before_notice_check(fixtures)
      superseded_attempt_check()
      refused_diagnostic_check(fixtures)
      destruction_check()
      replay_check()
      reader_ownership_check(supervisor)
      IO.puts("step 14 controller proof passed")
    after
      Supervisor.stop(supervisor)
      if Port.info(fixtures.server), do: Port.close(fixtures.server)
      cleanup()
    end
  end

  # Goal 1 and goal 8: the pure core names no control link, and no action declares environments.
  defp source_checks do
    core =
      Path.wildcard("apps/biot_node/lib/biot/node/reconcile/*.ex") ++
        [
          "apps/biot_node/lib/biot/node/reconcile.ex",
          "apps/biot_node/lib/biot/node/action.ex",
          "apps/biot_node/lib/biot/node/block_reason.ex",
          "apps/biot_node/lib/biot/node/node_state.ex"
        ]

    controller = "apps/biot_node/lib/biot/node/biot_controller.ex"

    IO.inspect(
      %{
        core_files: length(core),
        core_words: word_counts(core, ["control", "offline", "requires_control", "controller"]),
        controller_words:
          word_counts([controller], ["offline", "requires_control", "Control.status"]),
        controller_control_uses: uses(controller, ~r/Control\.[a-z_]+/),
        action_environments_exported: function_exported?(Action, :environments, 1),
        action_requires_control_exported: function_exported?(Action, :requires_control?, 1),
        marker_id_module_loadable: Code.ensure_loaded?(Biot.Node.MarkerId),
        blocking_invariant: invariant_comment(),
        controller_restart: BiotController.child_spec(biot_id: id(BiotId, 1)).restart
      },
      label: "1+8 pure core",
      limit: :infinity,
      printable_limit: :infinity
    )
  end

  defp word_counts(files, words) do
    text = Enum.map_join(files, "\n", &File.read!/1)

    Map.new(words, fn word ->
      {word, length(Regex.scan(~r/\b#{Regex.escape(word)}\b/, text))}
    end)
  end

  defp uses(file, pattern) do
    file |> File.read!() |> then(&Regex.scan(pattern, &1)) |> List.flatten() |> Enum.uniq()
  end

  defp invariant_comment do
    "apps/biot_node/lib/biot/node/reconcile.ex"
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "in flight"))
    |> Enum.map(&String.trim/1)
  end

  # Goal 1: a node with no control link runs the whole create sequence from durable intent.
  defp lifecycle_check(fixtures) do
    biot_id = id(BiotId, 801)
    environment_id = id(EnvironmentId, 802)
    spec = spec(biot_id, environment_id, fixtures.checkout, fixtures.selection, :running, 1)
    {:ok, host} = Host.context(biot_id)
    {:ok, _intent} = Journal.put_intent(spec)

    actions =
      trace(Host, :run, 2, fn ->
        :ok = Controllers.intent_changed(biot_id)

        eventually(
          fn -> match?({:present, _container}, Host.inspect_state(biot_id, host).container) end,
          @lifecycle_timeout_ms
        )
      end)

    state = Host.inspect_state(biot_id, host)
    {:present, container} = state.container
    [{^biot_id, controller}] = running_controllers(biot_id)

    IO.inspect(
      %{
        control_connection_process: Process.whereis(NodeConnection),
        durable_intent_revision: Journal.intent(biot_id).biot_spec.execution.desired.revision,
        actions_run: actions,
        data: elem(state.data, 0),
        installation: elem(state.installation, 0),
        container: {elem(state.container, 0), container.state},
        prepared: Map.values(state.prepared) |> Enum.map(&elem(&1, 0)),
        reported_to_outbox: outbox_report(biot_id) != nil,
        controller_alive: Process.alive?(controller)
      },
      label: "1 create sequence without a control link"
    )

    %{biot_id: biot_id, environment_id: environment_id, host: host, spec: spec}
  end

  # The proof keeps one resource lifecycle so each assertion observes the same container.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp runtime_log_check(supervisor) do
    biot_id = id(BiotId, 895)
    environment_id = id(EnvironmentId, 896)
    {:ok, host} = Host.context(biot_id)
    :ok = Host.run({:allocate, biot_id}, host)

    Enum.each(Paths.runtime_mounts(host.config, biot_id), fn {source, _target, _mode} ->
      File.mkdir_p!(source)
    end)

    allocation = Journal.allocation(biot_id)
    first_runner = runtime_runner("first")
    write_runtime_bundle(host.config, biot_id, environment_id, first_runner)
    {:ok, first_artifact} = ArtifactId.parse(first_runner.closure_root)

    installation = %Installation{
      biot_id: biot_id,
      environment_id: environment_id,
      artifact_id: first_artifact
    }

    :ok = Container.start(host, allocation, installation)
    {:present, first_container} = running_container(host, biot_id)
    :ok = RuntimeLogs.attach(host.config, biot_id, {:present, first_container})

    eventually(fn ->
      case RuntimeLogs.fetch(biot_id, 10_000) do
        {:ok, {id, content, false}} ->
          id == first_container.incarnation_id and String.contains?(content, "first-service")

        _other ->
          false
      end
    end)

    before_restart = RuntimeLogs.fetch(biot_id, 10_000)
    :ok = Supervisor.terminate_child(supervisor, RuntimeLogs)
    {:ok, _runtime_logs} = Supervisor.restart_child(supervisor, RuntimeLogs)
    :ok = RuntimeLogs.attach(host.config, biot_id, {:present, first_container})

    eventually(fn ->
      match?(
        {:ok, {_, content, true}} when byte_size(content) > 0,
        RuntimeLogs.fetch(biot_id, 10_000)
      )
    end)

    eventually(fn -> runtime_log_size(host.config, biot_id) == 4_096 end, 30_000)
    first_size = runtime_log_size(host.config, biot_id)
    Process.sleep(300)
    first_later_size = runtime_log_size(host.config, biot_id)
    first_after_restart = RuntimeLogs.fetch(biot_id, 10_000)

    :ok = Container.retire(host, first_container.incarnation_id)
    after_retire = RuntimeLogs.fetch(biot_id, 10_000)
    metadata_before_failure = File.read!(Paths.runtime_log_metadata(host.config, biot_id))

    bundle_path =
      Path.join(Paths.environment_root(host.config, biot_id, environment_id), "bundle.json")

    valid_bundle = File.read!(bundle_path)
    invalid_rootfs = "/nix/store/00000000000000000000000000000000-missing-rootfs"
    invalid_bundle = valid_bundle |> Jason.decode!() |> Map.put("rootfs", invalid_rootfs)
    File.write!(bundle_path, Jason.encode!(invalid_bundle))

    failed_start =
      try do
        Container.start(host, allocation, installation)
      after
        File.write!(bundle_path, valid_bundle)
      end

    after_failed_start = RuntimeLogs.fetch(biot_id, 10_000)
    metadata_after_failure = File.read!(Paths.runtime_log_metadata(host.config, biot_id))

    second_runner = runtime_runner("second")
    write_runtime_bundle(host.config, biot_id, environment_id, second_runner)
    {:ok, second_artifact} = ArtifactId.parse(second_runner.closure_root)
    second_installation = %{installation | artifact_id: second_artifact}
    :ok = Container.start(host, allocation, second_installation)
    {:present, second_container} = running_container(host, biot_id)
    :ok = RuntimeLogs.attach(host.config, biot_id, {:present, second_container})

    eventually(fn ->
      case RuntimeLogs.fetch(biot_id, 10_000) do
        {:ok, {id, content, _truncated}} ->
          id == second_container.incarnation_id and
            String.contains?(content, "second-service") and
            not String.contains?(content, "first-service")

        _other ->
          false
      end
    end)

    second_read = RuntimeLogs.fetch(biot_id, 10_000)

    IO.inspect(
      %{
        before_restart_exact: match?({:ok, {_, _, false}}, before_restart),
        restart_kept_incarnation:
          log_incarnation(first_after_restart) == first_container.incarnation_id,
        restart_marked_gap: match?({:ok, {_, _, true}}, first_after_restart),
        capture_stayed_bounded: first_size == 4_096 and first_later_size == 4_096,
        failed_start_failed: match?({:error, _outcome}, failed_start),
        failed_start_kept_log: after_failed_start == after_retire,
        failed_start_kept_metadata: metadata_after_failure == metadata_before_failure,
        new_incarnation: second_container.incarnation_id != first_container.incarnation_id,
        new_log_replaced_old:
          log_contains?(second_read, "second-service") and
            not log_contains?(second_read, "first-service")
      },
      label: "step 15 runtime logs"
    )

    :ok = Container.retire(host, second_container.incarnation_id)
    :ok = RuntimeLogs.forget(biot_id)
  end

  defp runtime_runner(label) do
    expression = """
    let pkgs = import <nixpkgs> {};
        runner = pkgs.writeShellScript "biot-step15-#{label}" ''
          i=0
          while [ "$i" -lt 400 ]; do
            printf '#{label}-service-%04d-abcdefghijklmnopqrstuvwxyz0123456789\\n' "$i"
            i=$((i + 1))
            ${pkgs.coreutils}/bin/sleep 0.02
          done
          exec ${pkgs.coreutils}/bin/sleep 300
        '';
        rootfs = pkgs.runCommandLocal "biot-step15-rootfs-#{label}" {} ''
          mkdir -p "$out"/{etc,biot/{checkout,home,service-data,run,secrets},nix/store,tmp,run,dev,proc,sys}
          touch "$out/etc/hosts" "$out/etc/hostname" "$out/etc/resolv.conf"
        '';
    in [ rootfs runner ]
    """

    case System.cmd("nix-build", ["--no-out-link", "--expr", expression], stderr_to_stdout: true) do
      {output, 0} ->
        paths =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.starts_with?(&1, "/nix/store/"))

        rootfs = Enum.find(paths, &String.ends_with?(&1, "-biot-step15-rootfs-#{label}"))
        runner = Enum.find(paths, &String.ends_with?(&1, "-biot-step15-#{label}"))
        true = is_binary(rootfs) and is_binary(runner)
        %{closure_root: rootfs, rootfs: rootfs, entrypoint: runner}

      {output, status} ->
        raise "nix-build exited with #{status}: #{output}"
    end
  end

  defp write_runtime_bundle(config, biot_id, environment_id, runner) do
    root = Paths.environment_root(config, biot_id, environment_id)
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "bundle.json"),
      Jason.encode!(%{
        "format" => 1,
        "closure_root" => runner.closure_root,
        "rootfs" => runner.rootfs,
        "entrypoint" => runner.entrypoint,
        "shell_entrypoint" => runner.entrypoint,
        "environment_file" => runner.entrypoint,
        "config_root" => runner.closure_root
      })
    )
  end

  defp running_container(host, biot_id) do
    case Host.inspect_state(biot_id, host).container do
      {:present, %{state: :running} = container} -> {:present, container}
      _other -> nil
    end
  end

  defp runtime_log_size(config, biot_id) do
    File.stat!(Paths.runtime_log(config, biot_id)).size
  end

  defp log_incarnation({:ok, {incarnation_id, _content, _truncated}}), do: incarnation_id
  defp log_incarnation(_other), do: nil

  defp log_contains?({:ok, {_incarnation_id, content, _truncated}}, value),
    do: String.contains?(content, value)

  defp log_contains?(_other, _value), do: false

  # Goal 6: a podman kill reaches the controller long before its observation interval.
  defp event_check(biot) do
    {:present, container} = Host.inspect_state(biot.biot_id, biot.host).container
    name = Names.container(container.incarnation_id)
    started = System.monotonic_time(:millisecond)

    inspections =
      trace(Host, :inspect_state, 2, fn ->
        {:ok, %Command.Result{status: 0}} = Podman.run(biot.host.config, ["kill", name])

        eventually(fn -> Journal.retry_state(biot.biot_id) != nil end, 30_000)
      end)

    elapsed = System.monotonic_time(:millisecond) - started
    eventually(fn -> Journal.retry_state(biot.biot_id).failure != nil end, 60_000)
    retry = Journal.retry_state(biot.biot_id)

    IO.inspect(
      %{
        observation_interval_ms: @observation_interval_ms,
        event_reader: Process.whereis(ContainerEvents) != nil,
        killed_container: name,
        controller_inspections_after_kill: length(inspections),
        wake_delay_ms: elapsed,
        recorded_failure_code: retry.failure.code,
        recorded_attempts: retry.attempts
      },
      label: "6 podman event wakes the controller"
    )

    # The exited container leaves the controller retrying on its own schedule; the rest of the run
    # reads host resources directly, so the controller is stopped for good here.
    stop_controller(biot.biot_id)
  end

  # Goal 7: two allocations get networks that cannot route to each other.
  defp second_biot_check(fixtures) do
    biot_id = id(BiotId, 811)
    environment_id = id(EnvironmentId, 812)
    spec = spec(biot_id, environment_id, fixtures.checkout, fixtures.selection, :running, 1)
    {:ok, host} = Host.context(biot_id)
    {:ok, _intent} = Journal.put_intent(spec)
    :ok = Controllers.intent_changed(biot_id)

    eventually(
      fn -> match?({:present, _container}, Host.inspect_state(biot_id, host).container) end,
      @lifecycle_timeout_ms
    )

    stop_controller(biot_id)
    %{biot_id: biot_id, environment_id: environment_id, host: host, spec: spec}
  end

  defp isolation_check(first, second) do
    restart_container(first)
    restart_container(second)
    first = with_container(first)
    second = with_container(second)
    curl = curl_executable(first)

    eventually(fn -> reachable?(first, curl, "127.0.0.1") end, 60_000)
    eventually(fn -> reachable?(second, curl, "127.0.0.1") end, 60_000)

    IO.inspect(
      %{
        create_arguments: network_create_arguments(),
        first_network_options: network_options(first),
        second_network_options: network_options(second),
        first_address: first.address,
        second_address: second.address,
        first_reaches_itself: reachable?(first, curl, "127.0.0.1"),
        second_reaches_itself: reachable?(second, curl, "127.0.0.1"),
        first_reaches_second: reachable?(first, curl, second.address),
        second_reaches_first: reachable?(second, curl, first.address)
      },
      label: "7 network isolation"
    )
  end

  defp with_container(biot) do
    state = Host.inspect_state(biot.biot_id, biot.host)
    {:present, container} = state.container
    name = Names.container(container.incarnation_id)
    Map.merge(biot, %{container: container, name: name, address: address(biot, name)})
  end

  # The event check killed one container, so the run starts it again from the same installation.
  defp restart_container(biot) do
    state = Host.inspect_state(biot.biot_id, biot.host)
    ensure_running(biot, state, state.container)
  end

  defp ensure_running(_biot, _state, {:present, %{state: :running}}), do: :ok

  defp ensure_running(biot, state, {:present, container}) do
    :ok = Host.run({:retire, container.incarnation_id}, biot.host)
    start_container(biot, state)
  end

  defp ensure_running(biot, state, :absent), do: start_container(biot, state)

  defp start_container(biot, state) do
    {:present, installation} = state.installation
    :ok = Host.run({:start, Journal.allocation(biot.biot_id), installation}, biot.host)
  end

  defp address(biot, name) do
    {:ok, %Command.Result{status: 0, stdout: output}} =
      Podman.run(biot.host.config, [
        "inspect",
        "--format",
        "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
        name
      ])

    String.trim(output)
  end

  defp network_options(biot) do
    allocation = Journal.allocation(biot.biot_id)

    result =
      Podman.run(biot.host.config, [
        "network",
        "inspect",
        "--format",
        "{{.Options}}",
        Names.network(allocation.network_id)
      ])

    case result do
      {:ok, %Command.Result{status: 0, stdout: output}} -> String.trim(output)
      other -> inspect(other)
    end
  end

  defp network_create_arguments do
    "apps/biot_node/lib/biot/node/host/network.ex"
    |> File.read!()
    |> then(&Regex.run(~r/arguments = \[(.*?)\]/s, &1))
    |> List.last()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp reachable?(biot, curl, address) do
    arguments =
      [
        "exec",
        biot.name,
        curl,
        "--fail",
        "--silent",
        "--show-error",
        "--max-time",
        "2",
        "http://#{address}:8080/"
      ]

    match?({:ok, %Command.Result{status: 0}}, Podman.run(biot.host.config, arguments))
  end

  defp curl_executable(biot) do
    {:ok, bundle} =
      HostEnvironment.bundle(biot.host.config, biot.biot_id, biot.environment_id)

    environment = bundle.environment_file |> StorePath.to_string() |> File.read!()
    [path] = Regex.run(~r{/nix/store/[^\s:'"]*curl[^\s:'"]*/bin}, environment)
    Path.join(path, "curl")
  end

  # Fix 3: an unavailable Podman leaves the event reader waiting, and the node keeps working.
  defp event_reader_check(biot) do
    controllers = Process.whereis(Controllers)
    {:present, container} = Host.inspect_state(biot.biot_id, biot.host).container
    name = Names.container(container.incarnation_id)
    settle_controller(biot.biot_id, @short_interval_ms)
    previous_reader = Process.whereis(ContainerEvents)
    previous_podman = Application.fetch_env!(:biot_node, :podman_executable)
    Application.put_env(:biot_node, :podman_executable, script("exiting-podman", "exit 1\n"))

    # The reader opens the stream once when it starts, so the run kills it to make it open the
    # stream again while Podman is unavailable. Every open after that one is its own.
    Process.exit(previous_reader, :kill)
    eventually(fn -> reopening?(previous_reader) end, 30_000)
    reader = Process.whereis(ContainerEvents)

    samples =
      for _sample <- 1..3 do
        Process.sleep(@events_retry_ms)
        {Process.whereis(ContainerEvents) == reader, reader_stream()}
      end

    inspections = trace(Host, :inspect_state, 2, fn -> Process.sleep(2 * @short_interval_ms) end)

    Application.put_env(:biot_node, :podman_executable, previous_podman)
    eventually(fn -> reader_stream() != nil end, 10 * @events_retry_ms)
    restored_stream = reader_stream()

    # A long observation interval leaves the Podman event the only thing that can wake the
    # controller before the run gives up.
    settle_controller(biot.biot_id, @observation_interval_ms)
    started = System.monotonic_time(:millisecond)
    {:ok, %Command.Result{status: 0}} = Podman.run(biot.host.config, ["kill", name])

    eventually(
      fn -> match?(%RetryState{failure: %Failure{}}, Journal.retry_state(biot.biot_id)) end,
      60_000
    )

    elapsed = System.monotonic_time(:millisecond) - started

    IO.inspect(
      %{
        container_events_retry_ms: @events_retry_ms,
        reader_restarted_by_supervisor: reader != previous_reader,
        reader_kept_its_pid_across_failed_opens:
          Enum.all?(samples, fn {same_reader, _stream} -> same_reader end),
        reader_streams_while_podman_fails: Enum.map(samples, fn {_same, stream} -> stream end),
        controller_tree_unchanged: Process.whereis(Controllers) == controllers,
        controller_inspections_while_podman_fails: length(inspections),
        short_observation_interval_ms: @short_interval_ms,
        reader_stream_after_podman_restored: restored_stream != nil,
        observation_interval_ms: @observation_interval_ms,
        killed_container: name,
        wake_delay_ms: elapsed,
        recorded_failure_code: Journal.retry_state(biot.biot_id).failure.code
      },
      label: "fix 3 the event reader waits for podman"
    )

    stop_controller(biot.biot_id)
  end

  # A controller reads its intervals when it starts, so this is how the run gives one biot a
  # different observation interval from the rest.
  defp settle_controller(biot_id, interval_ms) do
    stop_controller(biot_id)
    Application.put_env(:biot_node, :observation_interval_ms, interval_ms)
    :ok = Controllers.intent_changed(biot_id)
    eventually(fn -> match?({:settled, _wake}, phase(biot_id)) end, 120_000)
    Application.put_env(:biot_node, :observation_interval_ms, @observation_interval_ms)
  end

  defp reopening?(previous_reader) do
    case Process.whereis(ContainerEvents) do
      nil -> false
      reader -> reader != previous_reader and :sys.get_state(reader).stream == nil
    end
  end

  defp reader_stream do
    case Process.whereis(ContainerEvents) do
      nil -> nil
      reader -> :sys.get_state(reader).stream
    end
  end

  defp reaper_records, do: Reaper |> :sys.get_state() |> map_size()

  defp stderr_files do
    command_files() |> MapSet.size()
  end

  defp command_files do
    System.tmp_dir!() |> Path.join("biot-command-*") |> Path.wildcard() |> MapSet.new()
  end

  defp mailbox(process) do
    {:message_queue_len, length} = Process.info(process, :message_queue_len)
    length
  end

  defp script(name, body) do
    path = Path.join(@work, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  # Goal 2: one unreadable environment root leaves only its own environment unknown.
  defp prepared_check(biot) do
    sibling = id(EnvironmentId, 803)
    allocation = Journal.allocation(biot.biot_id)
    selection = biot.spec.execution.environment.selection
    :ok = Host.run({:resolve, sibling, selection, allocation}, biot.host)
    directory = Paths.environment(biot.host.config, sibling)
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o000)

    state = Host.inspect_state(biot.biot_id, biot.host)
    node_state = node_state(state, biot.spec)
    decision = Reconcile.next(biot.spec.execution, node_state, nil)

    File.chmod!(directory, 0o700)

    IO.inspect(
      %{
        prepared:
          Enum.map(state.prepared, fn {key, value} -> {label(key, biot), shape(value)} end),
        installation: elem(state.installation, 0),
        installed_environment: label(installed_environment(state), biot),
        decision_with_unreadable_sibling: describe(decision),
        report_installed_environment:
          label(Observation.report(biot.spec, node_state).installed_environment_id, biot)
      },
      label: "2 per-environment prepared resources"
    )
  end

  defp installed_environment(%{installation: {:present, installation}}) do
    installation.environment_id
  end

  defp label(nil, _biot), do: nil

  defp label(%EnvironmentId{} = value, biot),
    do: if(value == biot.environment_id, do: :desired, else: :sibling)

  defp shape(tuple) when is_tuple(tuple), do: elem(tuple, 0)
  defp shape(other), do: other

  defp describe({:run, action}), do: {:run, elem(action, 0)}
  defp describe({:blocked, reason}), do: {:blocked, elem(reason, 0)}
  defp describe({:failed, %Failure{} = failure}), do: {:failed, failure.code}
  defp describe(step), do: step

  # Goal 3: the completion marker holds the Biot ID, and another Biot's ID makes the data lost.
  defp marker_check(biot) do
    config = biot.host.config
    marker = Paths.marker(config, biot.biot_id)
    content = File.read!(marker)
    allocation = Journal.allocation(biot.biot_id)
    row = NodeRepo.get(AllocationRow, biot.biot_id)
    before = Host.inspect_state(biot.biot_id, biot.host).data
    File.write!(marker, BiotId.to_string(id(BiotId, 899)) <> "\n")
    after_foreign = Host.inspect_state(biot.biot_id, biot.host).data
    File.write!(marker, content)

    IO.inspect(
      %{
        marker_path: Path.relative_to(marker, @data_root),
        marker_content: content,
        marker_is_biot_id: content == BiotId.to_string(biot.biot_id) <> "\n",
        checkout_staging:
          Path.relative_to(Paths.checkout_staging(config, biot.biot_id), @data_root),
        allocation_initialization: allocation.initialization,
        journal_column: row.initialized,
        data_state: shape(before),
        data_state_payload: elem(before, 1) |> then(&(&1 == allocation)),
        data_state_tuple_size: tuple_size(before),
        data_state_with_foreign_marker: shape(after_foreign),
        marker_id_module_loadable: Code.ensure_loaded?(Biot.Node.MarkerId)
      },
      label: "3 completion marker holds the Biot ID"
    )
  end

  # Goal 4: the attempt count and the backoff wake are durable.
  defp retry_check do
    biot_id = id(BiotId, 820)
    environment_id = id(EnvironmentId, 821)
    spec = spec(biot_id, environment_id, unreachable_repository(), selection(), :running, 1)
    previous_git = Application.fetch_env!(:biot_node, :git_executable)
    Application.put_env(:biot_node, :git_executable, "biot-no-such-git")

    try do
      {:ok, _intent} = Journal.put_intent(spec)
      :ok = Controllers.intent_changed(biot_id)

      eventually(fn -> backing_off?(biot_id) end, 60_000)
      first = Journal.retry_state(biot_id)
      [{^biot_id, controller}] = running_controllers(biot_id)
      Process.exit(controller, :kill)

      eventually(fn ->
        match?([{^biot_id, pid}] when pid != controller, running_controllers(biot_id))
      end)

      eventually(fn -> backing_off?(biot_id) end, 30_000)
      restarted = Journal.retry_state(biot_id)
      restarted_wait = remaining_wait(biot_id)

      stop_controller(biot_id)
      distant = DateTime.add(DateTime.utc_now(), 3_600, :second)

      {:ok, saved} =
        Journal.record_failure(biot_id, 1, restarted.failure, distant)

      :ok = Controllers.intent_changed(biot_id)
      eventually(fn -> backing_off?(biot_id) end, 30_000)
      distant_wait = remaining_wait(biot_id)
      distant_attempts = Journal.retry_state(biot_id).attempts

      stop_controller(biot_id)
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _saved} = Journal.record_failure(biot_id, 1, restarted.failure, past)
      past_started = System.monotonic_time(:millisecond)
      :ok = Controllers.intent_changed(biot_id)

      eventually(
        fn -> Journal.retry_state(biot_id).attempts != distant_attempts end,
        @backoff_min_ms
      )

      past_wait = System.monotonic_time(:millisecond) - past_started
      eventually(fn -> backing_off?(biot_id) end, 30_000)

      # The controller is still backing off, so this exercises the running controller's own rule
      # that a new desired revision drops the durable record it superseded.
      new_revision =
        spec(biot_id, environment_id, unreachable_repository(), selection(), :running, 2)

      {:ok, _intent} = Journal.put_intent(new_revision)
      :ok = Controllers.intent_changed(biot_id)
      eventually(fn -> superseded?(biot_id) end, 60_000)
      superseded = Journal.retry_state(biot_id)
      stop_controller(biot_id)

      IO.inspect(
        %{
          backoff_bounds_ms: {@backoff_min_ms, @backoff_max_ms},
          attempts_before_kill: first.attempts,
          failure_before_kill: {first.failure.stage, first.failure.code, first.failure.retry},
          next_attempt_at_saved: first.next_attempt_at != nil,
          attempts_after_restart: restarted.attempts,
          same_attempts: restarted.attempts == first.attempts,
          same_next_attempt_at: restarted.next_attempt_at == first.next_attempt_at,
          wait_after_restart_ms: restarted_wait,
          wait_within_maximum: restarted_wait <= @backoff_max_ms,
          saved_next_attempt_at_seconds_ahead:
            DateTime.diff(saved.next_attempt_at, DateTime.utc_now()),
          wait_after_distant_wake_ms: distant_wait,
          distant_wait_within_maximum: distant_wait <= @backoff_max_ms,
          attempts_after_distant_wake: distant_attempts,
          past_wake_wait_ms: past_wait,
          past_wake_skipped_backoff: past_wait < @backoff_min_ms,
          revision_after_new_desired: superseded.target_revision,
          attempts_after_new_desired: superseded.attempts
        },
        label: "4 durable retry state"
      )
    after
      Application.put_env(:biot_node, :git_executable, previous_git)
    end
  end

  defp backing_off?(biot_id) do
    match?({:backing_off, _wake}, phase(biot_id))
  end

  # A superseded row is the row the new revision wrote: the old one is gone, so the count restarts.
  defp superseded?(biot_id) do
    case Journal.retry_state(biot_id) do
      %RetryState{target_revision: 2, failure: %Failure{}} -> true
      _other -> false
    end
  end

  defp phase(biot_id) do
    case running_controllers(biot_id) do
      [{^biot_id, controller}] -> :sys.get_state(controller).phase
      [] -> nil
    end
  end

  defp remaining_wait(biot_id) do
    {:backing_off, wake} = phase(biot_id)
    Process.read_timer(wake.timer)
  end

  # Fix 1: a task result for a revision the server replaced records nothing.
  defp superseded_effect_check(fixtures) do
    biot_id = id(BiotId, 850)
    environment_id = id(EnvironmentId, 851)
    first = spec(biot_id, environment_id, fixtures.checkout, fixtures.selection, :running, 1)
    second = spec(biot_id, environment_id, fixtures.checkout, fixtures.selection, :running, 2)
    {:ok, host} = Host.context(biot_id)
    biots = Paths.biots(host.config)
    previous_git = Application.fetch_env!(:biot_node, :git_executable)
    Application.put_env(:biot_node, :git_executable, script("slow-git", "sleep 30\nexit 1\n"))

    try do
      {:ok, _intent} = Journal.put_intent(first)
      :ok = Controllers.intent_changed(biot_id)

      eventually(fn -> running_action(biot_id) == :initialize end, 120_000)
      spent = Journal.retry_state(biot_id)

      {:ok, _intent} = Journal.put_intent(second)
      :ok = Controllers.intent_changed(biot_id)
      eventually(fn -> accepted_revision(biot_id) == 2 end)
      effect_revision = effect(biot_id).revision

      # An unreadable biot directory makes the next inspection unknown, so the controller waits
      # instead of starting the new revision's own work. What it holds then is what the superseded
      # result left behind.
      File.chmod!(biots, 0o000)

      eventually(
        fn -> match?({:waiting, {:inspection, _failure}, _wake}, phase(biot_id)) end,
        120_000
      )

      File.chmod!(biots, 0o700)
      retry = :sys.get_state(controller(biot_id)).retry

      IO.inspect(
        %{
          action_in_flight: :initialize,
          attempts_of_superseded_revision: spent.attempts,
          effect_revision: effect_revision,
          accepted_revision: accepted_revision(biot_id),
          phase_after_superseded_result: elem(phase(biot_id), 0),
          journal_row_after_superseded_result: Journal.retry_state(biot_id),
          controller_target_revision: retry.target_revision,
          controller_attempts: retry.attempts,
          controller_failure: retry.failure,
          controller_alive: Process.alive?(controller(biot_id))
        },
        label: "fix 1 a superseded result records nothing"
      )

      stop_controller(biot_id)
    after
      Application.put_env(:biot_node, :git_executable, previous_git)
      File.chmod!(biots, 0o700)
    end
  end

  defp controller(biot_id) do
    [{^biot_id, controller}] = running_controllers(biot_id)
    controller
  end

  defp effect(biot_id) do
    case phase(biot_id) do
      {:running, effect} -> effect
      _other -> nil
    end
  end

  defp running_action(biot_id) do
    case effect(biot_id) do
      nil -> nil
      effect -> elem(effect.action, 0)
    end
  end

  defp accepted_revision(biot_id) do
    :sys.get_state(controller(biot_id)).spec.execution.desired.revision
  end

  # Fix 2: the journal drops a superseded retry record when it accepts the new revision.
  defp revision_reset_check do
    biot_id = id(BiotId, 860)
    environment_id = id(EnvironmentId, 861)
    first = spec(biot_id, environment_id, unreachable_repository(), selection(), :running, 1)
    second = spec(biot_id, environment_id, unreachable_repository(), selection(), :running, 2)

    {:ok, _intent} = Journal.put_intent(first)
    {:ok, _retry} = Journal.record_attempt(biot_id, 1, :resolve)

    {:ok, _retry} =
      Journal.record_failure(biot_id, 1, evidence_failure(:resolve), DateTime.utc_now())

    {:ok, _intent} = Journal.put_intent(first)
    kept = Journal.retry_state(biot_id)

    {:ok, _intent} = Journal.put_intent(second)

    IO.inspect(
      %{
        controllers_for_biot: length(running_controllers(biot_id)),
        row_after_same_revision: %{
          target_revision: kept.target_revision,
          attempts: kept.attempts,
          failure_stage: kept.failure.stage
        },
        row_after_new_revision: Journal.retry_state(biot_id),
        intent_revision_after_new_revision:
          Journal.intent(biot_id).biot_spec.execution.desired.revision
      },
      label: "fix 2 the journal drops a superseded retry record"
    )
  end

  defp evidence_failure(stage) do
    %Failure{
      stage: stage,
      code: :resource_unavailable,
      retry: :automatic,
      message: "evidence failure",
      diagnostic_ref: nil
    }
  end

  # Fix round 2, finding 1: the journal commits new intent before anything tells the controller, so
  # a task result can reach the controller ahead of the notice. Suspending the controller is how
  # this run fixes that order: the result lands in a mailbox nobody is reading.
  defp commit_before_notice_check(fixtures) do
    biot_id = id(BiotId, 870)
    environment_id = id(EnvironmentId, 871)
    first = spec(biot_id, environment_id, fixtures.checkout, fixtures.selection, :running, 1)
    second = spec(biot_id, environment_id, fixtures.checkout, fixtures.selection, :running, 2)
    {:ok, host} = Host.context(biot_id)
    biots = Paths.biots(host.config)
    previous_git = Application.fetch_env!(:biot_node, :git_executable)
    Application.put_env(:biot_node, :git_executable, script("failing-git", "sleep 5\nexit 1\n"))

    try do
      {:ok, _intent} = Journal.put_intent(first)
      :ok = Controllers.intent_changed(biot_id)

      eventually(fn -> running_action(biot_id) == :initialize end, 120_000)
      controller = controller(biot_id)
      spent = Journal.retry_state(biot_id)

      :sys.suspend(controller)
      {:ok, _intent} = Journal.put_intent(second)
      committed = Journal.retry_state(biot_id)
      eventually(fn -> mailbox(controller) > 0 end, 60_000)

      # An unreadable biot directory makes the next inspection unknown, so the controller waits on
      # the new revision instead of starting its work. What it holds then is what the superseded
      # result left behind.
      File.chmod!(biots, 0o000)
      :ok = Controllers.intent_changed(biot_id)
      :sys.resume(controller)

      eventually(
        fn -> match?({:waiting, {:inspection, _failure}, _wake}, phase(biot_id)) end,
        120_000
      )

      File.chmod!(biots, 0o700)
      retry = :sys.get_state(controller).retry

      IO.inspect(
        %{
          action_in_flight: :initialize,
          attempts_of_superseded_revision: spent.attempts,
          retry_row_when_revision_committed: committed,
          result_reached_the_controller_before_the_notice: true,
          retry_row_after_superseded_result: Journal.retry_state(biot_id),
          diagnostics_for_biot: diagnostic_entries(biot_id),
          controller_target_revision: retry.target_revision,
          controller_attempts: retry.attempts,
          controller_failure: retry.failure,
          controller_alive: Process.alive?(controller)
        },
        label: "fix round 2 finding 1 a result that arrives before the notice records nothing"
      )

      stop_controller(biot_id)
    after
      Application.put_env(:biot_node, :git_executable, previous_git)
      File.chmod!(biots, 0o700)
    end
  end

  # Fix round 2, finding 1: the same order for a backoff wake. The journal refuses the attempt, so
  # the controller starts no action for the revision the server replaced.
  defp superseded_attempt_check do
    biot_id = id(BiotId, 880)
    environment_id = id(EnvironmentId, 881)
    first = spec(biot_id, environment_id, unreachable_repository(), selection(), :running, 1)
    second = spec(biot_id, environment_id, unreachable_repository(), selection(), :running, 2)
    {:ok, host} = Host.context(biot_id)
    biots = Paths.biots(host.config)
    previous_git = Application.fetch_env!(:biot_node, :git_executable)
    Application.put_env(:biot_node, :git_executable, "biot-no-such-git")

    # Only this biot's controller may run host actions while the trace is on.
    Enum.each(Controllers.running(), fn {running_id, _pid} -> stop_controller(running_id) end)

    try do
      {:ok, _intent} = Journal.put_intent(first)
      :ok = Controllers.intent_changed(biot_id)

      eventually(fn -> backing_off?(biot_id) end, 60_000)
      controller = controller(biot_id)
      spent = Journal.retry_state(biot_id)

      :sys.suspend(controller)
      {:ok, _intent} = Journal.put_intent(second)
      eventually(fn -> mailbox(controller) > 0 end, 30_000)

      File.chmod!(biots, 0o000)
      :ok = Controllers.intent_changed(biot_id)

      runs =
        trace(Host, :run, 2, fn ->
          :sys.resume(controller)

          eventually(
            fn -> match?({:waiting, {:inspection, _failure}, _wake}, phase(biot_id)) end,
            120_000
          )
        end)

      File.chmod!(biots, 0o700)
      retry = :sys.get_state(controller).retry

      IO.inspect(
        %{
          attempts_of_superseded_revision: spent.attempts,
          wake_reached_the_controller_before_the_notice: true,
          actions_started_after_the_wake: runs,
          retry_row_after_superseded_wake: Journal.retry_state(biot_id),
          controller_target_revision: retry.target_revision,
          controller_attempts: retry.attempts,
          controller_failure: retry.failure,
          controller_alive: Process.alive?(controller)
        },
        label: "fix round 2 finding 1 a superseded wake starts no action"
      )

      stop_controller(biot_id)
    after
      Application.put_env(:biot_node, :git_executable, previous_git)
      File.chmod!(biots, 0o700)
    end
  end

  # A refused retry write leaves its keyed diagnostic. The controller has not read
  # the new revision yet, so its own check accepts the result and stores the diagnostic. Only the
  # journal transaction sees the new revision, and it refuses the write after that.
  defp refused_diagnostic_check(fixtures) do
    biot_id = id(BiotId, 890)
    environment_id = id(EnvironmentId, 891)
    first = spec(biot_id, environment_id, fixtures.checkout, fixtures.selection, :running, 1)
    second = spec(biot_id, environment_id, fixtures.checkout, fixtures.selection, :running, 2)
    {:ok, host} = Host.context(biot_id)
    biots = Paths.biots(host.config)
    previous_git = Application.fetch_env!(:biot_node, :git_executable)

    Application.put_env(
      :biot_node,
      :git_executable,
      script("loud-git", "sleep 5\necho 'clone refused' >&2\nexit 1\n")
    )

    # Only this biot's controller may store a diagnostic while the trace is on.
    Enum.each(Controllers.running(), fn {running_id, _pid} -> stop_controller(running_id) end)

    try do
      {:ok, _intent} = Journal.put_intent(first)
      :ok = Controllers.intent_changed(biot_id)

      eventually(fn -> running_action(biot_id) == :initialize end, 120_000)
      controller = controller(biot_id)
      entries_before = diagnostic_entries(biot_id)

      # Nothing tells the controller about the new revision, so it still holds revision 1 when it
      # reads the failed task's result. Its own check passes and the journal's check refuses.
      :sys.suspend(controller)
      {:ok, _intent} = Journal.put_intent(second)
      eventually(fn -> mailbox(controller) > 0 end, 60_000)
      held = accepted_revision(biot_id)
      stored = Journal.intent(biot_id).biot_spec.execution.desired.revision

      # An unreadable biot directory makes the next inspection unknown, so the reload that follows
      # the refusal waits instead of starting the new revision's own work.
      File.chmod!(biots, 0o000)

      puts =
        trace(Diagnostics, :put, 4, fn ->
          :sys.resume(controller)

          eventually(
            fn -> match?({:waiting, {:inspection, _failure}, _wake}, phase(biot_id)) end,
            120_000
          )
        end)

      File.chmod!(biots, 0o700)
      retry = :sys.get_state(controller).retry

      IO.inspect(
        %{
          action_in_flight: :initialize,
          controller_revision_when_the_result_arrived: held,
          stored_revision_when_the_result_arrived: stored,
          diagnostic_entries_before: entries_before,
          diagnostics_stored_while_recording: length(puts),
          diagnostic_entries_after: diagnostic_entries(biot_id),
          retry_row_after_refused_write: Journal.retry_state(biot_id),
          controller_target_revision: retry.target_revision,
          controller_failure: retry.failure,
          controller_alive: Process.alive?(controller)
        },
        label: "a refused retry write leaves its diagnostic"
      )

      stop_controller(biot_id)
    after
      Application.put_env(:biot_node, :git_executable, previous_git)
      File.chmod!(biots, 0o700)
    end
  end

  defp diagnostic_entries(biot_id) do
    DiagnosticRow
    |> NodeRepo.all()
    |> Enum.filter(&(&1.biot_id == biot_id))
  end

  # Fix round 2, finding 2: every stream the reader opens is released when it ends, so a reader
  # that outlives its streams keeps no reaper record and no stderr file behind.
  defp reader_ownership_check(supervisor) do
    previous_podman = Application.fetch_env!(:biot_node, :podman_executable)
    Enum.each(Controllers.running(), fn {biot_id, _pid} -> stop_controller(biot_id) end)
    eventually(fn -> reaper_records() <= 1 end, 30_000)
    live_stream = %{reaper_records: reaper_records(), stderr_files: stderr_files()}
    files_before_failed_opens = command_files()

    try do
      Application.put_env(:biot_node, :podman_executable, script("exiting-podman", "exit 1\n"))

      # The reader holds its live stream until that stream ends, so the run kills it once. Every
      # open after that one is the reader's own.
      previous_reader = Process.whereis(ContainerEvents)
      Process.exit(previous_reader, :kill)
      eventually(fn -> reopening?(previous_reader) end, 30_000)
      reader = Process.whereis(ContainerEvents)

      opens = trace(Podman, :open, 2, fn -> Process.sleep(12 * @events_retry_ms) end)
      reader_survived_failed_opens = Process.whereis(ContainerEvents) == reader
      :ok = Supervisor.terminate_child(supervisor, ContainerEvents)

      eventually(
        fn ->
          Process.whereis(ContainerEvents) == nil and reaper_records() == 0
        end,
        30_000
      )

      files_after_failed_opens = command_files()

      after_failed_streams = %{
        reaper_records: reaper_records(),
        stderr_files:
          files_after_failed_opens
          |> MapSet.difference(files_before_failed_opens)
          |> MapSet.size()
      }

      IO.inspect(
        %{
          while_one_stream_is_live: live_stream,
          streams_that_opened_and_ended: length(opens),
          reader_survived_failed_opens: reader_survived_failed_opens,
          after_those_streams_ended: after_failed_streams,
          ended_streams_left_no_files_or_reaper_records:
            after_failed_streams == %{reaper_records: 0, stderr_files: 0}
        },
        label: "fix round 2 finding 2 an ended stream leaves no reaper record and no stderr file"
      )
    after
      Application.put_env(:biot_node, :podman_executable, previous_podman)
    end
  end

  # Goal 5: a finished destruction leaves its report in the journal and starts no controller again.
  defp destruction_check do
    biot_id = id(BiotId, 830)
    environment_id = id(EnvironmentId, 831)
    spec = spec(biot_id, environment_id, unreachable_repository(), selection(), :destroyed, 1)
    {:ok, _intent} = Journal.put_intent(spec)
    :ok = Controllers.intent_changed(biot_id)

    eventually(fn -> Journal.intent(biot_id).destruction_report != nil end, 60_000)
    eventually(fn -> running_controllers(biot_id) == [] end)

    report = Journal.intent(biot_id).destruction_report
    restart = Controllers.intent_changed(biot_id)

    IO.inspect(
      %{
        stored_report: %{
          accepted_revision: report.accepted_revision,
          container: report.container,
          data: report.data,
          failure: report.failure
        },
        outbox_report_matches: outbox_report(biot_id) == report,
        restart_result: restart,
        controllers_for_biot: length(running_controllers(biot_id)),
        retry_row: Journal.retry_state(biot_id),
        child_restart: BiotController.child_spec(biot_id: biot_id).restart
      },
      label: "5 destruction report survives the controller"
    )
  end

  # Goal 5: the connection replays the stored report, and a synchronization that omits the biot
  # deletes the intent row and the report with it.
  defp replay_check do
    biot_id = id(BiotId, 830)
    spec = Journal.intent(biot_id).biot_spec
    report = Journal.intent(biot_id).destruction_report
    {:ok, certificates} = Certificates.generate(@certificates, 1)
    :ets.delete(Outbox)
    connection_id = id(ConnectionId, 840)
    {listener, port} = raw_server(certificates)
    parent = self()

    server =
      Task.async(fn ->
        socket = accept_raw_server(listener)
        %Message.Hello{} = await_message(socket, :handshake)

        send_message(
          socket,
          %Message.Connected{connection_id: connection_id, selected_protocol_version: 1},
          :handshake
        )

        send_message(socket, %Message.SynchronizeBegin{connection_id: connection_id, count: 1}, 1)
        send_message(socket, %Message.SynchronizeItem{biot_spec: spec}, 1)
        send_message(socket, %Message.SynchronizeEnd{connection_id: connection_id}, 1)

        %Message.Synchronized{} = await_message_type(socket, 1, Message.Synchronized)
        ready = await_message_type(socket, 1, Message.Observation)
        send(parent, {:ready_replay, ready})

        send_message(socket, %Message.Desired{biot_spec: spec}, 1)
        repeat = await_message_type(socket, 1, Message.Observation)
        send(parent, {:desired_replay, repeat})
        :ssl.close(socket)
      end)

    connection = start_node_connection(port, certificates)
    ready = await(:ready_replay)
    repeat = await(:desired_replay)
    Task.await(server, @timeout)
    if Process.alive?(connection), do: GenServer.stop(connection)
    :ssl.close(listener)

    # A snapshot that omits the biot is what `Journal.replace_intents/1` receives, and it takes the
    # intent row and the retry row together.
    {:ok, _removed} = Journal.replace_intents([])

    IO.inspect(
      %{
        replay_when_ready: {ready.biot_id == biot_id, ready.execution_report == report},
        replay_after_desired: {repeat.biot_id == biot_id, repeat.execution_report == report},
        controller_started_for_stored_report: length(running_controllers(biot_id)),
        intent_after_omission: Journal.intent(biot_id),
        retry_row_after_omission: Journal.retry_state(biot_id)
      },
      label: "5 control connection replays the report"
    )
  end

  defp await(tag) do
    receive do
      {^tag, value} -> value
      ^tag -> :ok
    after
      @timeout -> raise "did not receive #{inspect(tag)}"
    end
  end

  defp outbox_report(biot_id) do
    case :ets.lookup(Outbox, {:observation, biot_id}) do
      [{_key, {:observation, ^biot_id, report}}] -> report
      [] -> nil
    end
  end

  defp running_controllers(biot_id) do
    Enum.filter(Controllers.running(), fn {id, _pid} -> id == biot_id end)
  end

  # A normal stop leaves a transient child stopped, which is how a finished destruction exits.
  defp stop_controller(biot_id) do
    case running_controllers(biot_id) do
      [{^biot_id, controller}] -> GenServer.stop(controller, :normal)
      [] -> :ok
    end
  end

  # Tracing one entry point records what the node actually ran, in order. The first argument names
  # the work: the action for a host run, the biot for a diagnostic write.
  defp trace(module, function, arity, body) do
    :erlang.trace_pattern({module, function, arity}, true, [:local])
    :erlang.trace(:processes, true, [:call])

    try do
      body.()
      collect_trace(module, function, [])
    after
      :erlang.trace(:processes, false, [:call])
      :erlang.trace_pattern({module, function, arity}, false, [:local])
    end
  end

  defp collect_trace(module, function, calls) do
    receive do
      {:trace, _pid, :call, {^module, ^function, [argument | _rest]}} ->
        collect_trace(module, function, [name_of(argument) | calls])
    after
      250 -> Enum.reverse(calls)
    end
  end

  defp name_of(argument) when is_tuple(argument), do: elem(argument, 0)
  defp name_of(argument), do: argument

  defp node_state(inspection, spec) do
    Observation.node_state(inspection, spec.execution.desired, nil, nil)
  end

  defp build_fixtures do
    File.mkdir_p!(@repositories)
    System.put_env("GIT_SSL_NO_VERIFY", "true")

    sources = %{
      checkout: git_repository("checkout", "checkout data\n", "README"),
      base_layer: git_repository("base-layer", layer("base-layer")),
      service_layer: git_repository("service-layer", layer("service-layer"))
    }

    {repositories, server} = served_repositories(sources)

    selection = %EnvironmentSelection{
      base_nixpkgs: SourceSelector.nixpkgs(),
      layers: [selector(repositories.base_layer), selector(repositories.service_layer)],
      project_context: nil
    }

    %{checkout: repositories.checkout, selection: selection, server: server}
  end

  defp layer(name) do
    File.read!(Path.join(@project_root, "nix/examples/stateful-counter/#{name}/default.nix"))
  end

  defp selector(repository) do
    {:ok, selector} = SourceSelector.new(repository, "main")
    selector
  end

  defp git_repository(name, content, filename \\ "default.nix") do
    path = Path.join(@repositories, name)
    File.mkdir_p!(path)
    File.write!(Path.join(path, filename), content)
    git!(path, ["init", "--quiet", "--initial-branch", "main"])
    git!(path, ["config", "user.name", "Biot evidence"])
    git!(path, ["config", "user.email", "evidence@example.test"])
    git!(path, ["add", filename])
    git!(path, ["commit", "--quiet", "--message", name])
    path
  end

  defp git!(path, arguments) do
    case System.cmd("git", arguments, cd: path, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git exited with #{status}: #{output}"
    end
  end

  defp served_repositories(sources) do
    served = Path.join(@repositories, "served")
    File.mkdir_p!(served)

    Enum.each(sources, fn {name, source} ->
      bare = Path.join(served, "#{name}.git")
      git!(@repositories, ["clone", "--quiet", "--bare", source, bare])
      git!(@repositories, ["--git-dir", bare, "update-server-info"])
    end)

    certificate = Path.join(@repositories, "server.crt")
    key = Path.join(@repositories, "server.key")

    {_output, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          key,
          "-out",
          certificate,
          "-days",
          "1",
          "-subj",
          "/CN=127.0.0.1",
          "-addext",
          "subjectAltName=IP:127.0.0.1"
        ],
        stderr_to_stdout: true
      )

    port_number = unused_port()

    server =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 1_024},
        args: [
          "-c",
          git_server_source(),
          served,
          Integer.to_string(port_number),
          certificate,
          key
        ]
      ])

    receive do
      {^server, {:data, {:eol, "ready"}}} -> :ok
    after
      @timeout -> raise "the git server did not start"
    end

    repositories =
      Map.new(sources, fn {name, _source} ->
        {:ok, repository} = RepositorySource.parse("https://127.0.0.1:#{port_number}/#{name}.git")
        {name, repository}
      end)

    {repositories, server}
  end

  defp git_server_source do
    """
    import http.server, os, ssl, subprocess, sys, urllib.parse

    class GitHandler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            self.run_backend()

        def do_POST(self):
            self.run_backend()

        def run_backend(self):
            parsed = urllib.parse.urlsplit(self.path)
            length = int(self.headers.get("Content-Length", "0"))
            environment = os.environ.copy()
            environment.update({
                "GIT_PROJECT_ROOT": sys.argv[1],
                "GIT_HTTP_EXPORT_ALL": "1",
                "PATH_INFO": parsed.path,
                "QUERY_STRING": parsed.query,
                "REQUEST_METHOD": self.command,
                "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                "CONTENT_LENGTH": str(length),
                "REMOTE_ADDR": self.client_address[0],
            })
            process = subprocess.run(
                ["git", "http-backend"],
                input=self.rfile.read(length),
                capture_output=True,
                env=environment,
            )
            headers, body = process.stdout.split(b"\\r\\n\\r\\n", 1)
            status = 200
            response_headers = []
            for line in headers.decode().split("\\r\\n"):
                name, value = line.split(":", 1)
                if name.lower() == "status":
                    status = int(value.strip().split(" ", 1)[0])
                else:
                    response_headers.append((name, value.strip()))
            self.send_response(status)
            for name, value in response_headers:
                self.send_header(name, value)
            if not any(name.lower() == "content-length" for name, _ in response_headers):
                self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            self.close_connection = True

        def log_message(self, format, *args):
            return

    server = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), GitHandler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[3], sys.argv[4])
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print("ready", flush=True)
    server.serve_forever()
    """
  end

  defp unused_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp unreachable_repository do
    {:ok, repository} = RepositorySource.parse("https://127.0.0.1:1/missing.git")
    repository
  end

  defp spec(biot_id, environment_id, repository, selection, state, revision) do
    %BiotSpec{
      execution: %ExecutionSpec{
        biot_id: biot_id,
        repository: repository,
        desired: %Desired{revision: revision, state: state, environment_id: environment_id},
        environment: %{id: environment_id, selection: selection}
      },
      access_revision: revision
    }
  end

  defp selection do
    {:ok, selection} =
      EnvironmentSelection.parse(%{
        "base_nixpkgs" => "nixpkgs",
        "layers" => [],
        "project_context" => nil
      })

    selection
  end

  defp raw_server(certificates) do
    options = [
      certfile: certificates.server.cert,
      keyfile: certificates.server.key,
      cacertfile: certificates.ca,
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      active: false,
      mode: :binary,
      packet: :raw,
      reuseaddr: true
    ]

    {:ok, listener} = :ssl.listen(0, options)
    {:ok, {_address, port}} = :ssl.sockname(listener)
    {listener, port}
  end

  defp accept_raw_server(listener) do
    {:ok, transport} = :ssl.transport_accept(listener, @timeout)
    {:ok, socket} = :ssl.handshake(transport, @timeout)
    socket
  end

  defp start_node_connection(port, certificates) do
    certificate = hd(certificates.nodes)

    {:ok, connection} =
      NodeConnection.start_link(
        server_host: "127.0.0.1",
        server_port: port,
        server_fingerprint: certificates.server.fingerprint,
        registration_id: id(RegistrationId, 901),
        tls: [
          certfile: certificate.cert,
          keyfile: certificate.key,
          cacertfile: certificates.ca
        ],
        heartbeat_interval_ms: 60_000,
        heartbeat_timeout_ms: 1_000,
        reconnect_backoff_min_ms: 10,
        reconnect_backoff_max_ms: 20
      )

    Process.unlink(connection)
    connection
  end

  defp send_message(socket, message, context) do
    {:ok, encoded} = Wire.encode(message, context)
    :ok = :ssl.send(socket, Frame.encode(encoded))
  end

  defp await_message(socket, context) do
    {:ok, <<size::unsigned-big-32>>} = :ssl.recv(socket, 4, @timeout)
    {:ok, payload} = :ssl.recv(socket, size, @timeout)
    {:ok, message} = Wire.decode(payload, context)
    message
  end

  defp await_message_type(socket, context, module) do
    case await_message(socket, context) do
      %Message.Heartbeat{challenge: challenge} ->
        send_message(socket, %Message.HeartbeatResponse{challenge: challenge}, context)
        await_message_type(socket, context, module)

      message ->
        if is_struct(message, module),
          do: message,
          else: await_message_type(socket, context, module)
    end
  end

  defp configure do
    File.mkdir_p!(@work)
    options = Application.fetch_env!(:biot_node, Biot.Node.Repo)

    Application.put_env(
      :biot_node,
      Biot.Node.Repo,
      options
      |> Keyword.put(:database, @database)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 1)
    )

    settings = [
      data_root: @data_root,
      uid_range_base: 100_000,
      uid_range_count: 1_024,
      uid_range_limit: 165_536,
      builder_image:
        "docker.io/nixos/nix@sha256:238dfe9a743a6e276e8e04d1db13b978c9bd91741445dec5d733c579596fea79",
      build_support_dir: @project_root,
      binary_cache_urls: ["https://cache.nixos.org"],
      binary_cache_keys: [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      ],
      host_command_timeout_ms: 600_000,
      worker_timeout_ms: 600_000,
      host_command_max_stderr_bytes: 256_000,
      runtime_log_max_bytes: 4_096,
      observation_interval_ms: @observation_interval_ms,
      inspection_retry_ms: @observation_interval_ms,
      retry_backoff_min_ms: @backoff_min_ms,
      retry_backoff_max_ms: @backoff_max_ms,
      controller_start_retry_ms: 60_000,
      container_events_retry_ms: @events_retry_ms
    ]

    Enum.each(settings, fn {key, value} -> Application.put_env(:biot_node, key, value) end)
  end

  defp start_dependencies do
    {:ok, _applications} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _applications} = Application.ensure_all_started(:ssl)
    {:ok, _platform} = Platform.current()
  end

  defp start_node_components do
    {:ok, supervisor} =
      Supervisor.start_link(
        [
          Biot.Node.RuntimeLogs,
          Biot.Node.Host.Command.Reaper,
          Biot.Node.DataRootLock,
          Biot.Node.Host.Setup,
          Biot.Node.Repo,
          Biot.Node.Journal.Migrator,
          Biot.Node.Controllers,
          Biot.Node.Host.ContainerEvents
        ],
        strategy: :one_for_one
      )

    Process.unlink(supervisor)
    :ok = Outbox.open()
    supervisor
  end

  defp eventually(function, timeout_ms \\ @timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    eventually(function, deadline, timeout_ms)
  end

  defp eventually(function, deadline, timeout_ms) do
    cond do
      function.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "condition did not become true within #{timeout_ms}ms"

      true ->
        receive do
        after
          100 -> eventually(function, deadline, timeout_ms)
        end
    end
  end

  defp id(module, number) do
    {:ok, value} = module.parse(id_string(number))
    value
  end

  defp id_string(number) do
    "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")
  end

  defp cleanup do
    config = Path.join(@data_root, "podman.conf")

    if File.exists?(config) do
      System.cmd("podman", ["--module", config, "rm", "--all", "--force"], stderr_to_stdout: true)

      System.cmd("podman", ["--module", config, "network", "prune", "--force"],
        stderr_to_stdout: true
      )
    end

    if File.dir?(@data_root) do
      File.chmod(@data_root, 0o700)
      System.cmd("podman", ["unshare", "chown", "-R", "0:0", @data_root], stderr_to_stdout: true)
    end

    File.rm_rf!(@work)
  end
end

Logger.configure(level: :warning)
Biot.Step14Evidence.run()
