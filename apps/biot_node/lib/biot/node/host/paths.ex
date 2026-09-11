defmodule Biot.Node.Host.Paths do
  @moduledoc """
  Owns the node-private layout below the configured data root.

  Each Biot has writable checkout, home, service data, and run mounts. Its secrets mount is read
  only in the container. The completion marker and container identity sit beside these mounts.
  Each environment has a derived build manifest and a `root` symlink into the Nix store.
  Inspection reads `bundle.json` through that root. The container-side mount targets listed here
  match the mount points and entries that `nix/build.nix` builds into the bundle.
  The SQLite journal and `flock` file sit below the data root. A Podman module selects the configured
  rootless network helper. Diagnostics and
  runtime logs are node-private siblings, so no container mount includes them.
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

  @type mount_mode :: :rw | :ro
  @type mount :: {String.t(), String.t(), mount_mode()}

  @spec mounts(Config.t(), BiotId.t()) :: [mount()]
  def mounts(config, biot_id) do
    [
      {checkout(config, biot_id), "/biot/checkout", :rw}
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

  @spec environments(Config.t()) :: String.t()
  def environments(%Config{data_root: root}), do: Path.join(root, "environments")

  @spec environment(Config.t(), EnvironmentId.t()) :: String.t()
  def environment(config, environment_id) do
    Path.join(environments(config), EnvironmentId.to_string(environment_id))
  end

  @spec manifest(Config.t(), EnvironmentId.t()) :: String.t()
  def manifest(config, environment_id),
    do: Path.join(environment(config, environment_id), "manifest.json")

  @spec environment_root(Config.t(), EnvironmentId.t()) :: String.t()
  def environment_root(config, environment_id),
    do: Path.join(environment(config, environment_id), "root")
end
