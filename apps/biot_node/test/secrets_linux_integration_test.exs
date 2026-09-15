defmodule Biot.Node.SecretsLinuxIntegrationTest do
  @moduledoc """
  Drives secrets, fetch credentials, and the credential wait against the real filesystem, real
  Podman user mapping, and a real private HTTPS Git host that refuses an unauthenticated fetch.
  """

  use ExUnit.Case, async: false

  alias Biot.Node.Controllers
  alias Biot.Node.DataRootLock
  alias Biot.Node.Host
  alias Biot.Node.Host.FetchCredentials
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.Setup
  alias Biot.Node.Journal
  alias Biot.Node.Journal.Migrator
  alias Biot.Node.Repo
  alias Biot.Node.SecretRequest
  alias Biot.Protocol.AuthorizationValue
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.ExecutionSpec
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SecretName
  alias Biot.Protocol.SecretValue
  alias Biot.Protocol.SourceSelector

  @moduletag :linux
  @moduletag :podman
  @moduletag timeout: 600_000

  @token "Bearer step18-token"
  # Long enough that a delivery can be queued while the clone that needs it is still in flight,
  # short enough that the racing test stays well inside its bound.
  @unauthorized_delay_ms 6_000

  setup_all do
    data_root = temporary_directory("biot-secrets-linux")
    repository_root = temporary_directory("biot-secrets-git")
    settings = host_settings(data_root)

    previous =
      Map.new(settings, fn {key, _value} -> {key, Application.get_env(:biot_node, key)} end)

    Enum.each(settings, fn {key, value} -> Application.put_env(:biot_node, key, value) end)

    start_supervised!({DataRootLock, data_root: data_root})
    assert :ignore = Setup.start_link([])
    start_supervised!(Repo)
    assert :ignore = Migrator.start_link([])

    {private, server, request_log} = private_git_host(repository_root)

    old_ssl = System.get_env("GIT_SSL_NO_VERIFY")
    System.put_env("GIT_SSL_NO_VERIFY", "true")

    on_exit(fn ->
      if Port.info(server), do: Port.close(server)
      :persistent_term.erase(Biot.Node.Host.Config)

      System.cmd("podman", ["unshare", "chown", "-R", "0:0", data_root], stderr_to_stdout: true)
      System.cmd("podman", ["unshare", "chmod", "-R", "u+rwX", data_root], stderr_to_stdout: true)
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

    {:ok, data_root: data_root, private: private, request_log: request_log}
  end

  test "a secret is published, replaced, listed, and removed with no temporary left behind" do
    {biot_id, host} = allocated(1_801)
    directory = Paths.secrets(host.config, biot_id)
    mapped_uid = Journal.allocation(biot_id).uid_range.start

    assert Host.serve(:list_secrets, host) == {:ok, []}

    assert Host.serve({:deliver_secret, name("DATABASE_URL"), secret("first\n")}, host) == :ok

    path = Path.join(directory, "DATABASE_URL")
    stat = File.stat!(path)
    assert Bitwise.band(stat.mode, 0o777) == 0o400
    assert stat.uid == mapped_uid
    assert File.ls!(directory) == ["DATABASE_URL"]

    # The file belongs to the allocation's user and to nobody else, so the node that wrote it
    # cannot read it back; only a reader inside that user's namespace can.
    assert File.read(path) == {:error, :eacces}
    assert read_as_owner(path) == "first\n"

    # The directory itself stays the node's, which is what lets the node publish into a directory
    # the container may only read.
    refute File.stat!(directory).uid == mapped_uid

    assert Host.serve({:deliver_secret, name("DATABASE_URL"), secret("second")}, host) == :ok
    assert read_as_owner(path) == "second"
    assert File.ls!(directory) == ["DATABASE_URL"]

    assert Host.serve({:deliver_secret, name("TOKEN"), secret(<<0xFF, 0xFE>>)}, host) == :ok
    assert read_as_owner(Path.join(directory, "TOKEN")) == <<0xFF, 0xFE>>

    assert Host.serve(:list_secrets, host) == {:ok, [name("DATABASE_URL"), name("TOKEN")]}

    assert Host.serve({:remove_secret, name("DATABASE_URL")}, host) == :ok
    assert Host.serve({:remove_secret, name("DATABASE_URL")}, host) == :ok
    assert Host.serve(:list_secrets, host) == {:ok, [name("TOKEN")]}
    assert Enum.sort(File.ls!(directory)) == ["TOKEN"]
  end

  test "a request after the allocation's data is removed answers no allocation and creates nothing" do
    {biot_id, host} = allocated(1_802)
    assert Host.serve({:deliver_secret, name("TOKEN"), secret("value")}, host) == :ok

    allocation = Journal.allocation(biot_id)
    assert :ok = Host.run({:remove_data, allocation}, host)

    root = Paths.biot(host.config, biot_id)
    refute File.exists?(Paths.secrets(host.config, biot_id))

    assert Host.serve({:deliver_secret, name("TOKEN"), secret("value")}, host) == :no_allocation
    assert Host.serve({:remove_secret, name("TOKEN")}, host) == :no_allocation
    assert Host.serve(:list_secrets, host) == :no_allocation

    assert Host.serve({:deliver_fetch_credential, source(), authorization()}, host) ==
             :no_allocation

    assert Host.serve({:remove_fetch_credential, source()}, host) == :no_allocation

    refute File.exists?(Paths.secrets(host.config, biot_id))
    refute File.exists?(Paths.fetch_credentials(host.config, biot_id))
    refute File.exists?(root)
  end

  test "a fetch credential is stored scoped, shared, and named by the include file" do
    {biot_id, host} = allocated(1_803)
    directory = Paths.fetch_credentials(host.config, biot_id)
    mapped_uid = Journal.allocation(biot_id).uid_range.start

    assert Host.serve({:deliver_fetch_credential, source(), authorization()}, host) == :ok

    fragment = Path.join(directory, FetchCredentials.fragment_name(source()))
    stat = File.stat!(fragment)
    assert Bitwise.band(stat.mode, 0o777) == 0o440
    assert stat.uid == mapped_uid

    content = File.read!(fragment)
    assert content =~ "[http \"https://host.test/org/private.git\"]"
    assert content =~ "extraHeader = \"Authorization: Bearer abc\""
    assert content =~ "followRedirects = false"

    allocation = Journal.allocation(biot_id)
    assert :ok = FetchCredentials.write_include(host.config, allocation)

    include = Path.join(directory, FetchCredentials.include_name())
    assert File.read!(include) == "[include]\n\tpath = #{Path.basename(fragment)}\n"

    # A relative include is what makes the same file graph mean the same thing to the node and to
    # the worker, which see this directory at different absolute paths.
    refute File.read!(include) =~ directory

    assert Host.serve({:remove_fetch_credential, source()}, host) == :ok
    assert Host.serve({:remove_fetch_credential, source()}, host) == :ok
    refute File.exists?(fragment)

    assert :ok = FetchCredentials.write_include(host.config, allocation)
    assert File.read!(include) == ""
  end

  test "a request for a biot with no controller is refused and starts nothing" do
    start_supervised!(Controllers)
    biot_id = id(BiotId, 1_804)

    request = SecretRequest.new("no-controller", :list_secrets, 5_000, self())
    assert Controllers.secret_request(biot_id, request) == :no_allocation

    refute Enum.any?(Controllers.running(), fn {running, _pid} -> running == biot_id end)
    refute_receive {:secret_result, "no-controller", _kind, _outcome}, 200
    stop_supervised!(Controllers)
  end

  test "a node checkout of a private repository waits for its credential", context do
    {biot_id, host} = allocated(1_805)
    allocation = Journal.allocation(biot_id)
    private = context.private

    assert Host.run({:initialize, allocation, private}, host) == {:waiting_for, private}
    refute File.exists?(Paths.checkout(host.config, biot_id))

    assert Host.serve({:deliver_fetch_credential, private, authorization(@token)}, host) == :ok
    assert Host.run({:initialize, allocation, private}, host) == :ok

    assert File.read!(Path.join(Paths.checkout(host.config, biot_id), "README.md")) ==
             "private layer content\n"

    # Removal prevents the next use; the checkout already taken is not undone.
    {other_id, other_host} = allocated(1_806)
    other_allocation = Journal.allocation(other_id)

    assert Host.serve({:deliver_fetch_credential, private, authorization(@token)}, other_host) ==
             :ok

    assert Host.serve({:remove_fetch_credential, private}, other_host) == :ok

    assert Host.run({:initialize, other_allocation, private}, other_host) ==
             {:waiting_for, private}
  end

  test "a credential delivered while the clone that needs it runs ends in one wake", context do
    start_supervised!(Controllers)
    biot_id = id(BiotId, 1_807)
    private = context.private
    before = unauthorized_count(context.request_log)

    assert {:ok, _intent} =
             Journal.put_intent(%BiotSpec{
               execution: execution(biot_id, private),
               access_revision: 1
             })

    assert :ok = Controllers.intent_changed(biot_id)

    # The clone is in flight once the host has seen the request it will refuse; delivering now is
    # the race the model's serialization rule is about.
    assert eventually(fn -> unauthorized_count(context.request_log) > before end)

    request =
      SecretRequest.new(
        "in-flight",
        {:deliver_fetch_credential, private, authorization(@token)},
        60_000,
        self()
      )

    assert Controllers.secret_request(biot_id, request) == :ok
    assert_receive {:secret_result, "in-flight", :fetch_credential, :ok}, 30_000

    {:ok, host} = Host.context(biot_id)

    assert eventually(fn ->
             File.exists?(Path.join(Paths.checkout(host.config, biot_id), "README.md"))
           end)

    retry = Journal.retry_state(biot_id)
    assert retry.waiting_for == nil

    # The waiting clone gave its attempt back, so the only attempt this stage holds is the clone
    # that ran after the credential arrived.
    assert retry.attempts[:initialize] == 1

    stop_supervised!(Controllers)
  end

  test "an expired request is dropped without a reply", context do
    start_supervised!(Controllers)
    biot_id = id(BiotId, 1_808)
    private = context.private
    before = unauthorized_count(context.request_log)

    assert {:ok, _intent} =
             Journal.put_intent(%BiotSpec{
               execution: execution(biot_id, private),
               access_revision: 1
             })

    assert :ok = Controllers.intent_changed(biot_id)
    assert eventually(fn -> unauthorized_count(context.request_log) > before end)

    expired = SecretRequest.new("expired", :list_secrets, 1, self())
    assert Controllers.secret_request(biot_id, expired) == :ok

    # The action in flight outlives the deadline, so the drain that follows it drops the request
    # rather than answering a caller the server has already released.
    refute_receive {:secret_result, "expired", _kind, _outcome}, 20_000

    stop_supervised!(Controllers)
  end

  # A file handed to the allocation's mapped user is readable only inside that user namespace;
  # `podman unshare` is the node's own way into it.
  defp read_as_owner(path) do
    {output, 0} = System.cmd("podman", ["unshare", "cat", "--", path])
    output
  end

  defp allocated(number) do
    biot_id = id(BiotId, number)
    {:ok, host} = Host.context(biot_id)
    assert :ok = Host.run({:allocate, biot_id}, host)
    {biot_id, host}
  end

  defp execution(biot_id, repository) do
    environment_id = id(EnvironmentId, 1_900)

    selection = %EnvironmentSelection{
      base_nixpkgs: SourceSelector.nixpkgs(),
      layers: []
    }

    %ExecutionSpec{
      biot_id: biot_id,
      repository: repository,
      desired: %Desired{revision: 1, state: :running, environment_id: environment_id},
      environment: %{id: environment_id, selection: selection}
    }
  end

  defp unauthorized_count(log) do
    case File.read(log) do
      {:ok, content} -> content |> String.split("authorization absent") |> length() |> Kernel.-(1)
      {:error, _reason} -> 0
    end
  end

  defp name(value) do
    {:ok, name} = SecretName.parse(value)
    name
  end

  defp secret(value) do
    {:ok, parsed} = SecretValue.parse(value, 1)
    parsed
  end

  defp authorization(value \\ "Bearer abc") do
    {:ok, parsed} = AuthorizationValue.parse(value, 1)
    parsed
  end

  defp source do
    {:ok, source} = RepositorySource.parse("https://host.test/org/private.git")
    source
  end

  defp id(module, number) do
    value =
      "00000000-0000-4000-8000-" <>
        (number |> Integer.to_string() |> String.pad_leading(12, "0"))

    {:ok, parsed} = module.parse(value)
    parsed
  end

  # One bare repository over TLS that answers 401 to every request without the exact authorization
  # header, and that holds an unauthorized request open long enough for a delivery to race it.
  defp private_git_host(root) do
    served = Path.join(root, "served")
    work = Path.join(root, "work")
    File.mkdir_p!(served)
    File.mkdir_p!(work)

    File.write!(Path.join(work, "README.md"), "private layer content\n")
    git!(work, ["init", "--quiet", "--initial-branch", "main"])
    git!(work, ["config", "user.name", "Biot test"])
    git!(work, ["config", "user.email", "test@example.test"])
    git!(work, ["add", "README.md"])
    git!(work, ["commit", "--quiet", "--message", "private"])
    git!(root, ["clone", "--quiet", "--bare", work, Path.join(served, "private.git")])

    cert = Path.join(root, "server.crt")
    key = Path.join(root, "server.key")
    log = Path.join(root, "requests.log")
    File.write!(log, "")

    {addresses, 0} = System.cmd("hostname", ["-I"], stderr_to_stdout: true)
    address = addresses |> String.split() |> hd()

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
                 "/CN=#{address}",
                 "-addext",
                 "subjectAltName=IP:#{address}"
               ],
               stderr_to_stdout: true
             )

    port_number = unused_port()

    server =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 2_048},
        args: [
          "-c",
          git_host_source(),
          served,
          Integer.to_string(port_number),
          cert,
          key,
          @token,
          log,
          Integer.to_string(@unauthorized_delay_ms)
        ]
      ])

    assert_receive {^server, {:data, {:eol, "ready"}}}, 10_000

    {:ok, private} =
      RepositorySource.parse("https://#{address}:#{port_number}/private.git")

    {private, server, log}
  end

  defp git_host_source do
    """
    import http.server, os, ssl, subprocess, sys, time, urllib.parse

    ROOT, PORT, CERT, KEY, EXPECTED, LOG, DELAY = sys.argv[1:8]

    def record(line):
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(line + "\\n")

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            return

        def do_GET(self):
            self.serve()

        def do_POST(self):
            self.serve()

        def serve(self):
            authorization = self.headers.get("Authorization")

            if authorization != EXPECTED:
                record("authorization absent")
                time.sleep(int(DELAY) / 1000.0)
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="biot"')
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                return

            record("authorization present")
            self.backend()

        def backend(self):
            parsed = urllib.parse.urlsplit(self.path)
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            environment = os.environ.copy()
            environment.update({
                "GIT_PROJECT_ROOT": ROOT,
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
                input=body,
                capture_output=True,
                env=environment,
            )
            headers, payload = process.stdout.split(b"\\r\\n\\r\\n", 1)
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
                self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
            self.close_connection = True

    server = http.server.ThreadingHTTPServer(("0.0.0.0", int(PORT)), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(CERT, KEY)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print("ready", flush=True)
    server.serve_forever()
    """
  end

  defp git!(path, arguments) do
    case System.cmd("git", arguments, cd: path, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git exited with #{status}: #{output}"
    end
  end

  defp unused_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp eventually(fun, attempts \\ 200)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp temporary_directory(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp host_settings(data_root) do
    [
      data_root: data_root,
      uid_range_base: 100_000,
      uid_range_count: 1_024,
      uid_range_limit: 165_536,
      git_executable: "git",
      podman_executable: "podman",
      podman_network_command: "slirp4netns",
      flock_executable: "flock",
      setsid_executable: "setsid",
      mkfifo_executable: "mkfifo",
      head_executable: "head",
      cat_executable: "cat",
      sleep_executable: "sleep",
      builder_image:
        "docker.io/nixos/nix@sha256:29fc5fe207f159ceb0143c25c19c774062fee02ce5eda118f3067547b3054894",
      binary_cache_urls: ["https://cache.nixos.org"],
      binary_cache_keys: [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      ],
      nixpkgs_repository: "https://github.com/NixOS/nixpkgs",
      nixpkgs_ref: "nixos-unstable",
      host_command_timeout_ms: 600_000,
      worker_timeout_ms: 600_000,
      host_command_max_output_bytes: 256_000,
      host_command_max_stderr_bytes: 256_000,
      runtime_log_max_bytes: 1_048_576,
      observation_interval_ms: 600_000,
      inspection_retry_ms: 600_000,
      retry_backoff_min_ms: 1_000,
      retry_backoff_max_ms: 4_000,
      controller_start_retry_ms: 1_000,
      container_events_retry_ms: 200
    ]
  end
end
