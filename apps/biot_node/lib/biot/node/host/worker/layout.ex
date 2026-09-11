defmodule Biot.Node.Host.Worker.Layout do
  @moduledoc """
  The filesystem a build worker sees, and the only place a container-side path is written.

  Callers that build a Nix command ask this module where the store, the staged inputs, and the
  out-link are, rather than spelling `/biot/...` themselves. Changing a path here changes the
  mount and the command together.

  Mounts are per phase, and the phase carries the environment it is working on. A fetch or a build
  sees one environment directory, mounted at the path it lives at, so one worker cannot read or
  write another environment of the same Biot. Collection sees every environment directory read
  only, because that is what its garbage collection roots point at.

  Invariant: an out-link's path inside the worker is what Nix records as an indirect garbage
  collection root, so those paths must differ per environment and must mean the same thing in
  every later worker. That is why environment directories keep their own name in the mount target
  instead of being mounted at one fixed place.

  Step 18's fetch credential is one entry added to the fetch phase's mounts and nothing else; no
  build or collection worker has a mount it could inherit it through.
  """

  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Paths
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentId

  @typedoc """
  What a worker is doing, the environment it is doing it to, and, for a build, the staged inputs
  that evaluation is allowed to see. A build worker's capability set is exactly what was staged.
  """
  @type phase ::
          {:fetch, EnvironmentId.t()}
          | {:build, EnvironmentId.t(), [staged_input()]}
          | :collect

  @typedoc "One staged input to mount: its fetch-output entry, its store object name, and its host path."
  @type staged_input :: {String.t(), String.t(), String.t()}

  @store_root "/biot/store"
  @scratch "/build"
  @environments "/biot/environments"
  @staged "/biot/staged"
  @build_support "/biot/build-support"
  @nix_config "/etc/nix/nix.conf"

  @doc "Where Nix is told the store is. Every worker command carries this and only this."
  @spec store_arguments() :: [String.t()]
  def store_arguments, do: ["--store", @store_root]

  @doc """
  The store root inside a worker.

  A worker with an allocation has that allocation's store mounted here. A worker without one gets
  a throwaway in its place, which is the only thing an absent allocation changes about where Nix
  writes.
  """
  @spec store_root() :: String.t()
  def store_root, do: @store_root

  @doc "Where the fetch phase reads this release's build support from. Only that phase has it."
  @spec build_support() :: String.t()
  def build_support, do: @build_support

  @doc """
  Where one staged input appears in a build worker.

  The last segment is the staged store object's own name, because that name and the input's NAR
  hash are what make a pure evaluation resolve to the object the fetch phase already retained
  instead of copying it.
  """
  @spec staged_input(String.t(), String.t()) :: String.t()
  def staged_input(entry, object_name), do: Path.join([@staged, entry, object_name])

  @spec environment(EnvironmentId.t()) :: String.t()
  def environment(environment_id) do
    Path.join(@environments, EnvironmentId.to_string(environment_id))
  end

  @doc "The fetch phase's out-link: this environment's staged inputs, and their retention root."
  @spec staged_link(EnvironmentId.t()) :: String.t()
  def staged_link(environment_id), do: Path.join(environment(environment_id), "staged")

  @doc "The build phase's out-link: this environment's prepared bundle, and its retention root."
  @spec bundle_link(EnvironmentId.t()) :: String.t()
  def bundle_link(environment_id), do: Path.join(environment(environment_id), "root")

  @doc """
  The environment every worker runs with.

  Nix gets no channel search path and no inherited configuration, so the operator's settings reach
  it through the mounted configuration file alone, and everything it writes outside the store goes
  to the allocation's own scratch.
  """
  @spec variables() :: [{String.t(), String.t()}]
  def variables do
    [
      {"NIX_PATH", ""},
      {"TMPDIR", @scratch},
      {"HOME", Path.join(@scratch, "home")},
      {"XDG_CACHE_HOME", Path.join(@scratch, "cache")}
    ]
  end

  @doc "Where the operator's Nix settings are mounted. A worker inherits no other configuration."
  @spec nix_config() :: String.t()
  def nix_config, do: @nix_config

  @doc """
  Image paths Nix writes to that a read-only image root would otherwise refuse.

  A worker's own state is the mounts it was given; these are the image's own scratch, and a fresh
  one per run is what makes the image root disposable rather than merely unused.
  """
  @spec image_tmpfs() :: [String.t()]
  def image_tmpfs, do: ["/tmp", "/root", "/var", "/nix/var"]

  @doc "What the phase is called, for the worker's label."
  @spec phase_name(phase()) :: :fetch | :build | :collect
  def phase_name({:fetch, %EnvironmentId{}}), do: :fetch
  def phase_name({:build, %EnvironmentId{}, _staged}), do: :build
  def phase_name(:collect), do: :collect

  @spec mounts(Config.t(), BiotId.t(), phase()) :: [Paths.mount()]
  def mounts(config, biot_id, {:fetch, environment_id}) do
    [
      {Paths.environment(config, biot_id, environment_id), environment(environment_id), :rw},
      {Paths.build_support(config, biot_id), @build_support, :ro}
      | common_mounts(config, biot_id)
    ]
  end

  # A build sees its own staged inputs and nothing else that can become one: not the release copy
  # the fetch phase read, which a later resolution may already have replaced, and not another
  # environment.
  def mounts(config, biot_id, {:build, environment_id, staged}) do
    [
      {Paths.environment(config, biot_id, environment_id), environment(environment_id), :rw}
      | Enum.map(staged, fn {entry, object_name, host_path} ->
          {host_path, staged_input(entry, object_name), :ro}
        end) ++ common_mounts(config, biot_id)
    ]
  end

  # Collection walks every root this Biot holds, and each one names an environment directory by the
  # path a build worker wrote it at.
  def mounts(config, biot_id, :collect) do
    [
      {Paths.environments(config, biot_id), @environments, :ro}
      | common_mounts(config, biot_id)
    ]
  end

  defp common_mounts(config, biot_id) do
    [
      {Paths.store_root(config, biot_id), @store_root, :rw},
      {Paths.scratch(config, biot_id), @scratch, :rw},
      {Paths.worker_nix_config(config), @nix_config, :ro}
    ]
  end
end
