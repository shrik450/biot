defmodule Biot.Node.Host.Setup do
  @moduledoc """
  Creates the node-wide host layout after the data-root lock is held, and refuses to start a node
  whose host cannot give a build worker a working Nix sandbox.

  The sandbox check is a real build in a real worker, not a capability test, because Nix falls
  back to building without a sandbox when it can and reports success either way. The worker
  configuration this module writes turns that fallback off, so the check and every later build
  fail visibly instead.
  """

  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.Worker

  # A derivation with no inputs. Nix's own sandbox supplies `/bin/sh`, so a host where this builds
  # is a host where a user build can run in one too.
  @sandbox_probe ~s|derivation { name = "biot-sandbox-probe"; system = builtins.currentSystem; | <>
                   ~s|builder = "/bin/sh"; args = [ "-c" "echo sandboxed > $out" ]; }|

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary
    }
  end

  @spec start_link(keyword()) :: :ignore | {:error, term()}
  def start_link(_options) do
    with {:ok, config} <- Config.load(),
         :ok <-
           FileSystem.ensure_directories([
             Paths.biots(config),
             Paths.diagnostics(config),
             Paths.runtime_logs(config),
             Paths.git_template(config)
           ]),
         :ok <- write_podman_config(config),
         :ok <- write_worker_nix_config(config),
         :ok <- sandboxing_works(config) do
      :ignore
    end
  end

  defp write_podman_config(config) do
    FileSystem.write_atomic(
      Paths.podman_config(config),
      ["[network]\ndefault_rootless_network_cmd=\"", config.podman_network_command, "\"\n"]
    )
  end

  # One file holds every Nix setting a worker runs with, so an operator reads their cache and
  # sandbox policy in one place and a worker inherits nothing else.
  defp write_worker_nix_config(config) do
    FileSystem.write_atomic(Paths.worker_nix_config(config), [
      "build-users-group =\n",
      "sandbox = true\n",
      # Nix builds without a sandbox and reports success when it cannot make one, so `sandbox =
      # true` alone reports a host as working that is not. Turning the fallback off is what makes
      # the probe below, and every later build, fail visibly instead.
      "sandbox-fallback = false\n",
      "experimental-features = nix-command flakes\n",
      "substituters = ",
      Enum.join(config.binary_cache_urls, " "),
      "\n",
      "trusted-public-keys = ",
      Enum.join(config.binary_cache_keys, " "),
      "\n",
      "require-sigs = true\n"
    ])
  end

  defp sandboxing_works(config) do
    case Worker.probe(config, probe_command()) do
      {:ok, %Command.Result{status: 0}} ->
        :ok

      {:ok, %Command.Result{} = result} ->
        {:error, {:build_sandboxing_unsupported, String.slice(result.stderr, 0, 2_000)}}

      {:error, %Outcome{} = outcome} ->
        {:error, {:build_sandboxing_unsupported, outcome.outcome}}
    end
  end

  # The probe builds in a real worker, so it answers for the builds that follow it rather than for
  # a separate approximation of one. Dropping either of the worker's isolation options makes it
  # fail, which is what says it is measuring the thing it claims to.
  defp probe_command do
    ["nix", "build", "--impure", "--no-link", "--expr", @sandbox_probe]
  end
end
