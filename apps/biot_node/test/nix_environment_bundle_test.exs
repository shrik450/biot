defmodule Biot.Node.NixEnvironmentBundleTest do
  use ExUnit.Case, async: false

  alias Biot.Node.EnvironmentBundle
  alias Biot.Node.StorePath
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.PinnedSource
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector

  @moduletag :nix
  @moduletag timeout: 900_000

  @nixpkgs_revision "ac62194c3917d5f474c1a844b6fd6da2db95077d"
  @nixpkgs_nar_hash "sha256-16KkgfdYqjaeRGBaYsNrhPRRENs0qzkQVUooNHtoy2w="
  @wrong_nar_hash "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

  setup_all do
    project_root = Path.expand("../../..", __DIR__)
    root = temporary_directory("biot-step7-nix")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sources = %{
      base:
        git_source(
          root,
          "base",
          File.read!(
            Path.join(project_root, "nix/examples/stateful-counter/base-layer/default.nix")
          )
        ),
      service:
        git_source(
          root,
          "service",
          File.read!(
            Path.join(project_root, "nix/examples/stateful-counter/service-layer/default.nix")
          )
        ),
      conflict:
        git_source(
          root,
          "conflict",
          File.read!(Path.join(project_root, "nix/examples/conflicting-layer/default.nix"))
        ),
      home: git_source(root, "home", ~s({ biot.environment.HOME = "elsewhere"; }\n)),
      path: git_source(root, "path", ~s({ biot.environment.PATH = "/bin"; }\n)),
      term: git_source(root, "term", ~s({ biot.environment.TERM = "xterm"; }\n)),
      config_root:
        git_source(root, "config-root", ~s({ biot.environment.BIOT_CONFIG_ROOT = "/tmp"; }\n)),
      reserved_service:
        git_source(
          root,
          "reserved-service",
          ~s({ pkgs, ... }: { biot.services.biot-agent.command = [ "${pkgs.coreutils}/bin/true" ]; }\n)
        ),
      default: git_source(root, "default", "{ }\n"),
      directories:
        git_source(
          root,
          "directories",
          ~S'''
          { pkgs, ... }: {
            biot.services.checkout.command = [ "${pkgs.coreutils}/bin/pwd" ];
            biot.services.data = {
              command = [ "${pkgs.coreutils}/bin/pwd" ];
              directory = { root = "service_data"; path = "nested"; };
            };
          }
          '''
        )
    }

    manifest = manifest([sources.base.pin, sources.service.pin])
    manifest_path = write_manifest(root, "compatible", Manifest.encode(manifest))
    out_link = Path.join(root, "artifact")

    assert {output, 0} = nix_build(project_root, manifest_path, out_link)

    bundle_document = out_link |> Path.join("bundle.json") |> File.read!() |> Jason.decode!()
    assert {:ok, bundle} = EnvironmentBundle.parse(bundle_document), output

    {:ok,
     project_root: project_root,
     root: root,
     sources: sources,
     manifest: manifest,
     out_link: out_link,
     bundle_document: bundle_document,
     bundle: bundle}
  end

  test "the built bundle has exactly seven fields and six existing store paths", context do
    assert context.bundle_document["format"] == 1

    assert Map.keys(context.bundle_document) |> Enum.sort() ==
             ~w(closure_root config_root entrypoint environment_file format rootfs shell_entrypoint)

    paths = [
      context.bundle.closure_root,
      context.bundle.rootfs,
      context.bundle.entrypoint,
      context.bundle.shell_entrypoint,
      context.bundle.environment_file,
      context.bundle.config_root
    ]

    for path <- paths do
      value = StorePath.to_string(path)
      assert String.starts_with?(value, "/nix/store/")
      assert File.exists?(value), "missing #{value}"
    end

    assert File.read_link!(context.out_link) == StorePath.to_string(context.bundle.closure_root)
  end

  test "the closure contains the agent and the complete root filesystem", context do
    requisites = requisites(context.bundle)
    assert Enum.any?(requisites, &String.contains?(&1, "biot-agent-1"))

    rootfs = StorePath.to_string(context.bundle.rootfs)

    for entry <- [
          "bin/sh",
          "usr/bin/env",
          "etc/passwd",
          "etc/group",
          "etc/nsswitch.conf",
          "etc/hosts",
          "etc/hostname",
          "etc/resolv.conf",
          "biot/checkout",
          "biot/home",
          "biot/service-data",
          "biot/run",
          "biot/secrets",
          "nix/store",
          "tmp",
          "run"
        ] do
      assert File.exists?(Path.join(rootfs, entry)), "rootfs is missing #{entry}"
    end
  end

  test "service and shell entries load configuration before current secrets", context do
    requisites = requisites(context.bundle)
    service = executable_text(requisites, "biot-service-counter", "biot-service-counter")

    assert ordered?(service, [
             StorePath.to_string(context.bundle.environment_file),
             "export PORT=8080",
             "/biot/secrets/*"
           ])

    shell = executable_text(requisites, "biot-shell-command", "biot-shell-command")

    assert ordered?(shell, [
             StorePath.to_string(context.bundle.environment_file),
             "/biot/secrets/*"
           ])
  end

  test "the generated runner has one copy of each restart limit", context do
    runner = executable_text(requisites(context.bundle), "biot-run-counter", "biot-run-counter")

    for value <- [
          ~S|if [ "$attempt" -ge 5 ]|,
          ~S|if [ $(( SECONDS - started )) -ge 60 ]|,
          "delay=$(( 1 << (attempt - 1) ))",
          ~S|if [ "$delay" -gt 4 ]|,
          "exit 70"
        ] do
      assert length(:binary.matches(runner, value)) == 1, "#{inspect(value)} was not unique"
    end

    assert runner =~ "exhausted restart attempts"
  end

  test "compatible layers merge one environment definition", context do
    environment_file = StorePath.to_string(context.bundle.environment_file)

    definitions =
      environment_file
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "export BIOT_EXAMPLE="))

    assert length(definitions) == 1
    assert hd(definitions) =~ "stateful-counter"
  end

  test "conflicting layers fail with both source files", context do
    manifest_path =
      write_manifest(
        context.root,
        "conflict",
        context.sources
        |> then(&manifest([&1.base.pin, &1.conflict.pin]))
        |> Manifest.encode()
      )

    {output, status} = nix_build(context.project_root, manifest_path)

    assert status != 0
    assert output =~ "stateful-counter"
    assert output =~ "a-different-environment"

    source_files =
      ~r{/nix/store/[^\s'`]+-source/default\.nix}
      |> Regex.scan(output)
      |> List.flatten()
      |> Enum.uniq()

    assert length(source_files) >= 2, output
  end

  test "reserved shared environment variables name the option authors must use", context do
    for name <- [:home, :path, :term, :config_root] do
      manifest_path =
        write_manifest(
          context.root,
          "reserved-#{name}",
          context.sources
          |> Map.fetch!(name)
          |> then(&manifest([&1.pin]))
          |> Manifest.encode()
        )

      {output, status} = nix_build(context.project_root, manifest_path)

      assert status != 0
      assert output =~ String.upcase(to_string(name))
      assert output =~ "reserved"
      assert output =~ "default.nix"
    end
  end

  test "the reserved agent service name is rejected with its source", context do
    {output, status} = build_source(context, "reserved-service", context.sources.reserved_service)

    assert status != 0
    assert output =~ ~s(service name "biot-agent" is reserved)
    assert output =~ "default.nix"
  end

  test "service directories reject every unsafe path with its source", context do
    invalid = [
      "",
      "/tmp",
      "nested//path",
      "./nested",
      "nested/./path",
      "../path",
      "nested/../path"
    ]

    for {path, index} <- Enum.with_index(invalid) do
      source =
        git_source(
          context.root,
          "invalid-directory-#{index}",
          ~s({ pkgs, ... }: { biot.services.bad = { command = [ "${pkgs.coreutils}/bin/true" ]; directory.path = #{inspect(path)}; }; }\n)
        )

      {output, status} = build_source(context, "invalid-directory-#{index}", source)
      assert status != 0
      assert output =~ "directory.path"
      assert output =~ "default.nix"
    end
  end

  test "service directories default to checkout and resolve both roots", context do
    {bundle, _document} = build_bundle(context, "directories", [context.sources.directories.pin])
    requisites = requisites(bundle)
    checkout = executable_text(requisites, "biot-service-checkout", "biot-service-checkout")
    data = executable_text(requisites, "biot-service-data", "biot-service-data")

    assert checkout =~ "cd /biot/checkout/."
    assert data =~ "cd /biot/service-data/nested"
  end

  test "the shell defaults to bash and accepts a zsh override", context do
    {default_bundle, _document} =
      build_bundle(context, "default-shell", [context.sources.default.pin])

    default_shell =
      executable_text(requisites(default_bundle), "biot-shell-command", "biot-shell-command")

    configured_shell =
      executable_text(requisites(context.bundle), "biot-shell-command", "biot-shell-command")

    assert default_shell =~ "/bin/bash"
    assert configured_shell =~ "/bin/zsh"
  end

  test "a wrong layer NAR hash fails the build", context do
    source = context.sources.base
    wrong_pin = pin_git(source.url, source.revision, @wrong_nar_hash)

    manifest_path =
      write_manifest(context.root, "wrong-hash", manifest([wrong_pin]) |> Manifest.encode())

    {output, status} = nix_build(context.project_root, manifest_path)

    assert status != 0
    assert output =~ "NAR hash mismatch"
    assert output =~ @wrong_nar_hash
  end

  test "an extra manifest key is rejected with its name", context do
    manifest_path =
      write_manifest(
        context.root,
        "extra-key",
        context.manifest
        |> Manifest.encode()
        |> Map.put("unexpected_field", true)
      )

    {output, status} = nix_build(context.project_root, manifest_path)

    assert status != 0
    assert output =~ "unexpected_field"
  end

  test "a missing manifest key is rejected with its name", context do
    manifest_path =
      write_manifest(
        context.root,
        "missing-key",
        context.manifest
        |> Manifest.encode()
        |> Map.delete("layers")
      )

    {output, status} = nix_build(context.project_root, manifest_path)

    assert status != 0
    assert output =~ "layers"
  end

  test "the stateful service keeps private state across a container restart", context do
    podman_root = Path.join(context.root, "podman")
    checkout = Path.join(podman_root, "checkout")
    home = Path.join(podman_root, "home")
    service_data = Path.join(podman_root, "service-data")
    run = Path.join(podman_root, "run")
    secrets = Path.join(podman_root, "secrets")

    for path <- [checkout, home, service_data, run, secrets] do
      File.mkdir_p!(path)
    end

    name = "biot-step7-#{System.unique_integer([:positive])}"
    on_exit(fn -> System.cmd("podman", ["rm", "--force", name], stderr_to_stdout: true) end)

    entrypoint = StorePath.to_string(context.bundle.entrypoint)

    args = [
      "run",
      "--name",
      name,
      "--detach",
      "--read-only",
      "--tmpfs",
      "/tmp",
      "--tmpfs",
      "/run",
      "--network",
      "slirp4netns",
      "--publish",
      "127.0.0.1:18080:8080",
      "--volume",
      "/nix/store:/nix/store:ro",
      "--volume",
      "#{checkout}:/biot/checkout:rw",
      "--volume",
      "#{home}:/biot/home:rw",
      "--volume",
      "#{service_data}:/biot/service-data:rw",
      "--volume",
      "#{run}:/biot/run:rw",
      "--volume",
      "#{secrets}:/biot/secrets:ro",
      "--rootfs",
      StorePath.to_string(context.bundle.rootfs),
      entrypoint
    ]

    assert {output, 0} = System.cmd("podman", args, stderr_to_stdout: true)
    assert String.trim(output) != ""
    assert eventually(fn -> curl("GET", "/") == {"", 0} end)
    assert {_, 0} = curl("PUT", "/", "survives-restart")
    assert {"survives-restart", 0} = curl("GET", "/")
    assert {"State survives a container restart.\n", 0} = curl("GET", "/message")

    assert {_, 0} = System.cmd("podman", ["stop", name], stderr_to_stdout: true)
    assert {_, 0} = System.cmd("podman", ["start", name], stderr_to_stdout: true)
    assert eventually(fn -> curl("GET", "/") == {"survives-restart", 0} end)

    assert File.read!(Path.join(service_data, "counter/value")) == "survives-restart"

    {mounts, 0} =
      System.cmd(
        "podman",
        ["inspect", "--format", "{{range .Mounts}}{{println .Destination .RW}}{{end}}", name],
        stderr_to_stdout: true
      )

    assert mounts =~ "/nix/store false"
    assert mounts =~ "/biot/checkout true"
    assert mounts =~ "/biot/home true"
    assert mounts =~ "/biot/service-data true"
    assert mounts =~ "/biot/run true"
    assert mounts =~ "/biot/secrets false"
  end

  defp build_source(context, name, source) do
    manifest_path =
      write_manifest(context.root, name, manifest([source.pin]) |> Manifest.encode())

    nix_build(context.project_root, manifest_path)
  end

  defp build_bundle(context, name, pins) do
    manifest_path = write_manifest(context.root, name, manifest(pins) |> Manifest.encode())
    out_link = Path.join(context.root, "artifact-#{name}")
    assert {output, 0} = nix_build(context.project_root, manifest_path, out_link)
    document = out_link |> Path.join("bundle.json") |> File.read!() |> Jason.decode!()
    assert {:ok, bundle} = EnvironmentBundle.parse(document), output
    {bundle, document}
  end

  defp requisites(bundle) do
    closure = StorePath.to_string(bundle.closure_root)
    assert {output, 0} = System.cmd("nix-store", ["--query", "--requisites", closure])
    String.split(output)
  end

  defp executable_text(requisites, path_fragment, executable) do
    path =
      Enum.find(requisites, &String.contains?(Path.basename(&1), path_fragment)) ||
        flunk("#{path_fragment} is absent from the closure")

    File.read!(Path.join([path, "bin", executable]))
  end

  defp ordered?(text, fragments) do
    fragments
    |> Enum.map(fn fragment -> :binary.match(text, fragment) end)
    |> Enum.reduce_while(-1, fn
      {position, _length}, previous when position > previous -> {:cont, position}
      _missing_or_out_of_order, _previous -> {:halt, false}
    end)
    |> is_integer()
  end

  defp manifest(layers) do
    {:ok, base_nixpkgs} =
      PinnedSource.pin(SourceSelector.nixpkgs(), @nixpkgs_revision, @nixpkgs_nar_hash)

    Manifest.build(base_nixpkgs, layers, nil)
  end

  defp git_source(root, name, contents) do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "default.nix"), contents)

    git!(path, ["init", "--quiet"])
    git!(path, ["config", "user.name", "Biot test"])
    git!(path, ["config", "user.email", "test@example.test"])
    git!(path, ["add", "default.nix"])
    git!(path, ["commit", "--quiet", "--message", name])

    revision = git!(path, ["rev-parse", "HEAD"])
    url = "file://#{path}"
    nar_hash = source_nar_hash(url, revision)

    %{url: url, revision: revision, nar_hash: nar_hash, pin: pin_git(url, revision, nar_hash)}
  end

  defp git!(path, args) do
    case System.cmd("git", args, cd: path, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git exited with #{status}: #{output}"
    end
  end

  defp source_nar_hash(url, revision) do
    expression =
      "(builtins.fetchGit { url = #{Jason.encode!(url)}; rev = #{Jason.encode!(revision)}; }).narHash"

    case System.cmd(
           "nix",
           [
             "eval",
             "--extra-experimental-features",
             "nix-command",
             "--impure",
             "--raw",
             "--expr",
             expression
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "nix eval exited with #{status}: #{output}"
    end
  end

  defp pin_git(url, revision, nar_hash) do
    {:ok, selector} = SourceSelector.new(%RepositorySource{url: url}, "main")
    {:ok, pinned} = PinnedSource.pin(selector, revision, nar_hash)
    pinned
  end

  defp write_manifest(root, name, encoded) do
    path = Path.join(root, "#{name}.json")
    File.write!(path, Jason.encode!(encoded))
    path
  end

  defp nix_build(project_root, manifest_path, out_link \\ nil) do
    args = [
      "build",
      "--extra-experimental-features",
      "nix-command",
      "--file",
      Path.join(project_root, "nix/build.nix"),
      "--argstr",
      "manifest",
      manifest_path,
      "--argstr",
      "system",
      nix_system()
    ]

    args =
      if out_link do
        args ++ ["--out-link", out_link]
      else
        args ++ ["--no-link"]
      end

    System.cmd("nix", args, cd: project_root, stderr_to_stdout: true)
  end

  defp nix_system do
    case System.cmd(
           "nix",
           [
             "eval",
             "--extra-experimental-features",
             "nix-command",
             "--impure",
             "--raw",
             "--expr",
             "builtins.currentSystem"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "nix eval exited with #{status}: #{output}"
    end
  end

  defp curl(method, path, body \\ nil) do
    args = ["--fail", "--silent", "--show-error", "--max-time", "1", "--request", method]
    args = if body, do: args ++ ["--data", body], else: args
    System.cmd("curl", args ++ ["http://127.0.0.1:18080#{path}"], stderr_to_stdout: true)
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(200)
      eventually(check, attempts - 1)
    end
  end

  defp temporary_directory(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end
end
