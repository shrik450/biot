# This proof prints structured evidence for the outer ExUnit assertions.
# credo:disable-for-this-file Credo.Check.Warning.IoInspect
defmodule Step9Run do
  @moduledoc """
  Drives one Biot end to end through the real server, the real control link, and the real host.

  The Linux integration test loads this file through `test/support/step9_controller_runner.exs`.
  """

  import Ecto.Query, only: [from: 2]

  alias Biot.Node.Control, as: NodeControl
  alias Biot.Node.Control.Connection, as: NodeConnection
  alias Biot.Node.Control.Outbox
  alias Biot.Node.Controllers
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config, as: HostConfig
  alias Biot.Node.Host.Environment, as: HostEnvironment
  alias Biot.Node.Host.Names
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.Podman
  alias Biot.Node.Journal
  alias Biot.Node.StorePath
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Certificates
  alias Biot.Protocol.Digest
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.IncarnationId
  alias Biot.Protocol.NodeId
  alias Biot.Protocol.PrincipalId
  alias Biot.Protocol.RegistrationId
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector
  alias Biot.Server.Actor
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Create
  alias Biot.Server.Control.Listener
  alias Biot.Server.Diagnostics, as: ServerDiagnostics
  alias Biot.Server.NodeConnections
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Environment, as: EnvironmentRow
  alias Biot.Server.Schema.Node, as: NodeRow
  alias Biot.Server.Schema.NodeObservation
  alias Biot.Server.Schema.Observation
  alias Biot.Server.Schema.Operation
  alias Biot.Server.Schema.Principal
  alias Ecto.Adapters.SQL.Sandbox

  @home System.get_env("HOME", "/home/biot")
  @work System.get_env("BIOT_STEP9_TEST_ROOT", @home)
  @data_root Path.join(@work, "step9-data")
  @sources Path.join(@work, "step9-sources")
  @certificates Path.join(@work, "step9-certificates")
  @source_prefix "https://sources.biot.test/"
  @build_timeout_ms 600_000

  def run do
    Logger.configure(level: :info)
    Sandbox.mode(Repo, :auto)

    Enum.each([@data_root, @sources, @certificates], &File.rm_rf!/1)
    {:ok, certificates} = Certificates.generate(@certificates, 1)
    prepare_sources()

    port = free_port()
    {:ok, _listener} = start_listener(port, certificates)

    principal =
      Repo.insert!(%Principal{
        id: id(PrincipalId),
        issuer: "https://step9.test",
        subject: Ecto.UUID.generate()
      })

    actor = %Actor{principal_id: principal.id}

    node =
      Repo.insert!(%NodeRow{
        id: id(NodeId),
        registration: id(RegistrationId),
        peer_identity: hd(certificates.nodes).fingerprint,
        status: :enabled,
        max_biots: 10
      })

    configure_node(port, certificates, node.registration)
    start_node()
    ready = await(fn -> ready_connection(node.id) end, 20_000)
    section("node ready")
    IO.inspect(ready, label: "connection")

    {:ok, config} = HostConfig.from_application()

    {biot_id, environment_id} = prove_create_running(actor, node, config)
    prove_outbox(biot_id, environment_id)
    prove_repeated_exits(biot_id, config)
    prove_stop_and_destroy(actor, biot_id)
    prove_cancellation(actor, node)
    prove_startup_ownership(config)
    failed_biot_id = prove_failed_build(actor, node)
    prove_orphan(node, failed_biot_id)

    section("done")
    IO.puts("step 9 controller proof passed")
  end

  # The biot repository and the two example layers are local Git repositories. Git rewrites the
  # credential-free HTTPS URL the protocol requires to the local path, so both the checkout and
  # Nix's own fetch read the same commit without a network service.
  defp prepare_sources do
    File.mkdir_p!(@sources)
    git_global(["config", "--global", "user.name", "Biot proof"])
    git_global(["config", "--global", "user.email", "proof@biot.test"])
    git_global(["config", "--global", "url.#{@sources}/.insteadOf", @source_prefix])

    project = Path.join(@sources, "project")
    File.mkdir_p!(project)
    File.write!(Path.join(project, "README.md"), "step 9 project checkout\n")
    commit(project)

    # A layer whose only package takes a long time to build, so a destruction has something long
    # to cancel.
    slow = Path.join(@sources, "slow-layer")
    File.mkdir_p!(slow)

    File.write!(Path.join(slow, "default.nix"), """
    { pkgs, ... }:

    {
      biot.packages = [
        (pkgs.runCommand "biot-slow-build" { } "sleep 20; mkdir -p $out/bin")
      ];
    }
    """)

    commit(slow)

    Enum.each(
      [
        {"base-layer", "nix/examples/stateful-counter/base-layer/default.nix"},
        {"service-layer", "nix/examples/stateful-counter/service-layer/default.nix"},
        {"conflicting-layer", "nix/examples/conflicting-layer/default.nix"}
      ],
      fn {name, source} ->
        path = Path.join(@sources, name)
        File.mkdir_p!(path)
        File.cp!(Path.join(File.cwd!(), source), Path.join(path, "default.nix"))
        commit(path)
      end
    )

    section("git sources")
    IO.inspect(File.ls!(@sources), label: "repositories")
  end

  defp commit(path) do
    {_output, 0} =
      System.cmd("git", ["init", "--quiet", "--initial-branch", "main"],
        cd: path,
        stderr_to_stdout: true
      )

    {_output, 0} = System.cmd("git", ["add", "."], cd: path, stderr_to_stdout: true)

    {_output, 0} =
      System.cmd("git", ["commit", "--quiet", "-m", "step 9"], cd: path, stderr_to_stdout: true)
  end

  defp git_global(arguments) do
    {_output, 0} = System.cmd("git", arguments, stderr_to_stdout: true)
  end

  defp configure_node(port, certificates, registration_id) do
    certificate = hd(certificates.nodes)
    project_root = File.cwd!()

    settings = [
      data_root: @data_root,
      uid_range_base: 100_000,
      uid_range_count: 1_024,
      uid_range_limit: 165_536,
      git_executable: "git",
      nix_executable: "nix",
      nix_instantiate_executable: "nix-instantiate",
      podman_executable: "podman",
      podman_network_command: "slirp4netns",
      flock_executable: "flock",
      setsid_executable: "setsid",
      nix_build_file: Path.join(project_root, "nix/build.nix"),
      nix_pin_file: Path.join(project_root, "nix/pin.nix"),
      nixpkgs_repository: "https://github.com/NixOS/nixpkgs",
      nixpkgs_ref: "nixos-unstable",
      host_command_timeout_ms: 600_000,
      host_command_max_output_bytes: 256_000,
      host_command_max_stderr_bytes: 256_000,
      runtime_log_max_bytes: 4_096,
      mkfifo_executable: "mkfifo",
      head_executable: "head",
      cat_executable: "cat",
      sleep_executable: "sleep",
      retry_budget: 3,
      retry_backoff_min_ms: 2_000,
      retry_backoff_max_ms: 8_000,
      observation_interval_ms: 2_000,
      inspection_retry_ms: 2_000,
      cancel_grace_ms: 5_000,
      controller_start_retry_ms: 1_000,
      diagnostic_max_entries_per_biot: 3,
      diagnostic_max_entry_bytes: 4_096,
      server_host: "127.0.0.1",
      server_port: port,
      server_fingerprint: certificates.server.fingerprint,
      registration_id: registration_id,
      tls: [certfile: certificate.cert, keyfile: certificate.key, cacertfile: certificates.ca],
      reconnect_backoff_min_ms: 250,
      reconnect_backoff_max_ms: 1_000
    ]

    Enum.each(settings, fn {key, value} -> Application.put_env(:biot_node, key, value) end)
    Application.put_env(:biot_server, :node_response_max_bytes, 800)
    Application.put_env(:biot_server, :node_request_timeout_ms, 5_000)
  end

  defp start_node do
    Application.stop(:biot_node)
    {:ok, _applications} = Application.ensure_all_started(:biot_node)
  end

  defp start_listener(port, certificates) do
    Listener.start_link(
      port: port,
      tls: [
        certfile: certificates.server.cert,
        keyfile: certificates.server.key,
        cacertfile: certificates.ca
      ],
      handler_options: [handshake_timeout_ms: 5_000]
    )
  end

  defp prove_create_running(actor, node, config) do
    biot_id = id(BiotId)

    {:ok, accepted} =
      Biots.create(actor, biot_id, command("counter", node.id, ["base-layer", "service-layer"]))

    section("create")
    IO.inspect(accepted, label: "accepted")

    prove_restart_mid_action(biot_id)

    observation = await(fn -> running_observation(biot_id) end, @build_timeout_ms)
    section("running")
    IO.inspect(report_facts(observation), label: "execution report")
    IO.inspect(Repo.get!(Operation, accepted.operation_id).outcome, label: "create operation")

    prove_container(biot_id, config, observation)
    {biot_id, observation.installed_environment_id}
  end

  # Killing the controller while its effect runs proves the restart converges from durable intent
  # and inspection instead of replaying the sequence from the checkout.
  defp prove_restart_mid_action(biot_id) do
    controller = await(fn -> controller(biot_id) end, 30_000)
    action = await(fn -> preparing(controller) end, @build_timeout_ms)
    allocation = Journal.allocation(biot_id)
    attempts_before_kill = Journal.retry_state(biot_id).attempts

    section("controller killed mid-action")
    IO.inspect(elem(action, 0), label: "action in flight")

    :sys.suspend(Controllers)

    attempts_after_kill =
      try do
        Process.exit(controller, :kill)
        await(fn -> not Process.alive?(controller) end, 30_000)
        Journal.retry_state(biot_id).attempts
      after
        :sys.resume(Controllers)
      end

    IO.inspect(Map.get(attempts_before_kill, :prepare, 0) > 0,
      label: "attempt recorded before the action started"
    )

    IO.inspect(attempts_after_kill == attempts_before_kill,
      label: "attempt count unchanged while the controller restarted"
    )

    replacement = await(fn -> replacement(biot_id, controller) end, 30_000)
    first = await(fn -> effect_action(replacement) end, 120_000)
    IO.inspect(elem(first, 0), label: "first action after restart")

    IO.inspect(Journal.allocation(biot_id).initialization == allocation.initialization,
      label: "initialization marker unchanged"
    )
  end

  defp prove_container(biot_id, config, observation) do
    {:present, incarnation_id, :running} = observation.container
    name = Names.container(incarnation_id)

    {:ok, %Command.Result{status: 0, stdout: stdout}} = Podman.run(config, ["inspect", name])
    {:ok, [details]} = Jason.decode(stdout)

    mounts =
      details |> Map.fetch!("Mounts") |> Enum.map(&{&1["Destination"], &1["RW"]}) |> Enum.sort()

    section("container")
    IO.inspect(details["HostConfig"]["ReadonlyRootfs"], label: "read-only root filesystem")
    IO.inspect(mounts, label: "mounts")
    IO.inspect(details["Config"]["Labels"], label: "labels")

    IO.puts(await(fn -> service_processes(config, name) end, 60_000))

    {:ok, bundle} = HostEnvironment.bundle(config, observation.installed_environment_id)
    environment = File.read!(StorePath.to_string(bundle.environment_file))

    IO.inspect(
      Enum.filter(String.split(environment, "\n"), &String.contains?(&1, "BIOT_EXAMPLE")),
      label: "merged layer environment"
    )

    IO.inspect(File.ls!(Paths.service_data(config, biot_id)), label: "service data")

    IO.inspect(write_state(config, name, "survives-replacement"),
      label: "state written through the service"
    )

    IO.inspect(read_state(config, name), label: "state read back")

    IO.inspect(exec(config, name, ["--silent", "--fail", "http://127.0.0.1:8080/message"]),
      label: "declared file"
    )
  end

  # The mounts belong to the allocation's user range, so the host user reaches the service's own
  # state the way a person would: through the service, inside the container.
  defp service_processes(config, name) do
    {:ok, %Command.Result{status: 0, stdout: processes}} = Podman.run(config, ["top", name])
    if String.contains?(processes, "biot-state-server"), do: processes
  end

  defp write_state(config, name, value) do
    exec(config, name, [
      "--silent",
      "--show-error",
      "--fail",
      "--retry",
      "30",
      "--retry-all-errors",
      "--retry-delay",
      "1",
      "--request",
      "PUT",
      "--data",
      value,
      "http://127.0.0.1:8080/"
    ])

    read_state(config, name)
  end

  defp read_state(config, name) do
    exec(config, name, [
      "--silent",
      "--show-error",
      "--fail",
      "--retry",
      "30",
      "--retry-all-errors",
      "--retry-delay",
      "1",
      "http://127.0.0.1:8080/"
    ])
  end

  defp exec(config, name, arguments) do
    {:ok, %Command.Result{status: 0, stdout: stdout}} =
      Podman.run(config, ["exec", name, curl_executable() | arguments])

    stdout
  end

  # Every container mounts the whole store read only, so any curl in the store is reachable inside
  # it. The base layer puts this one in the environment.
  defp curl_executable do
    "/nix/store/*curl*/bin/curl" |> Path.wildcard() |> hd()
  end

  defp prove_repeated_exits(biot_id, config) do
    section("repeated container exits")

    rounds =
      Enum.reduce_while(1..4, [], fn round, rounds ->
        observation = await(fn -> running_observation(biot_id) end, @build_timeout_ms)
        {:present, incarnation_id, :running} = observation.container
        name = Names.container(incarnation_id)
        state = read_state(config, name)
        started = System.monotonic_time(:millisecond)
        {:ok, %Command.Result{status: 0}} = Podman.run(config, ["kill", name])

        failure = await(fn -> reported_failure(biot_id) end, 120_000)
        reported = System.monotonic_time(:millisecond)

        entry = %{
          round: round,
          incarnation: incarnation_id,
          state: state,
          failure: failure,
          after_ms: reported - started,
          recovery_ms: recovery_ms(biot_id, failure, reported)
        }

        if failure.retry == :operator,
          do: {:halt, [entry | rounds]},
          else: {:cont, [entry | rounds]}
      end)
      |> Enum.reverse()

    Enum.each(rounds, fn entry ->
      IO.puts(
        "round #{entry.round}: state=#{inspect(entry.state)} #{entry.failure.code} retry=#{entry.failure.retry} reported #{entry.after_ms} ms after the kill, running again #{inspect(entry.recovery_ms)} ms later: #{entry.failure.message}"
      )
    end)

    IO.inspect(Enum.uniq(Enum.map(rounds, &IncarnationId.to_string(&1.incarnation))),
      label: "incarnations"
    )

    IO.inspect(Repo.get!(Observation, biot_id).failure,
      label: "operator failure in the observation"
    )
  end

  # The delay includes the start effect, so it is the backoff plus one container start.
  defp recovery_ms(biot_id, %{retry: :automatic}, reported) do
    _observation = await(fn -> running_observation(biot_id) end, 120_000)
    System.monotonic_time(:millisecond) - reported
  end

  defp recovery_ms(_biot_id, _failure, _reported), do: nil

  defp prove_stop_and_destroy(actor, biot_id) do
    section("stop")
    revision = Repo.get!(Observation, biot_id).accepted_revision
    {:ok, stopped} = Biots.stop(actor, biot_id, revision)
    observation = await(fn -> stopped_observation(biot_id, stopped.revision) end, 120_000)
    IO.inspect(report_facts(observation), label: "execution report")
    IO.inspect(Repo.get!(Operation, stopped.operation_id).outcome, label: "stop operation")

    section("destroy")
    {:ok, destroyed} = Biots.destroy(actor, biot_id)
    observation = await(fn -> destroyed_observation(biot_id, destroyed.revision) end, 300_000)
    IO.inspect(report_facts(observation), label: "execution report")
    IO.inspect(Repo.get!(Operation, destroyed.operation_id).outcome, label: "destroy operation")

    IO.inspect(File.exists?(Path.join(@data_root, "biots/#{BiotId.to_string(biot_id)}")),
      label: "biot directory remains"
    )

    section("resynchronize after destruction")
    resynchronize()

    IO.inspect(await(fn -> Journal.intent(biot_id) == nil end, 30_000),
      label: "local intent removed"
    )

    IO.inspect(await(fn -> controller(biot_id) == nil end, 30_000), label: "controller stopped")
  end

  # A long preparation ends with its owner. A controller that dies takes its command group with it,
  # and a destruction cancels the group of the command still running.
  defp prove_cancellation(actor, node) do
    section("a long preparation and its owner")
    biot_id = id(BiotId)

    {:ok, _accepted} =
      Biots.create(actor, biot_id, command("slow", node.id, ["base-layer", "slow-layer"]))

    controller = await(fn -> controller(biot_id) end, 60_000)
    _action = await(fn -> preparing(controller) end, @build_timeout_ms)
    owned = await(fn -> some_process_ids("nix build") end, 60_000)
    IO.inspect(owned, label: "nix build processes the controller owns")

    Process.exit(controller, :kill)

    IO.inspect(await(fn -> gone?(owned) end, 30_000),
      label: "those processes gone after the controller was killed"
    )

    replacement = await(fn -> replacement(biot_id, controller) end, 30_000)
    _action = await(fn -> preparing(replacement) end, @build_timeout_ms)
    IO.inspect(processes("nix build"), label: "nix build processes after the restart")
    IO.inspect(processes("sleep 97"), label: "slow derivation processes")

    started = System.monotonic_time(:millisecond)
    {:ok, destroyed} = Biots.destroy(actor, biot_id)
    observation = await(fn -> destroyed_observation(biot_id, destroyed.revision) end, 300_000)

    IO.inspect(System.monotonic_time(:millisecond) - started, label: "destroyed after (ms)")
    IO.inspect(report_facts(observation), label: "execution report")
    IO.inspect(processes("nix build"), label: "nix build processes after the cancellation")
    IO.inspect(processes("sleep 97"), label: "slow derivation processes after the cancellation")
  end

  # A caller that dies in the first milliseconds of a command leaves nothing running. Suspending
  # the reaper parks the caller between the group announcement and the go line, which is the window
  # a kill has to hit for this to be a proof.
  defp prove_startup_ownership(config) do
    section("a command whose caller dies before the go line")
    reaper = Process.whereis(Command.Reaper)
    :sys.suspend(reaper)

    caller =
      spawn(fn ->
        Command.run(
          config.setsid_executable,
          HostConfig.capture_tools(config),
          "sleep",
          ["99137"],
          timeout_ms: 120_000
        )
      end)

    {:watch, _caller, process_group, stderr_path} =
      await(fn -> queued_watch(reaper, caller) end, 30_000)

    IO.inspect(process_group, label: "group the shell announced")

    IO.inspect(command_line(process_group),
      label: "what the group leader runs while the caller waits"
    )

    IO.inspect(processes("99137"), label: "processes in the pipeline while the caller waits")

    Process.exit(caller, :kill)
    :sys.resume(reaper)

    IO.inspect(await(fn -> not Process.alive?(caller) end, 5_000), label: "caller gone")
    IO.inspect(await(fn -> gone?([process_group]) end, 10_000), label: "announced group gone")
    IO.inspect(processes("99137"), label: "processes after the caller was killed")
    IO.inspect(File.exists?(stderr_path), label: "stderr file remains")
  end

  defp queued_watch(reaper, caller) do
    {:messages, messages} = Process.info(reaper, :messages)

    Enum.find_value(messages, fn
      {:"$gen_call", _from, {:watch, ^caller, _group, _path} = watch} -> watch
      _other -> nil
    end)
  end

  defp command_line(process_group) do
    case File.read("/proc/#{process_group}/cmdline") do
      {:ok, content} ->
        content |> String.split(<<0>>, trim: true) |> Enum.take(2) |> Enum.join(" ")

      {:error, reason} ->
        reason
    end
  end

  # Reports wait in a bounded outbox instead of the connection's mailbox. Suspending the connection
  # holds the link ready while the biot keeps reporting, so the outbox can be read as it coalesces.
  # The server forgets the observation and the resolution first, so what it holds afterwards is what
  # the drain delivered.
  defp prove_outbox(biot_id, environment_id) do
    section("bounded coalescing outbox")
    connection = Process.whereis(NodeConnection)
    :sys.suspend(connection)

    forget_reports(biot_id, environment_id)
    IO.inspect(Repo.get(Observation, biot_id), label: "server observation while the link is held")

    samples =
      Enum.map(1..3, fn _interval ->
        Process.sleep(2_000)
        Enum.map(outbox_entries(), &outbox_fact/1)
      end)

    IO.inspect(samples, label: "outbox at each observation interval")
    IO.inspect(message_shapes(connection), label: "connection mailbox")

    :sys.resume(connection)
    observation = await(fn -> Repo.get(Observation, biot_id) end, 30_000)
    IO.inspect(report_facts(observation), label: "execution report after the resume")

    IO.inspect(await(fn -> resolved_digest(environment_id) end, 30_000),
      label: "resolution digest after the resume"
    )

    section("reports after a reconnect")
    forget_reports(biot_id, environment_id)
    resynchronize()
    observation = await(fn -> Repo.get(Observation, biot_id) end, 30_000)
    IO.inspect(report_facts(observation), label: "execution report after the reconnect")

    IO.inspect(await(fn -> resolved_digest(environment_id) end, 30_000),
      label: "resolution digest after the reconnect"
    )
  end

  # The server forgets what the node told it, so what it holds next is what the node reported next.
  defp forget_reports(biot_id, environment_id) do
    Repo.delete_all(from_biot(Observation, biot_id))

    EnvironmentRow
    |> Repo.get!(environment_id)
    |> Ecto.Changeset.change(resolution: :unresolved)
    |> Repo.update!()
  end

  # The outbox table is the connection's, and reading it from here shows what a blocked link holds.
  defp outbox_entries do
    Outbox
    |> :ets.tab2list()
    |> Enum.reject(&match?({:wakeup, _pending}, &1))
    |> Enum.map(fn {_key, report} -> report end)
  end

  defp outbox_fact({:observation, biot_id, report}) do
    {:observation, BiotId.to_string(biot_id), report.accepted_revision}
  end

  defp outbox_fact({:resolution, environment_id, _manifest}) do
    {:resolution, EnvironmentId.to_string(environment_id)}
  end

  defp outbox_fact({:node_observation, allocations}), do: {:node_observation, length(allocations)}

  defp message_shapes(pid) do
    {:messages, messages} = Process.info(pid, :messages)
    Enum.map(messages, &message_shape/1)
  end

  defp message_shape({:"$gen_cast", request}), do: {:cast, request}
  defp message_shape(message) when is_tuple(message), do: elem(message, 0)
  defp message_shape(message), do: message

  defp resolved_digest(environment_id) do
    case Repo.get!(EnvironmentRow, environment_id).resolution do
      {:resolved, manifest} -> Digest.to_string(manifest.digest)
      :unresolved -> nil
    end
  end

  defp processes(pattern), do: length(process_ids(pattern))

  defp process_ids(pattern) do
    {output, _status} = System.cmd("pgrep", ["-f", pattern], stderr_to_stdout: true)
    String.split(output, "\n", trim: true)
  end

  defp some_process_ids(pattern) do
    case process_ids(pattern) do
      [] -> nil
      ids -> ids
    end
  end

  defp gone?(ids), do: Enum.all?(ids, &process_ended?/1)

  defp process_ended?(id) do
    case File.read("/proc/#{id}/stat") do
      {:error, :enoent} -> true
      {:ok, stat} -> Regex.match?(~r/^\d+ \(.+\) Z /, stat)
      {:error, _reason} -> false
    end
  end

  defp prove_failed_build(actor, node) do
    section("failing build")
    biot_id = id(BiotId)

    {:ok, accepted} =
      Biots.create(
        actor,
        biot_id,
        command("conflict", node.id, ["base-layer", "service-layer", "conflicting-layer"])
      )

    failure = await(fn -> reported_failure(biot_id) end, @build_timeout_ms)

    IO.inspect(
      %{stage: failure.stage, code: failure.code, retry: failure.retry, message: failure.message},
      label: "failure"
    )

    IO.inspect(Repo.get!(Operation, accepted.operation_id).outcome, label: "create operation")
    IO.inspect(ServerDiagnostics.get(actor, failure.diagnostic_ref), label: "diagnostic")
    IO.inspect(report_facts(Repo.get!(Observation, biot_id)), label: "execution report")
    IO.inspect(Journal.allocation(biot_id) != nil, label: "allocation kept")

    biot_id
  end

  defp prove_orphan(node, biot_id) do
    section("server forgets a biot")
    Repo.delete_all(from_biot(Observation, biot_id))
    Repo.delete_all(from_biot(Operation, biot_id))
    Repo.delete_all(from(row in Biot.Server.Schema.Biot, where: row.id == ^biot_id))
    Repo.delete_all(from_biot(EnvironmentRow, biot_id))

    resynchronize()
    orphaned = await(fn -> orphaned_allocations(node.id, biot_id) end, 30_000)
    IO.inspect(orphaned, label: "node observation")
    IO.inspect(Journal.intent(biot_id) == nil, label: "local intent removed")
    IO.inspect(controller(biot_id) == nil, label: "controller stopped")

    IO.inspect(Journal.allocation(biot_id) != nil,
      label: "allocation kept, not adopted or deleted"
    )
  end

  defp from_biot(schema, biot_id) do
    from(row in schema, where: row.biot_id == ^biot_id)
  end

  defp orphaned_allocations(node_id, biot_id) do
    case Repo.get(NodeObservation, node_id) do
      nil ->
        nil

      %NodeObservation{orphaned_allocations: allocations} ->
        Enum.find(allocations, &(&1.biot_id == biot_id))
    end
  end

  defp resynchronize do
    connection = Process.whereis(NodeConnection)
    reference = Process.monitor(connection)
    Process.exit(connection, :kill)

    receive do
      {:DOWN, ^reference, :process, ^connection, _reason} -> :ok
    after
      5_000 -> raise "the node connection did not stop"
    end

    await(
      fn ->
        case Process.whereis(NodeConnection) do
          replacement when is_pid(replacement) and replacement != connection -> replacement
          _other -> nil
        end
      end,
      30_000
    )
  end

  defp command(name, node_id, layers) do
    %Create{
      name: "step9-#{name}-#{System.unique_integer([:positive])}",
      repository: source("project"),
      environment: %EnvironmentSelection{
        base_nixpkgs: SourceSelector.nixpkgs(),
        layers: Enum.map(layers, &selector/1),
        project_context: nil
      },
      node_id: node_id
    }
  end

  defp selector(name) do
    {:ok, selector} = SourceSelector.new(source(name), "main")
    selector
  end

  defp source(name) do
    {:ok, repository} = RepositorySource.parse(@source_prefix <> name)
    repository
  end

  defp controller(biot_id) do
    case Enum.find(Controllers.running(), fn {id, _pid} -> id == biot_id end) do
      {_id, pid} -> pid
      nil -> nil
    end
  end

  defp preparing(pid) do
    case effect_action(pid) do
      {:prepare, _environment_id, _manifest} = action -> action
      _other -> nil
    end
  end

  defp effect_action(pid) do
    case :sys.get_state(pid) do
      %{phase: {:running, %{action: action}}} -> action
      _other -> nil
    end
  end

  defp replacement(biot_id, previous) do
    case controller(biot_id) do
      pid when is_pid(pid) and pid != previous -> pid
      _other -> nil
    end
  end

  defp running_observation(biot_id) do
    case Repo.get(Observation, biot_id) do
      %Observation{container: {:present, _incarnation_id, :running}, failure: nil} = observation ->
        if observation.installed_environment_id, do: observation

      _other ->
        nil
    end
  end

  defp stopped_observation(biot_id, revision) do
    case Repo.get(Observation, biot_id) do
      %Observation{container: :absent, accepted_revision: ^revision} = observation -> observation
      _other -> nil
    end
  end

  defp destroyed_observation(biot_id, revision) do
    case Repo.get(Observation, biot_id) do
      %Observation{data: :no_allocation, accepted_revision: ^revision} = observation ->
        observation

      _other ->
        nil
    end
  end

  defp reported_failure(biot_id) do
    case Repo.get(Observation, biot_id) do
      %Observation{failure: {_revision, failure}} -> failure
      _other -> nil
    end
  end

  defp report_facts(%Observation{} = observation) do
    %{
      accepted_revision: observation.accepted_revision,
      installed_environment_id: observation.installed_environment_id,
      container: observation.container,
      data: observation.data,
      failure: observation.failure
    }
  end

  defp ready_connection(node_id) do
    case NodeConnections.current(node_id) do
      %{state: :ready} = connection -> connection
      _other -> nil
    end
  end

  defp section(title), do: IO.puts("\n=== #{title} ===")

  defp await(function, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await(function, deadline, timeout_ms)
  end

  defp await(function, deadline, timeout_ms) do
    case function.() do
      nil ->
        retry(function, deadline, timeout_ms)

      false ->
        retry(function, deadline, timeout_ms)

      value ->
        value
    end
  end

  defp retry(function, deadline, timeout_ms) do
    if System.monotonic_time(:millisecond) >= deadline do
      raise "timed out after #{timeout_ms} ms"
    else
      Process.sleep(200)
      await(function, deadline, timeout_ms)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp id(module) do
    {:ok, value} = module.parse(Ecto.UUID.generate())
    value
  end
end

Step9Run.run()
