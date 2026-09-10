defmodule Biot.Node.Host.Setup do
  @moduledoc "Creates the node-wide host layout after the data-root lock is held."

  alias Biot.Node.Host.Config
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Paths

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
    with {:ok, config} <- Config.from_application(),
         :ok <-
           FileSystem.ensure_directories([
             Paths.biots(config),
             Paths.environments(config),
             Paths.diagnostics(config),
             Paths.runtime_logs(config)
           ]),
         :ok <- write_podman_config(config) do
      :ignore
    end
  end

  defp write_podman_config(config) do
    FileSystem.write_atomic(
      Paths.podman_config(config),
      ["[network]\ndefault_rootless_network_cmd=\"", config.podman_network_command, "\"\n"]
    )
  end
end
