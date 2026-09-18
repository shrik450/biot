defmodule Biot.Node.SecretsLinuxIntegrationTest do
  @moduledoc """
  Drives secrets, fetch credentials, and the credential wait against the real filesystem, real
  Podman user mapping, and a real private HTTPS Git host that refuses an unauthenticated fetch.
  """

  use ExUnit.Case, async: false

  alias Biot.Node.Controllers
  alias Biot.Node.DataRootLock
  alias Biot.Node.GitHostFixture
  alias Biot.Node.Host
  alias Biot.Node.Host.FetchCredentials
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.Setup
  alias Biot.Node.Journal
  alias Biot.Node.Journal.Migrator
  alias Biot.Node.Repo
  alias Biot.Node.RetryState
  alias Biot.Node.SecretRequest
  alias Biot.Node.TestHostRange
  alias Biot.Protocol.AuthorizationValue
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.Desired
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.ExecutionSpec
  alias Biot.Protocol.Failure
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
    data_root = node_directory("biot-secrets-linux")
    repository_root = temporary_directory("biot-secrets-git")
    runtime_root = node_directory("biot-rt")
    settings = host_settings(data_root, runtime_root)

    previous =
      Map.new(settings, fn {key, _value} -> {key, Application.get_env(:biot_node, key)} end)

    Enum.each(settings, fn {key, value} -> Application.put_env(:biot_node, key, value) end)

    start_supervised!({DataRootLock, data_root: data_root})
    assert :ignore = Setup.start_link([])
    start_supervised!(Repo)
    assert :ignore = Migrator.start_link([])

    git_host = private_git_host(repository_root)
    private = GitHostFixture.repository_source(git_host, "private")

    old_ssl = System.get_env("GIT_SSL_NO_VERIFY")
    System.put_env("GIT_SSL_NO_VERIFY", "true")

    on_exit(fn ->
      :persistent_term.erase(Biot.Node.Host.Config)

      for root <- [data_root, runtime_root] do
        System.cmd("podman", ["unshare", "chown", "-R", "0:0", root], stderr_to_stdout: true)
        System.cmd("podman", ["unshare", "chmod", "-R", "u+rwX", root], stderr_to_stdout: true)
        File.rm_rf!(root)
      end

      File.rm_rf!(repository_root)

      if old_ssl,
        do: System.put_env("GIT_SSL_NO_VERIFY", old_ssl),
        else: System.delete_env("GIT_SSL_NO_VERIFY")

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:biot_node, key)
        {key, value} -> Application.put_env(:biot_node, key, value)
      end)
    end)

    {:ok, data_root: data_root, private: private, git_host: git_host}
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

  test "a source that refuses a delivered credential is an invalid source, not a wait", context do
    {biot_id, host} = allocated(1_810)
    allocation = Journal.allocation(biot_id)
    private = context.private

    # With no credential held, the node has nothing to offer this source, so it waits for one.
    assert Host.run({:initialize, allocation, private}, host) == {:waiting_for, private}

    # The source refuses the credential that was delivered. The node asked for one, got it, and it
    # did not work, so a wait would tell the person who just delivered it to deliver it again with
    # nothing else coming. It is an invalid source instead, and the diagnostic names the source the
    # bounded failure message cannot.
    assert Host.serve({:deliver_fetch_credential, private, authorization("Bearer refused")}, host) ==
             :ok

    assert {:error, %Outcome{outcome: {:credential_refused, ^private}, diagnostic: diagnostic}} =
             Host.run({:initialize, allocation, private}, host)

    {text, _truncated} = diagnostic
    assert text =~ RepositorySource.to_string(private)
  end

  test "a credential delivered while the clone that needs it runs ends in one wake", context do
    start_supervised!(Controllers)
    biot_id = id(BiotId, 1_807)
    private = context.private
    before = GitHostFixture.unauthorized_count(context.git_host)

    assert {:ok, _intent} =
             Journal.put_intent(%BiotSpec{
               execution: execution(biot_id, private),
               access_revision: 1
             })

    assert :ok = Controllers.intent_changed(biot_id)

    # The clone is in flight once the host has seen the request it will refuse; delivering now is
    # the race the model's serialization rule is about.
    assert eventually(fn -> GitHostFixture.unauthorized_count(context.git_host) > before end)

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

  test "a second delivery clears a refused credential's failure and lets the biot converge",
       context do
    start_supervised!(Controllers)
    biot_id = id(BiotId, 1_811)
    private = context.private

    assert {:ok, _intent} =
             Journal.put_intent(%BiotSpec{
               execution: execution(biot_id, private),
               access_revision: 1
             })

    assert :ok = Controllers.intent_changed(biot_id)

    # The clone has no credential, so the biot waits for one and spends nothing on the wait.
    assert eventually(fn ->
             match?(
               %RetryState{waiting_for: {:fetch_credential, ^private}},
               Journal.retry_state(biot_id)
             )
           end)

    assert RetryState.attempts(Journal.retry_state(biot_id), :initialize) == 0

    # A credential is delivered and the source refuses it. That is a failure a person has to
    # answer, not a wait, and it spends the attempt the wait gave back.
    assert :ok = deliver(biot_id, "refused", private, authorization("Bearer refused"))

    assert eventually(fn ->
             match?(
               %RetryState{waiting_for: nil, failure: %Failure{code: :invalid_source}},
               Journal.retry_state(biot_id)
             )
           end)

    refused = Journal.retry_state(biot_id)
    assert refused.failure.retry == :after_change
    # The refusal spends the attempt the wait gave back, which is what bounds repetition: a wait
    # returns the attempt and a refusal does not.
    assert RetryState.attempts(refused, :initialize) >= 1

    # The wait is gone, so delivering a credential is now the only thing that can clear the
    # failure. Without that, the biot stays failed until its spec changes.
    assert :ok = deliver(biot_id, "accepted", private, authorization(@token))

    {:ok, host} = Host.context(biot_id)

    assert eventually(fn ->
             File.exists?(Path.join(Paths.checkout(host.config, biot_id), "README.md"))
           end)

    converged = Journal.retry_state(biot_id)
    assert converged.failure == nil
    # Clearing the failure does not clear the attempts, so the work the accepted credential ran is
    # counted against the budget too.
    assert RetryState.attempts(converged, :initialize) >
             RetryState.attempts(refused, :initialize)

    stop_supervised!(Controllers)
  end

  test "an expired request is dropped without a reply", context do
    start_supervised!(Controllers)
    biot_id = id(BiotId, 1_808)
    private = context.private
    before = GitHostFixture.unauthorized_count(context.git_host)

    assert {:ok, _intent} =
             Journal.put_intent(%BiotSpec{
               execution: execution(biot_id, private),
               access_revision: 1
             })

    assert :ok = Controllers.intent_changed(biot_id)
    assert eventually(fn -> GitHostFixture.unauthorized_count(context.git_host) > before end)

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

  defp deliver(biot_id, request_id, source, value) do
    request =
      SecretRequest.new(request_id, {:deliver_fetch_credential, source, value}, 60_000, self())

    assert Controllers.secret_request(biot_id, request) == :ok
    assert_receive {:secret_result, ^request_id, :fetch_credential, :ok}, 30_000
    :ok
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
    address = GitHostFixture.address()

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

    GitHostFixture.start(served,
      certificate: cert,
      key: key,
      authorization: @token,
      unauthorized_delay_ms: @unauthorized_delay_ms
    )
  end

  defp git!(path, arguments) do
    case System.cmd("git", arguments, cd: path, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git exited with #{status}: #{output}"
    end
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

  # Both of a node's roots have to be somewhere its containers can reach, and its runtime root has
  # to be short as well. `BiotTest.Temp.node_root/1` says why the system temp root is neither.
  defp node_directory(prefix) do
    path = BiotTest.Temp.node_root(prefix)
    File.mkdir_p!(path)
    path
  end

  defp temporary_directory(prefix) do
    path = BiotTest.Temp.directory(prefix)
    File.mkdir_p!(path)
    path
  end

  defp host_settings(data_root, runtime_root) do
    {uid_start, uid_count} = TestHostRange.subordinate_ids()

    [
      data_root: data_root,
      runtime_root: runtime_root,
      uid_range_base: uid_start,
      uid_range_count: 1_024,
      uid_range_limit: uid_start + uid_count,
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
