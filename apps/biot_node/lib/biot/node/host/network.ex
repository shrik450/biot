defmodule Biot.Node.Host.Network do
  @moduledoc "Creates, inspects, and removes one allocation's private Podman network."

  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Names
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Host.Podman
  alias Biot.Node.NetworkId

  @type state :: :present | :absent | {:unknown, term()}

  @spec ensure(Config.t(), NetworkId.t()) :: :ok | {:error, Outcome.t()}
  def ensure(config, network_id) do
    case state(config, network_id) do
      :present -> :ok
      :absent -> create(config, network_id)
      {:unknown, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  @spec state(Config.t(), NetworkId.t()) :: state()
  def state(config, network_id) do
    case Podman.exists(config, :network, Names.network(network_id)) do
      :present ->
        :present

      :absent ->
        :absent

      {:error, %Command.Result{} = result} ->
        {:unknown, Outcome.from_command(:host_unavailable, result)}

      {:error, reason} ->
        {:unknown, reason}
    end
  end

  @spec remove(Config.t(), NetworkId.t()) :: :ok | {:error, Outcome.t()}
  def remove(config, network_id) do
    case state(config, network_id) do
      :absent -> :ok
      :present -> remove_present(config, network_id)
      {:unknown, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  # Rootless bridge networks share one host network namespace, so without `isolate` one biot's
  # container can route to another biot's container.
  defp create(config, network_id) do
    arguments = [
      "network",
      "create",
      "--disable-dns",
      "--opt",
      "isolate=true",
      Names.network(network_id)
    ]

    case Podman.run(config, arguments) do
      {:ok, %Command.Result{status: 0}} ->
        :ok

      {:ok, %Command.Result{} = result} ->
        {:error, Outcome.from_command(:host_unavailable, result)}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp remove_present(config, network_id) do
    case Podman.run(config, ["network", "rm", Names.network(network_id)]) do
      {:ok, %Command.Result{status: 0}} ->
        :ok

      {:ok, %Command.Result{} = result} ->
        {:error, Outcome.from_command(:host_unavailable, result)}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end
end
