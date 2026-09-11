defmodule Biot.Node.Host.Paths do
  @moduledoc """
  Owns the node-private layout below the configured data root.

  Each Biot has writable checkout, home, service data, and run mounts. Its secrets mount is read
  only in the container. The completion marker and container identity sit beside these mounts.
  Everything Nix owns for that Biot is under the same root: `store` holds its private Nix store
  and database, `build` holds worker scratch and the staged build support, and `environments`
  holds one directory per environment with the `staged` and `root` out-links a build worker
  writes. The container-side mount targets listed here match the mount points that
  `nix/build.nix` builds into the bundle.

  Invariant: `/nix/store` names a different physical directory in every Biot. The logical path
  inside a worker and a runtime is always `/nix/store`, which is what keeps binary cache
  substitutes usable; `Biot.Node.Host.PrivateStore` owns the translation back to a host path, and
  `Biot.Node.Host.Worker.Layout` owns what a worker sees.

  The SQLite journal, `flock` file, Podman module, worker Nix configuration, and the empty Git
  template sit below the data root. Diagnostics and runtime logs are node-private siblings, so no
  container mount includes them.
  """

  alias Biot.Node.Host.Config
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.PrivateDiagnosticId

  @spec lock(Config.t() | String.t()) :: String.t()
  def lock(%Config{data_root: root}), do: lock(root)

  # Boot code has only the data-root string before the parsed host configuration exists.
  def lock(root), do: Path.join(root, "lock")

  @spec journal(Config.t() | String.t()) :: String.t()
  def journal(%Config{data_root: root}), do: journal(root)

  # The repository starts before a controller can build a host context.
  def journal(root), do: Path.join(root, "journal.sqlite3")

  @spec podman_config(Config.t()) :: String.t()
  def podman_config(%Config{data_root: root}), do: Path.join(root, "podman.conf")

  @doc "The Nix configuration every build worker reads. Operator policy lives in one file."
  @spec worker_nix_config(Config.t()) :: String.t()
  def worker_nix_config(%Config{data_root: root}), do: Path.join(root, "nix.conf")

  @doc "The empty template directory every Biot-managed Git call uses instead of the user's."
  @spec git_template(Config.t()) :: String.t()
  def git_template(%Config{data_root: root}), do: Path.join(root, "git-template")

  @spec diagnostics(Config.t()) :: String.t()
  def diagnostics(%Config{data_root: root}), do: Path.join(root, "diagnostics")

  @spec diagnostic(Config.t(), PrivateDiagnosticId.t()) :: String.t()
  def diagnostic(config, diagnostic_id) do
    Path.join(diagnostics(config), PrivateDiagnosticId.to_string(diagnostic_id))
  end

  @spec runtime_logs(Config.t()) :: String.t()
  def runtime_logs(%Config{data_root: root}), do: Path.join(root, "runtime-logs")

  @spec runtime_log(Config.t(), BiotId.t()) :: String.t()
  def runtime_log(config, biot_id) do
    Path.join(runtime_logs(config), BiotId.to_string(biot_id) <> ".log")
  end

  @spec runtime_log_metadata(Config.t(), BiotId.t()) :: String.t()
  def runtime_log_metadata(config, biot_id), do: runtime_log(config, biot_id) <> ".metadata.json"

  @spec biots(Config.t()) :: String.t()
  def biots(%Config{data_root: root}), do: Path.join(root, "biots")

  @spec biot(Config.t(), BiotId.t()) :: String.t()
  def biot(config, biot_id), do: Path.join(biots(config), BiotId.to_string(biot_id))

  @spec checkout(Config.t(), BiotId.t()) :: String.t()
  def checkout(config, biot_id), do: Path.join(biot(config, biot_id), "checkout")

  @spec home(Config.t(), BiotId.t()) :: String.t()
  def home(config, biot_id), do: Path.join(biot(config, biot_id), "home")

  @spec service_data(Config.t(), BiotId.t()) :: String.t()
  def service_data(config, biot_id), do: Path.join(biot(config, biot_id), "service-data")

  @spec run(Config.t(), BiotId.t()) :: String.t()
  def run(config, biot_id), do: Path.join(biot(config, biot_id), "run")

  @spec secrets(Config.t(), BiotId.t()) :: String.t()
  def secrets(config, biot_id), do: Path.join(biot(config, biot_id), "secrets")

  @doc "The root of the Biot's private Nix store and database, as a Nix store root."
  @spec store_root(Config.t(), BiotId.t()) :: String.t()
  def store_root(config, biot_id), do: Path.join(biot(config, biot_id), "store")

  @spec store(Config.t(), BiotId.t()) :: String.t()
  def store(config, biot_id), do: Path.join(store_root(config, biot_id), "nix/store")

  @doc "Worker scratch: the build directory, the Nix fetcher cache, and the worker's home."
  @spec scratch(Config.t(), BiotId.t()) :: String.t()
  def scratch(config, biot_id), do: Path.join(biot(config, biot_id), "build")

  @doc """
  The copy of this release's Nix build support that a worker evaluates.

  It stays owned by the node, because the node rewrites it on every resolution so a node upgrade
  is picked up without retaining the old one, and a worker only ever reads it.
  """
  @spec build_support(Config.t(), BiotId.t()) :: String.t()
  def build_support(config, biot_id), do: Path.join(biot(config, biot_id), "support")

  @spec environments(Config.t(), BiotId.t()) :: String.t()
  def environments(config, biot_id), do: Path.join(biot(config, biot_id), "environments")

  @spec environment(Config.t(), BiotId.t(), EnvironmentId.t()) :: String.t()
  def environment(config, biot_id, environment_id) do
    Path.join(environments(config, biot_id), EnvironmentId.to_string(environment_id))
  end

  @doc "The fetch phase's out-link: the staged inputs of one environment, and its GC root."
  @spec staged(Config.t(), BiotId.t(), EnvironmentId.t()) :: String.t()
  def staged(config, biot_id, environment_id) do
    Path.join(environment(config, biot_id, environment_id), "staged")
  end

  @doc "The build phase's out-link: the prepared bundle of one environment, and its GC root."
  @spec environment_root(Config.t(), BiotId.t(), EnvironmentId.t()) :: String.t()
  def environment_root(config, biot_id, environment_id) do
    Path.join(environment(config, biot_id, environment_id), "root")
  end

  @type mount_mode :: :rw | :ro
  @type mount :: {String.t(), String.t(), mount_mode()}

  @doc """
  What a runtime container mounts. It sees its own store read only and nothing Nix writes: no
  `/nix/var`, no daemon socket, no scratch, and no other Biot.
  """
  @spec runtime_mounts(Config.t(), BiotId.t()) :: [mount()]
  def runtime_mounts(config, biot_id) do
    [
      {checkout(config, biot_id), "/biot/checkout", :rw},
      {store(config, biot_id), "/nix/store", :ro}
      | mounts_created_at_allocation(config, biot_id)
    ]
  end

  # The checkout is missing here because a present checkout directory is what marks the clone
  # done: if `allocate` created it, every Biot would initialize with an empty checkout.
  @spec mounts_created_at_allocation(Config.t(), BiotId.t()) :: [mount()]
  def mounts_created_at_allocation(config, biot_id) do
    [
      {home(config, biot_id), "/biot/home", :rw},
      {service_data(config, biot_id), "/biot/service-data", :rw},
      {run(config, biot_id), "/biot/run", :rw},
      {secrets(config, biot_id), "/biot/secrets", :ro}
    ]
  end

  @doc """
  Every private directory `allocate` creates and hands to the allocation's own user range.

  The store directory is listed as well as its root so a runtime's mount source exists before the
  first build writes anything. `environments/` is not here: the node creates and removes one
  directory per environment inside it, and hands each of those to the allocation on its own.
  """
  @spec allocation_owned_directories(Config.t(), BiotId.t()) :: [String.t()]
  def allocation_owned_directories(config, biot_id) do
    Enum.map(mounts_created_at_allocation(config, biot_id), &elem(&1, 0)) ++
      [
        store_root(config, biot_id),
        store(config, biot_id),
        scratch(config, biot_id)
      ]
  end

  @spec marker(Config.t(), BiotId.t()) :: String.t()
  def marker(config, biot_id), do: Path.join(biot(config, biot_id), "marker")

  # Working data initialize once, and this directory sits inside the Biot's own root, so one
  # staging path per Biot is all a repeated clone can need.
  @spec checkout_staging(Config.t(), BiotId.t()) :: String.t()
  def checkout_staging(config, biot_id) do
    Path.join(biot(config, biot_id), ".checkout.staging")
  end

  @spec container_identity(Config.t(), BiotId.t()) :: String.t()
  def container_identity(config, biot_id) do
    Path.join(biot(config, biot_id), "container-id")
  end
end
