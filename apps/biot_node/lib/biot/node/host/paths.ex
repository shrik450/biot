defmodule Biot.Node.Host.Paths do
  @moduledoc """
  Owns the node-private layout below the configured data root.

  Each Biot has `checkout`, `home`, and `service-data` writable mounts. Its completion marker and
  container identity sit beside those mounts. Each environment has a derived build manifest and a
  `root` symlink into the Nix store. Inspection reads `bundle.json` through that root. The SQLite journal and `flock` file sit directly below the data root. A Podman
  module selects the configured rootless network helper. Each Biot also has an empty root
  filesystem owned by its UID range. Diagnostics and runtime logs are node-private siblings of
  the runtime and environment directories, so no container mount includes them.
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

  @spec mounts(Config.t(), BiotId.t()) :: [{String.t(), String.t()}]
  def mounts(config, biot_id) do
    [
      {checkout(config, biot_id), "/biot/checkout"},
      {home(config, biot_id), "/biot/home"},
      {service_data(config, biot_id), "/biot/service-data"}
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

  @spec rootfs(Config.t(), BiotId.t()) :: String.t()
  def rootfs(config, biot_id), do: Path.join(biot(config, biot_id), "rootfs")
end
