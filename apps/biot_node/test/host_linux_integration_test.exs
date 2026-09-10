defmodule Biot.Node.HostLinuxIntegrationTest do
  use ExUnit.Case, async: false

  alias Biot.Node.Allocation
  alias Biot.Node.Controllers
  alias Biot.Node.DataRootLock
  alias Biot.Node.Host
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Command.Reaper
  alias Biot.Node.Host.ContainerEvents
  alias Biot.Node.Host.Environment, as: HostEnvironment
  alias Biot.Node.Host.Inspection
  alias Biot.Node.Host.Names
  alias Biot.Node.Host.Network
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.Podman
  alias Biot.Node.Host.Setup
  alias Biot.Node.Journal
  alias Biot.Node.Journal.Migrator
  alias Biot.Node.NodeState
  alias Biot.Node.Reconcile
  alias Biot.Node.Repo
  alias Biot.Node.RetryState
  alias Biot.Node.StorePath
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.ExecutionSpec
  alias Biot.Protocol.IncarnationId
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector

  @moduletag :linux
  @moduletag :nix
  @moduletag timeout: 1_800_000

  setup_all do
    project_root = Path.expand("../../..", __DIR__)
    data_root = temporary_directory("biot-host-linux")
    repository_root = temporary_directory("biot-host-git")
    settings = host_settings(data_root, project_root)

    previous =
      Map.new(settings, fn {key, _value} -> {key, Application.get_env(:biot_node, key)} end)

    Enum.each(settings, fn {key, value} -> Application.put_env(:biot_node, key, value) end)

    start_supervised!({DataRootLock, data_root: data_root})
    assert :ignore = Setup.start_link([])
    start_supervised!(Repo)
    assert :ignore = Migrator.start_link([])

    checkout_source =
      git_repository(repository_root, "checkout-source", "checkout data\n", "README")

    base_layer = git_repository(repository_root, "base-layer", layer(project_root, "base-layer"))

    service_layer =
      git_repository(repository_root, "service-layer", layer(project_root, "service-layer"))

    broken_layer = git_repository(repository_root, "broken-layer", "{ this is not valid Nix; }\n")

    {repositories, server} =
      served_repositories(repository_root, %{
        checkout: checkout_source,
        base_layer: base_layer,
        service_layer: service_layer,
        broken_layer: broken_layer
      })

    old_ssl = System.get_env("GIT_SSL_NO_VERIFY")
    System.put_env("GIT_SSL_NO_VERIFY", "true")

    on_exit(fn ->
      if Port.info(server), do: Port.close(server)
      remove_all_test_containers(settings)
      File.chmod(data_root, 0o700)
      System.cmd("podman", ["unshare", "chown", "-R", "0:0", data_root], stderr_to_stdout: true)
      File.rm_rf!(data_root)
      File.rm_rf!(repository_root)

      if old_ssl,
        do: System.put_env("GIT_SSL_NO_VERIFY", old_ssl),
        else: System.delete_env("GIT_SSL_NO_VERIFY")

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:biot_node, key)
        {key, value} -> Application.put_env(:biot_node, key, value)
      end)
    end)

    {:ok,
     data_root: data_root,
     project_root: project_root,
     checkout_repository: repositories.checkout,
     base_layer: repositories.base_layer,
     service_layer: repositories.service_layer,
     broken_layer: repositories.broken_layer}
  end

  test "real host resources preserve ownership, data, and repeated effects", context do
    prove_second_process_lock(context.data_root)

    biot_id = id(BiotId, 801)
    environment_id = id(EnvironmentId, 802)
    {:ok, host} = Host.context(biot_id)

    selection = %EnvironmentSelection{
      base_nixpkgs: SourceSelector.nixpkgs(),
      layers: [selector(context.base_layer), selector(context.service_layer)],
      project_context: nil
    }

    running =
      execution(biot_id, environment_id, context.checkout_repository, selection, :running, 1)

    assert {:run, {:allocate, ^biot_id} = allocate} = decision(running, host)
    assert :ok = Host.run(allocate, host)
    allocated_once = Host.inspect_state(biot_id, host)
    repeated_allocate = Host.run(allocate, host)
    allocated_twice = Host.inspect_state(biot_id, host)
    assert {:uninitialized, allocation} = allocated_once.data

    rootfs = Paths.rootfs(host.config, biot_id)
    assert {_, 0} = System.cmd("podman", ["unshare", "chown", "-R", "0:0", rootfs])
    File.rm_rf!(rootfs)

    assert {:ok, %Command.Result{status: 0}} =
             Podman.run(host.config, ["network", "rm", Names.network(allocation.network_id)])

    repaired_allocate = Host.run(allocate, host)
    repaired_rootfs = File.dir?(rootfs)
    repaired_network = Network.state(host.config, allocation.network_id)

    assert repaired_allocate == :ok
    assert repaired_rootfs
    assert repaired_network == :present

    assert {:run, {:initialize, ^allocation, _repository} = initialize} = decision(running, host)
    assert :ok = Host.run(initialize, host)
    initialized_once = Host.inspect_state(biot_id, host)
    assert :ok = Host.run(initialize, host)
    assert Host.inspect_state(biot_id, host) == initialized_once

    assert File.read!(Path.join(Paths.checkout(host.config, biot_id), "README")) ==
             "checkout data\n"

    refute File.exists?(Paths.checkout_staging(host.config, biot_id))

    {settled, create_actions} = converge(running, host)
    assert create_actions == [:resolve, :prepare, :install, :start]
    assert decision(running, host) == :settled
    assert {:present, first_container} = settled.container

    assert {:ok, _intent} =
             Journal.put_intent(%BiotSpec{execution: running, access_revision: 1})

    start_supervised!(Controllers)
    start_supervised!(ContainerEvents)
    assert eventually(fn -> controller_running?(biot_id) end)
    started = System.monotonic_time(:millisecond)

    assert {:ok, %Command.Result{status: 0}} =
             Podman.run(host.config, ["kill", Names.container(first_container.incarnation_id)])

    assert eventually(fn ->
             match?(
               %RetryState{failure: %{code: :container_failed}},
               Journal.retry_state(biot_id)
             )
           end)

    assert System.monotonic_time(:millisecond) - started < 30_000
    stop_supervised!(ContainerEvents)
    stop_supervised!(Controllers)
    assert :ok = Journal.replace_intents([])
    {settled, _recovery_actions} = converge(running, host)
    assert {:present, first_container} = settled.container

    assert :ok = Host.run({:start, allocation, installed(settled)}, host)
    assert Host.inspect_state(biot_id, host).container == settled.container

    bundle = bundle(host, environment_id)
    curl = curl_executable(bundle)

    assert eventually(fn ->
             container_curl(host, first_container, curl, "GET", "/") == {"", 0}
           end)

    assert {_, 0} = container_curl(host, first_container, curl, "PUT", "/", "kept-state")

    stopped =
      execution(biot_id, environment_id, context.checkout_repository, selection, :stopped, 2)

    {stopped_state, stop_actions} = converge(stopped, host)
    assert stop_actions == [:retire]
    assert stopped_state.container == :absent

    restarted =
      execution(biot_id, environment_id, context.checkout_repository, selection, :running, 3)

    {restarted_state, start_actions} = converge(restarted, host)
    assert start_actions == [:start]
    assert {:present, restarted_container} = restarted_state.container
    refute restarted_container.incarnation_id == first_container.incarnation_id

    assert eventually(fn ->
             container_curl(host, restarted_container, curl, "GET", "/") == {"kept-state", 0}
           end)

    assert File.read!(Path.join(Paths.service_data(host.config, biot_id), "counter/value")) ==
             "kept-state"

    assert :ok = Host.run({:retire, restarted_container.incarnation_id}, host)
    retired_once = Host.inspect_state(biot_id, host)
    assert :ok = Host.run({:retire, restarted_container.incarnation_id}, host)
    assert Host.inspect_state(biot_id, host) == retired_once
    assert retired_once.container == :absent

    {running_again, [:start]} = converge(restarted, host)
    assert {:present, old_container} = running_again.container
    old_data = running_again.data

    second_id = id(BiotId, 804)
    second_environment = id(EnvironmentId, 810)
    {:ok, second_host} = Host.context(second_id)

    second_running =
      execution(
        second_id,
        second_environment,
        context.checkout_repository,
        selection,
        :running,
        1
      )

    {second_state, _second_actions} = converge(second_running, second_host)
    second_allocation = Journal.allocation(second_id)
    refute second_allocation.uid_range.start == allocation.uid_range.start
    assert {:present, second_container} = second_state.container

    first_address = container_address(host, old_container)
    second_address = container_address(second_host, second_container)

    assert eventually(fn -> container_reaches(host, old_container, curl, "127.0.0.1") end)

    assert eventually(fn ->
             container_reaches(second_host, second_container, curl, "127.0.0.1")
           end)

    refute container_reaches(host, old_container, curl, second_address)
    refute container_reaches(second_host, second_container, curl, first_address)

    assert :ok = Host.run({:retire, second_container.incarnation_id}, second_host)
    assert :ok = Host.run({:release_environment, second_environment}, second_host)

    broken_environment = id(EnvironmentId, 803)

    broken_selection = %EnvironmentSelection{
      base_nixpkgs: SourceSelector.nixpkgs(),
      layers: [selector(context.broken_layer)],
      project_context: nil
    }

    broken =
      execution(
        biot_id,
        broken_environment,
        context.checkout_repository,
        broken_selection,
        :running,
        4
      )

    assert {:run, {:resolve, ^broken_environment, _, _} = resolve} = decision(broken, host)
    assert :ok = Host.run(resolve, host)
    assert {:run, {:prepare, ^broken_environment, _manifest} = prepare} = decision(broken, host)
    assert {:error, %Biot.Node.Host.Outcome{outcome: :build_failed}} = Host.run(prepare, host)
    after_failed_build = Host.inspect_state(biot_id, host)
    assert after_failed_build.container == {:present, old_container}
    assert after_failed_build.data == old_data

    assert :ok = Host.run({:retire, old_container.incarnation_id}, host)
    foreign_id = IncarnationId.generate()
    start_foreign_container(host, allocation, installed(after_failed_build), bundle, foreign_id)

    foreign_state = Host.inspect_state(biot_id, host)
    assert {:present, %{biot_id: foreign_owner}} = foreign_state.container
    assert foreign_owner == id(BiotId, 899)

    assert {:error, %Biot.Node.Host.Outcome{outcome: :ownership_mismatch}} =
             Host.run({:retire, foreign_id}, host)

    assert {:present, _container} = Host.inspect_state(biot_id, host).container
    remove_container(host, foreign_id)
    File.rm(Paths.container_identity(host.config, biot_id))

    assert :ok = Host.run({:release_allocation, allocation}, host)
    assert Allocation.resources(Journal.allocation(biot_id)) == Allocation.resources(allocation)

    assert :ok = Host.run({:release_environment, broken_environment}, host)
    assert :ok = Host.run({:release_environment, environment_id}, host)
    assert :ok = Host.run({:release_allocation, allocation}, host)
    assert Allocation.resources(Journal.allocation(biot_id)) == Allocation.resources(allocation)

    third_id = id(BiotId, 805)
    {:ok, third_host} = Host.context(third_id)
    assert :ok = Host.run({:allocate, third_id}, third_host)
    third_allocation = Journal.allocation(third_id)
    refute third_allocation.uid_range.start == allocation.uid_range.start

    assert :ok = Host.run({:remove_data, allocation}, host)
    assert :ok = Host.run({:release_allocation, allocation}, host)
    assert Journal.allocation(biot_id) == nil

    reused_id = id(BiotId, 806)
    {:ok, reused_host} = Host.context(reused_id)
    assert :ok = Host.run({:allocate, reused_id}, reused_host)
    assert Journal.allocation(reused_id).uid_range.start == allocation.uid_range.start

    cleanup_allocation(second_host, second_allocation)
    cleanup_allocation(third_host, third_allocation)
    cleanup_allocation(reused_host, Journal.allocation(reused_id))

    prove_lost_and_unknown(context.checkout_repository)

    final_id = id(BiotId, 807)
    final_environment = id(EnvironmentId, 808)
    {:ok, final_host} = Host.context(final_id)

    final_running =
      execution(final_id, final_environment, context.checkout_repository, selection, :running, 1)

    {_final_state, _actions} = converge(final_running, final_host)

    destroyed =
      execution(
        final_id,
        final_environment,
        context.checkout_repository,
        selection,
        :destroyed,
        2
      )

    {destroyed_state, destroy_actions} = converge(destroyed, final_host)
    assert destroy_actions == [:retire, :release_environment, :remove_data, :release_allocation]
    assert destroyed_state.data == :no_allocation
    assert destroyed_state.container == :absent
    assert destroyed_state.installation == nil
    assert destroyed_state.resolutions == %{}
    assert repeated_allocate == :ok
    assert allocated_twice == allocated_once
  end

  test "the container event reader releases commands that exit at once", context do
    executable = Path.join(context.data_root, "exiting-podman")
    File.write!(executable, "#!/bin/sh\nexit 1\n")
    File.chmod!(executable, 0o700)
    previous = Application.fetch_env!(:biot_node, :podman_executable)
    before = MapSet.new(Path.wildcard(Path.join(System.tmp_dir!(), "biot-command-*")))
    Application.put_env(:biot_node, :podman_executable, executable)

    on_exit(fn -> Application.put_env(:biot_node, :podman_executable, previous) end)

    reader = start_supervised!(ContainerEvents)
    Process.sleep(1_500)

    assert Process.alive?(reader)
    assert Process.whereis(ContainerEvents) == reader
    assert :sys.get_state(Reaper) == %{}

    after_files = MapSet.new(Path.wildcard(Path.join(System.tmp_dir!(), "biot-command-*")))
    assert MapSet.difference(after_files, before) == MapSet.new()
  end

  defp prove_second_process_lock(data_root) do
    lock_root = Path.join(data_root, "lock-proof")
    name = Module.concat(__MODULE__, "Lock#{System.unique_integer([:positive])}")
    {:ok, lock} = DataRootLock.start_link(data_root: lock_root, name: name)

    code = """
    Process.flag(:trap_exit, true)

    case Biot.Node.DataRootLock.start_link(data_root: #{inspect(lock_root)}, name: SecondLock) do
      {:error, %Biot.Node.DataRootLock.Error{reason: :already_locked}} -> System.halt(0)
      _other -> System.halt(1)
    end
    """

    assert {_, 0} = System.cmd("mix", ["run", "--no-start", "--no-compile", "-e", code])
    refute File.exists?(Path.join(lock_root, "journal.sqlite3"))
    refute File.exists?(Path.join(lock_root, "biots"))
    GenServer.stop(lock)
  end

  defp prove_lost_and_unknown(repository) do
    biot_id = id(BiotId, 809)
    {:ok, host} = Host.context(biot_id)
    assert :ok = Host.run({:allocate, biot_id}, host)
    allocation = Journal.allocation(biot_id)
    assert :ok = Host.run({:initialize, allocation, repository}, host)
    allocation = Journal.allocation(biot_id)

    checkout = Paths.checkout(host.config, biot_id)
    assert {_, 0} = System.cmd("podman", ["unshare", "chown", "-R", "0:0", checkout])
    File.rm_rf!(checkout)
    assert {:lost, ^allocation} = Host.inspect_state(biot_id, host).data

    assert :ok = Host.run({:initialize, allocation, repository}, host)
    allocation = Journal.allocation(biot_id)
    path = Paths.biot(host.config, biot_id)
    File.chmod!(path, 0o000)

    assert {:unknown, ^allocation, %Biot.Node.InspectionFailure{reason: :denied}} =
             Host.inspect_state(biot_id, host).data

    File.chmod!(path, 0o700)
    cleanup_allocation(host, allocation)
  end

  defp decision(spec, host) do
    spec
    |> then(&Reconcile.next(&1, node_state(Host.inspect_state(spec.biot_id, host)), nil))
  end

  defp converge(spec, host, actions \\ [])

  defp converge(spec, host, actions) when length(actions) < 20 do
    inspection = Host.inspect_state(spec.biot_id, host)

    case Reconcile.next(spec, node_state(inspection), nil) do
      :settled ->
        {inspection, Enum.reverse(actions)}

      {:run, action} ->
        assert :ok = Host.run(action, host)
        converge(spec, host, [elem(action, 0) | actions])

      other ->
        flunk("reconciliation stopped at #{inspect(other)}")
    end
  end

  defp converge(_spec, _host, actions) do
    flunk("reconciliation exceeded its action limit: #{inspect(Enum.reverse(actions))}")
  end

  defp node_state(%Inspection{} = inspection) do
    inspection
    |> Map.from_struct()
    |> Map.merge(%{pending_exit: nil, failure: nil})
    |> then(&struct!(NodeState, &1))
  end

  defp execution(biot_id, environment_id, repository, selection, state, revision) do
    %ExecutionSpec{
      biot_id: biot_id,
      repository: repository,
      desired: %Desired{revision: revision, state: state, environment_id: environment_id},
      environment: %{id: environment_id, selection: selection}
    }
  end

  defp installed(%Inspection{installation: {:present, installation}}), do: installation

  defp bundle(host, environment_id) do
    assert {:ok, bundle} = HostEnvironment.bundle(host.config, environment_id)
    bundle
  end

  defp curl_executable(bundle) do
    environment = bundle.environment_file |> StorePath.to_string() |> File.read!()
    [path] = Regex.run(~r{/nix/store/[^\s:'"]*curl[^\s:'"]*/bin}, environment)
    Path.join(path, "curl")
  end

  defp container_curl(host, container, curl, method, path, body \\ nil) do
    arguments = [
      "exec",
      Names.container(container.incarnation_id),
      curl,
      "--fail",
      "--silent",
      "--show-error",
      "--max-time",
      "1",
      "--request",
      method
    ]

    arguments = if body, do: arguments ++ ["--data", body], else: arguments

    case Podman.run(host.config, arguments ++ ["http://127.0.0.1:8080#{path}"]) do
      {:ok, %Command.Result{status: status, stdout: output}} -> {output, status}
      {:error, _reason} -> {"", 1}
    end
  end

  defp container_address(host, container) do
    assert {:ok, %Command.Result{status: 0, stdout: output}} =
             Podman.run(host.config, [
               "inspect",
               "--format",
               "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
               Names.container(container.incarnation_id)
             ])

    String.trim(output)
  end

  defp container_reaches(host, container, curl, address) do
    match?(
      {:ok, %Command.Result{status: 0}},
      Podman.run(host.config, [
        "exec",
        Names.container(container.incarnation_id),
        curl,
        "--fail",
        "--silent",
        "--show-error",
        "--max-time",
        "2",
        "http://#{address}:8080/"
      ])
    )
  end

  defp start_foreign_container(host, allocation, installation, bundle, incarnation_id) do
    biot_id = allocation.biot_id
    foreign_owner = id(BiotId, 899)
    mapped_start = Allocation.subordinate_start(allocation, host.config.uid_range_base)
    mapping = "0:#{mapped_start}:#{allocation.uid_range.count}"

    volumes =
      ["--volume", "/nix/store:/nix/store:ro"] ++
        Enum.flat_map(Paths.mounts(host.config, biot_id), fn {source, target} ->
          ["--volume", "#{source}:#{target}:rw"]
        end)

    arguments =
      [
        "run",
        "--name",
        Names.container(incarnation_id),
        "--detach",
        "--read-only",
        "--rootfs",
        "--network",
        Names.network(allocation.network_id),
        "--uidmap",
        mapping,
        "--gidmap",
        mapping
      ] ++
        Names.label_arguments(foreign_owner, incarnation_id, installation.environment_id) ++
        volumes ++
        [Paths.rootfs(host.config, biot_id), StorePath.to_string(bundle.entrypoint)]

    assert {:ok, %Command.Result{status: 0}} = Podman.run(host.config, arguments)
    File.write!(Paths.container_identity(host.config, biot_id), "#{incarnation_id}\n")
  end

  defp remove_container(host, incarnation_id) do
    assert {:ok, %Command.Result{status: 0}} =
             Podman.run(host.config, ["rm", "--force", Names.container(incarnation_id)])
  end

  defp cleanup_allocation(host, allocation) do
    assert :ok = Host.run({:remove_data, allocation}, host)
    current = Journal.allocation(allocation.biot_id)
    assert :ok = Host.run({:release_allocation, current}, host)
  end

  defp selector(repository) do
    {:ok, selector} = SourceSelector.new(repository, "main")
    selector
  end

  defp served_repositories(root, sources) do
    served = Path.join(root, "served")
    File.mkdir_p!(served)

    Enum.each(sources, fn {name, source} ->
      bare = Path.join(served, "#{name}.git")
      git!(root, ["clone", "--quiet", "--bare", source, bare])
      git!(root, ["--git-dir", bare, "update-server-info"])
    end)

    cert = Path.join(root, "server.crt")
    key = Path.join(root, "server.key")

    assert {_, 0} =
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
                 cert,
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

    python = """
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

    server =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 1_024},
        args: ["-c", python, served, Integer.to_string(port_number), cert, key]
      ])

    assert_receive {^server, {:data, {:eol, "ready"}}}, 5_000

    repositories =
      Map.new(sources, fn {name, _source} ->
        {:ok, repository} =
          RepositorySource.parse("https://127.0.0.1:#{port_number}/#{name}.git")

        {name, repository}
      end)

    {repositories, server}
  end

  defp git_repository(root, name, content, filename \\ "default.nix") do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    File.write!(Path.join(path, filename), content)
    git!(path, ["init", "--quiet", "--initial-branch", "main"])
    git!(path, ["config", "user.name", "Biot test"])
    git!(path, ["config", "user.email", "test@example.test"])
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

  defp layer(project_root, name) do
    File.read!(Path.join(project_root, "nix/examples/stateful-counter/#{name}/default.nix"))
  end

  defp unused_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp eventually(fun, attempts \\ 80)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(250)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp controller_running?(biot_id) do
    Enum.any?(Controllers.running(), fn {running_id, _pid} -> running_id == biot_id end)
  end

  defp host_settings(data_root, project_root) do
    [
      data_root: data_root,
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
      host_command_timeout_ms: 1_200_000,
      host_command_max_output_bytes: 256_000,
      observation_interval_ms: 600_000,
      inspection_retry_ms: 600_000,
      retry_backoff_min_ms: 2_000,
      retry_backoff_max_ms: 8_000,
      controller_start_retry_ms: 1_000,
      container_events_retry_ms: 200
    ]
  end

  defp remove_all_test_containers(settings) do
    data_root = Keyword.fetch!(settings, :data_root)
    config_path = Path.join(data_root, "podman.conf")

    if File.exists?(config_path) do
      System.cmd("podman", ["--module", config_path, "rm", "--all", "--force"],
        stderr_to_stdout: true
      )
    end
  end

  defp temporary_directory(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp id(module, number) do
    value =
      "00000000-0000-4000-8000-#{number |> Integer.to_string() |> String.pad_leading(12, "0")}"

    {:ok, parsed} = module.parse(value)
    parsed
  end
end
