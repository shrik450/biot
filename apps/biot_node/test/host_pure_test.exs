defmodule Biot.Node.HostPureTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Biot.Node.ReconcileFixtures

  alias Biot.Node.Allocation
  alias Biot.Node.Diagnostic
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.ContainerInspection
  alias Biot.Node.Host.DataInspection
  alias Biot.Node.Host.Diagnostic, as: HostDiagnostic
  alias Biot.Node.Host.EnvironmentInspection
  alias Biot.Node.Host.Git
  alias Biot.Node.Host.Names
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.PrivateStore
  alias Biot.Node.Host.StagedInputs
  alias Biot.Node.Host.Worker.Layout
  alias Biot.Node.InspectionFailure
  alias Biot.Node.Journal.Ecto.Attempts
  alias Biot.Node.StorePath
  alias Biot.Protocol.Platform
  alias Biot.Protocol.RepositorySource

  describe "data inspection" do
    test "covers every data state from host facts" do
      fresh = fresh_allocation()
      complete = allocation()
      present_mounts = List.duplicate({:present, :directory}, 3)

      assert {:uninitialized, ^fresh} =
               DataInspection.state(fresh, facts(:absent, [], :absent))

      assert {:present, ^complete} =
               DataInspection.state(
                 complete,
                 facts({:present, :directory}, present_mounts, {:present, to_string(biot_id())})
               )

      assert {:lost, ^complete} =
               DataInspection.state(complete, facts(:absent, present_mounts, :absent))

      assert {:lost, ^complete} =
               DataInspection.state(
                 complete,
                 facts({:present, :directory}, [:absent | present_mounts], {
                   :present,
                   to_string(biot_id())
                 })
               )

      assert {:lost, ^complete} =
               DataInspection.state(
                 complete,
                 facts(
                   {:present, :directory},
                   present_mounts,
                   {:present, "not-a-biot-id"}
                 )
               )

      for {field, inspected} <- [
            {:allocation_directory, facts({:error, :eacces}, present_mounts, :absent)},
            {:mounts,
             facts({:present, :directory}, [{:error, :eperm} | present_mounts], {
               :present,
               to_string(biot_id())
             })},
            {:marker, facts({:present, :directory}, present_mounts, {:error, :eio})}
          ] do
        assert {:unknown, ^complete, %InspectionFailure{resource: :data}} =
                 DataInspection.state(complete, inspected),
               "#{field} inspection was not unknown"
      end
    end

    test "an uninitialized allocation still reports an unreadable directory" do
      fresh = fresh_allocation()

      assert {:unknown, ^fresh, %InspectionFailure{reason: :denied}} =
               DataInspection.state(fresh, facts({:error, :eacces}, [], :absent))
    end

    test "a marker for another biot is lost" do
      complete = allocation()
      present_mounts = List.duplicate({:present, :directory}, 3)

      assert DataInspection.state(
               complete,
               facts(
                 {:present, :directory},
                 present_mounts,
                 {:present, to_string(other_biot_id())}
               )
             ) == {:lost, complete}
    end
  end

  describe "environment inspection" do
    test "covers every resolution state" do
      present = resolution(e1())
      lost = resolution(e2())

      states =
        EnvironmentInspection.resolutions([
          {present, :present},
          {lost, :absent}
        ])

      assert states[e1()] == {:present, present}
      assert states[e2()] == {:lost, lost}
    end

    test "covers absent, present, and unknown prepared resources" do
      assert EnvironmentInspection.prepared([{e1(), :absent}]) == %{e1() => :absent}

      assert EnvironmentInspection.prepared([{e1(), {:present, artifact(e1())}}]) ==
               %{e1() => {:present, artifact(e1())}}

      environment_id = e1()

      assert %{
               ^environment_id =>
                 {:unknown, %InspectionFailure{resource: :prepared, reason: :unreadable}}
             } =
               EnvironmentInspection.prepared([
                 {e1(), {:error, {:unreadable, "the bundle is invalid"}}}
               ])
    end

    test "covers every installation state" do
      installation = installation(e1())

      assert EnvironmentInspection.installation(nil, :absent) == nil

      assert EnvironmentInspection.installation(
               installation,
               %{e1() => {:present, artifact(e1())}}
             ) == {:present, installation}

      assert EnvironmentInspection.installation(installation, %{}) ==
               {:lost, installation}

      failure = inspection(:prepared, :timed_out)

      assert EnvironmentInspection.installation(installation, %{e1() => {:unknown, failure}}) ==
               {:unknown, installation, failure}

      assert EnvironmentInspection.installation(
               installation,
               %{e1() => {:present, artifact(e2())}, e2() => {:present, artifact(e1())}}
             ) == {:lost, installation}
    end
  end

  describe "container inspection" do
    test "parses real Podman inspect shapes for running and exited containers" do
      assert {:ok, %{state: :running}} = ContainerInspection.parse(podman_inspection(true, 0))

      assert {:ok, %{state: {:exited, 137}}} =
               ContainerInspection.parse(podman_inspection(false, 137))
    end

    test "rejects each missing required Podman field" do
      document = podman_inspection(true, 0)
      labels = document["Config"]["Labels"]

      invalid = [
        Map.delete(document, "Config"),
        Map.delete(document, "State"),
        put_in(document, ["Config"], Map.delete(document["Config"], "Labels")),
        put_in(document, ["State"], Map.delete(document["State"], "Running"))
      ]

      invalid =
        invalid ++
          Enum.map(
            [Names.biot_label(), Names.incarnation_label(), Names.environment_label()],
            &put_in(document, ["Config", "Labels"], Map.delete(labels, &1))
          )

      assert Enum.all?(invalid, &(ContainerInspection.parse(&1) == {:error, :invalid_format}))
    end

    property "returns a tagged result for random maps" do
      check all(value <- StreamData.map_of(StreamData.term(), StreamData.term(), max_length: 12)) do
        result = ContainerInspection.parse(value)
        assert match?({:ok, _container}, result) or result == {:error, :invalid_format}
      end
    end
  end

  test "outcome accepts every retry reason without changing it" do
    reasons = [
      :host_unavailable,
      {:container_exited, 137},
      :invalid_source,
      :resolution_failed,
      :build_failed,
      :invalid_configuration,
      :lost_data,
      :ownership_mismatch
    ]

    for reason <- reasons do
      diagnostic = Diagnostic.text("detail")
      assert %Outcome{outcome: ^reason, diagnostic: ^diagnostic} = Outcome.new(reason, diagnostic)
    end

    assert Outcome.from_reason(:enospc) ==
             Outcome.new(:host_unavailable, Diagnostic.text("the disk is full"))

    failure = %InspectionFailure{
      resource: :data,
      reason: :denied,
      detail: Diagnostic.text("cannot read")
    }

    assert Outcome.from_reason(failure) ==
             Outcome.new(:host_unavailable, Diagnostic.text("cannot read"))

    command = command_result(stderr: "err")

    assert Outcome.from_command(:build_failed, command) ==
             Outcome.new(:build_failed, {"err", false})
  end

  test "diagnostic text marks literal text as complete" do
    assert Diagnostic.text("detail") == {"detail", false}
  end

  test "host diagnostics choose stderr and the matching truncation flag" do
    cases = [
      {command_result(stdout: "out", stderr: "err"), {"err", false}},
      {command_result(stdout: "out", stderr: "err", stderr_truncated: true), {"err", true}},
      {command_result(stdout: "out", stdout_truncated: true), {"out", true}},
      {command_result(stdout: "out"), {"out", false}}
    ]

    for {result, expected} <- cases do
      assert HostDiagnostic.from_command(result) == expected
    end
  end

  test "paths keep runtime and build storage under the Biot" do
    config = config("/var/lib/biot")
    biot = biot_id()

    assert Paths.runtime_mounts(config, biot) == [
             {"/var/lib/biot/biots/#{biot}/checkout", "/biot/checkout", :rw},
             {"/var/lib/biot/biots/#{biot}/store/nix/store", "/nix/store", :ro},
             {"/var/lib/biot/biots/#{biot}/home", "/biot/home", :rw},
             {"/var/lib/biot/biots/#{biot}/service-data", "/biot/service-data", :rw},
             {"/var/lib/biot/biots/#{biot}/run", "/biot/run", :rw},
             {"/var/lib/biot/biots/#{biot}/secrets", "/biot/secrets", :ro}
           ]

    root = Paths.biot(config, biot)

    assert Enum.all?(
             [
               Paths.store_root(config, biot),
               Paths.store(config, biot),
               Paths.scratch(config, biot),
               Paths.build_support(config, biot),
               Paths.environments(config, biot),
               Paths.environment(config, biot, e1()),
               Paths.staged(config, biot, e1()),
               Paths.environment_root(config, biot, e1())
             ],
             &String.starts_with?(&1, root <> "/")
           )

    refute Paths.environments(config, biot) in Paths.allocation_owned_directories(config, biot)

    assert Paths.marker(config, biot) == "/var/lib/biot/biots/#{biot}/marker"

    refute Paths.marker(config, biot) in Enum.map(
             Paths.runtime_mounts(config, biot),
             &elem(&1, 0)
           )
  end

  describe "staged inputs" do
    test "parse accepts the complete closed pins document" do
      assert {:ok, staged} = StagedInputs.parse(staged_document())

      assert Enum.map(StagedInputs.entries(staged), &elem(&1, 0)) == [
               "build-support",
               "nixpkgs",
               "layer-0"
             ]
    end

    test "parse rejects every missing required key" do
      document = staged_document()

      invalid = [
        Map.delete(document, "build_support"),
        Map.delete(document, "base_nixpkgs"),
        Map.delete(document, "layers"),
        put_in(document, ["build_support"], Map.delete(document["build_support"], "store_path")),
        put_in(document, ["build_support"], Map.delete(document["build_support"], "nar_hash")),
        put_in(document, ["base_nixpkgs"], Map.delete(document["base_nixpkgs"], "revision")),
        put_in(document, ["base_nixpkgs"], Map.delete(document["base_nixpkgs"], "store_path")),
        put_in(document, ["base_nixpkgs"], Map.delete(document["base_nixpkgs"], "nar_hash")),
        update_in(document, ["layers"], fn [layer] -> [Map.delete(layer, "revision")] end),
        update_in(document, ["layers"], fn [layer] -> [Map.delete(layer, "store_path")] end),
        update_in(document, ["layers"], fn [layer] -> [Map.delete(layer, "nar_hash")] end)
      ]

      assert Enum.all?(invalid, &(StagedInputs.parse(&1) == {:error, :invalid_format}))
    end

    test "parse rejects extra keys, non-store paths, and invalid NAR hashes" do
      document = staged_document()

      invalid = [
        Map.put(document, "extra", true),
        put_in(document, ["build_support", "extra"], true),
        put_in(document, ["base_nixpkgs", "extra"], true),
        update_in(document, ["layers"], fn [layer] -> [Map.put(layer, "extra", true)] end),
        put_in(document, ["build_support", "store_path"], "/tmp/support"),
        put_in(document, ["base_nixpkgs", "nar_hash"], "not-a-nar-hash"),
        update_in(document, ["layers"], fn [layer] ->
          [Map.put(layer, "nar_hash", "sha256-short")]
        end)
      ]

      assert Enum.all?(invalid, &(StagedInputs.parse(&1) == {:error, :invalid_format}))
    end

    test "manifest rejects a layer count that differs from the selection" do
      assert {:ok, staged} = StagedInputs.parse(staged_document())
      assert StagedInputs.manifest(staged, selection()) == {:error, :invalid_format}
    end

    property "parse is total over random maps and binaries" do
      values =
        StreamData.one_of([
          StreamData.binary(max_length: 512),
          StreamData.map_of(StreamData.term(), StreamData.term(), max_length: 12)
        ])

      check all(value <- values) do
        assert match?({:ok, %StagedInputs{}}, StagedInputs.parse(value)) or
                 StagedInputs.parse(value) == {:error, :invalid_format}
      end
    end
  end

  test "worker layout grants each phase only its required mounts" do
    config = config("/var/lib/biot")
    biot = biot_id()
    env = e1()
    staged = [{"layer-0", "layer", "/private/store/layer"}]

    common = [
      {Paths.store_root(config, biot), "/biot/store", :rw},
      {Paths.scratch(config, biot), "/build", :rw},
      {Paths.worker_nix_config(config), "/etc/nix/nix.conf", :ro}
    ]

    assert Layout.mounts(config, biot, {:fetch, env}) == [
             {Paths.environment(config, biot, env), Layout.environment(env), :rw},
             {Paths.build_support(config, biot), Layout.build_support(), :ro}
             | common
           ]

    assert Layout.mounts(config, biot, {:build, env, staged}) == [
             {Paths.environment(config, biot, env), Layout.environment(env), :rw},
             {"/private/store/layer", Layout.staged_input("layer-0", "layer"), :ro}
             | common
           ]

    assert Layout.mounts(config, biot, :collect) == [
             {Paths.environments(config, biot), "/biot/environments", :ro}
             | common
           ]
  end

  test "worker layout fixes the environment, tmpfs, and logical store" do
    assert Layout.variables() == [
             {"NIX_PATH", ""},
             {"TMPDIR", "/build"},
             {"HOME", "/build/home"},
             {"XDG_CACHE_HOME", "/build/cache"}
           ]

    assert Layout.image_tmpfs() == ["/tmp", "/root", "/var", "/nix/var"]
    assert Layout.store_arguments() == ["--store", "/biot/store"]
  end

  test "private store maps logical paths below the allocation store root" do
    config = config("/var/lib/biot")
    {:ok, store_path} = StorePath.parse(store_path("bundle"))

    assert PrivateStore.host_path(config, biot_id(), store_path) ==
             "/var/lib/biot/biots/#{biot_id()}/store/nix/store/#{Path.basename(store_path("bundle"))}"
  end

  test "Git hardening and clone arguments have one exact shape" do
    config = config("/var/lib/biot")
    {:ok, repository} = RepositorySource.parse("https://example.com/project.git")

    assert Git.environment() == [
             {"GIT_ALLOW_PROTOCOL", "https"},
             {"GIT_CONFIG_NOSYSTEM", "1"},
             {"GIT_CONFIG_GLOBAL", "/dev/null"},
             {"GIT_TERMINAL_PROMPT", "0"},
             {"GIT_ASKPASS", ""},
             {"SSH_ASKPASS", ""}
           ]

    assert Git.clone_arguments(config, repository, "/checkout") == [
             "-c",
             "credential.helper=",
             "-c",
             "submodule.recurse=false",
             "clone",
             "--no-recurse-submodules",
             "--template",
             Paths.git_template(config),
             "--",
             "https://example.com/project.git",
             "/checkout"
           ]
  end

  test "names include every owner and stable resource identity" do
    labels = Names.label_arguments(biot_id(), incarnation(), e1())

    assert label_value(labels, Names.biot_label()) == to_string(biot_id())
    assert label_value(labels, Names.incarnation_label()) == to_string(incarnation())
    assert label_value(labels, Names.environment_label()) == to_string(e1())
    assert Names.network(allocation().network_id) == "biot-network-#{allocation().network_id}"
    assert Names.container(incarnation()) == "biot-#{incarnation()}"
  end

  test "names parse the owner label" do
    assert Names.owner(%{Names.biot_label() => to_string(biot_id())}) == {:ok, biot_id()}

    assert Names.owner(%{Names.biot_label() => "not-a-biot-id"}) ==
             {:error, :invalid_format}

    assert Names.owner(%{}) == {:error, :invalid_format}
  end

  describe "journal attempt counts" do
    test "cast and dump accept stage maps with positive counts" do
      attempts = %{allocate: 1, prepare: 3}

      assert Attempts.cast(attempts) == {:ok, attempts}
      assert Attempts.cast(%{"allocate" => 1, "prepare" => 3}) == {:ok, attempts}
      assert Attempts.dump(attempts) == {:ok, %{"allocate" => 1, "prepare" => 3}}
      assert Attempts.load(%{"allocate" => 1, "prepare" => 3}) == {:ok, attempts}
    end

    test "cast and dump reject invalid maps and non-maps" do
      invalid = [
        %{:not_a_stage => 1},
        %{"not_a_stage" => 1},
        %{allocate: 0},
        %{allocate: -1},
        %{allocate: 1.5},
        %{allocate: "1"},
        nil,
        [],
        :attempts,
        1
      ]

      for value <- invalid do
        assert Attempts.cast(value) == :error, "cast accepted #{inspect(value)}"
        assert Attempts.dump(value) == :error, "dump accepted #{inspect(value)}"
      end
    end

    test "load raises for corrupt stored values" do
      for value <- [
            %{"not_a_stage" => 1},
            %{"allocate" => 0},
            %{"allocate" => -1},
            %{"allocate" => 1.5},
            nil,
            []
          ] do
        assert_raise ArgumentError, fn -> Attempts.load(value) end
      end
    end
  end

  test "the subordinate range starts after Podman's root mapping" do
    assert Allocation.subordinate_start(fresh_allocation(), 500_000) == 1

    assert Allocation.subordinate_start(
             %{fresh_allocation() | uid_range: %{start: 501_024, count: 1_024}},
             500_000
           ) == 1_025
  end

  defp facts(directory, mounts, marker) do
    %{allocation_directory: directory, mounts: mounts, marker: marker}
  end

  defp podman_inspection(running, exit_code) do
    %{
      "Config" => %{
        "Labels" => %{
          Names.biot_label() => to_string(biot_id()),
          Names.incarnation_label() => to_string(incarnation()),
          Names.environment_label() => to_string(e1())
        }
      },
      "State" => %{"Running" => running, "ExitCode" => exit_code},
      "Id" => String.duplicate("a", 64),
      "Name" => Names.container(incarnation())
    }
  end

  defp label_value(arguments, key) do
    arguments
    |> Enum.chunk_every(2)
    |> Enum.find_value(fn ["--label", value] ->
      case String.split(value, "=", parts: 2) do
        [^key, label] -> label
        _other -> nil
      end
    end)
  end

  defp config(data_root) do
    {:ok, platform} = Platform.parse("x86_64-linux")

    struct!(Config,
      data_root: data_root,
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
      build_support_dir: "/source",
      binary_cache_urls: ["https://cache.example.test"],
      binary_cache_keys: ["cache.example.test:key"],
      nixpkgs_repository: "https://github.com/NixOS/nixpkgs",
      nixpkgs_ref: "nixos-unstable",
      command_timeout_ms: 1_000,
      worker_timeout_ms: 2_000,
      command_max_output_bytes: 1_000,
      command_max_stderr_bytes: 1_000,
      runtime_log_max_bytes: 1_000,
      platform: platform
    )
  end

  defp command_result(overrides) do
    struct!(
      %Command.Result{
        status: 9,
        stdout: "out",
        stderr: "",
        stdout_truncated: false,
        stderr_truncated: false
      },
      overrides
    )
  end

  defp staged_document do
    %{
      "build_support" => %{"store_path" => store_path("support"), "nar_hash" => nar_hash(1)},
      "base_nixpkgs" => %{
        "store_path" => store_path("nixpkgs"),
        "nar_hash" => nar_hash(2),
        "revision" => String.duplicate("a", 40)
      },
      "layers" => [
        %{
          "store_path" => store_path("layer"),
          "nar_hash" => nar_hash(3),
          "revision" => String.duplicate("b", 40)
        }
      ]
    }
  end

  defp store_path(name), do: "/nix/store/#{String.duplicate("a", 32)}-#{name}"
  defp nar_hash(byte), do: "sha256-" <> Base.encode64(:binary.copy(<<byte>>, 32))
end
