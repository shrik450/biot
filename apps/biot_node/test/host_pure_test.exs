defmodule Biot.Node.HostPureTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Biot.Node.ReconcileFixtures

  alias Biot.Node.Allocation
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.ContainerInspection
  alias Biot.Node.Host.DataInspection
  alias Biot.Node.Host.EnvironmentInspection
  alias Biot.Node.Host.Names
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Host.Paths
  alias Biot.Node.InspectionFailure
  alias Biot.Protocol.Platform

  describe "data inspection" do
    test "covers every data state from host facts" do
      fresh = fresh_allocation()
      complete = allocation()
      expected_marker = marker()
      present_mounts = List.duplicate({:present, :directory}, 3)

      assert {:uninitialized, ^fresh} =
               DataInspection.state(fresh, facts(:absent, [], :absent))

      assert {:present, ^complete, ^expected_marker} =
               DataInspection.state(
                 complete,
                 facts({:present, :directory}, present_mounts, {:present, to_string(marker())})
               )

      assert {:lost, ^complete} =
               DataInspection.state(complete, facts(:absent, present_mounts, :absent))

      assert {:lost, ^complete} =
               DataInspection.state(
                 complete,
                 facts({:present, :directory}, [:absent | present_mounts], {
                   :present,
                   to_string(marker())
                 })
               )

      assert {:lost, ^complete} =
               DataInspection.state(
                 complete,
                 facts(
                   {:present, :directory},
                   present_mounts,
                   {:present, to_string(marker()) <> "x"}
                 )
               )

      for {field, inspected} <- [
            {:allocation_directory, facts({:error, :eacces}, present_mounts, :absent)},
            {:mounts,
             facts({:present, :directory}, [{:error, :eperm} | present_mounts], {
               :present,
               to_string(marker())
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
  end

  describe "environment inspection" do
    test "covers every resolution state" do
      present = resolution(e1())
      lost = resolution(e2())
      unknown = resolution(e3())

      states =
        EnvironmentInspection.resolutions([
          {present, :not_needed},
          {lost, :absent},
          {unknown, {:error, :eacces}}
        ])

      assert states[e1()] == {:present, present}
      assert states[e2()] == {:lost, lost}
      assert {:unknown, ^unknown, %InspectionFailure{reason: :denied}} = states[e3()]
    end

    test "covers absent, present, and unknown prepared resources" do
      assert EnvironmentInspection.prepared([{e1(), :absent}]) == {:present, %{}}

      assert EnvironmentInspection.prepared([{e1(), {:present, artifact(e1())}}]) ==
               {:present, %{e1() => artifact(e1())}}

      assert {:unknown, %InspectionFailure{resource: :prepared, reason: :unreadable}} =
               EnvironmentInspection.prepared([
                 {e1(), {:error, {:unreadable, "the bundle is invalid"}}}
               ])
    end

    test "covers every installation state" do
      installation = installation(e1())

      assert EnvironmentInspection.installation(nil, :absent) == nil

      assert EnvironmentInspection.installation(
               installation,
               {:present, %{e1() => artifact(e1())}}
             ) == {:present, installation}

      assert EnvironmentInspection.installation(installation, {:present, %{}}) ==
               {:lost, installation}

      failure = inspection(:prepared, :timed_out)

      assert EnvironmentInspection.installation(installation, {:unknown, failure}) ==
               {:unknown, installation, failure}
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
      assert %Outcome{outcome: ^reason, diagnostic: "detail"} = Outcome.new(reason, "detail")
    end

    assert Outcome.from_reason(:enospc) == Outcome.new(:host_unavailable, "the disk is full")

    failure = %InspectionFailure{resource: :data, reason: :denied, detail: "cannot read"}
    assert Outcome.from_reason(failure) == Outcome.new(:host_unavailable, "cannot read")

    command = %Command.Result{status: 9, stdout: "out", stderr: "err"}
    assert Outcome.from_command(:build_failed, command) == Outcome.new(:build_failed, "err")
  end

  test "paths keep metadata outside the writable mounts" do
    config = config("/var/lib/biot")
    biot = biot_id()

    assert Paths.mounts(config, biot) == [
             {"/var/lib/biot/biots/#{biot}/checkout", "/biot/checkout"},
             {"/var/lib/biot/biots/#{biot}/home", "/biot/home"},
             {"/var/lib/biot/biots/#{biot}/service-data", "/biot/service-data"}
           ]

    assert Paths.marker(config, biot) == "/var/lib/biot/biots/#{biot}/marker"
    refute Paths.marker(config, biot) in Enum.map(Paths.mounts(config, biot), &elem(&1, 0))
  end

  test "names include every owner and stable resource identity" do
    labels = Names.label_arguments(biot_id(), incarnation(), e1())

    assert label_value(labels, Names.biot_label()) == to_string(biot_id())
    assert label_value(labels, Names.incarnation_label()) == to_string(incarnation())
    assert label_value(labels, Names.environment_label()) == to_string(e1())
    assert Names.network(allocation().network_id) == "biot-network-#{allocation().network_id}"
    assert Names.container(incarnation()) == "biot-#{incarnation()}"
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
      nix_executable: "nix",
      nix_instantiate_executable: "nix-instantiate",
      podman_executable: "podman",
      setsid_executable: "setsid",
      podman_network_command: "slirp4netns",
      nix_build_file: "/source/nix/build.nix",
      nix_pin_file: "/source/nix/pin.nix",
      nixpkgs_repository: "https://github.com/NixOS/nixpkgs",
      nixpkgs_ref: "nixos-unstable",
      command_timeout_ms: 1_000,
      command_max_output_bytes: 1_000,
      platform: platform
    )
  end
end
