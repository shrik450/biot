defmodule Biot.Node.Host.Names do
  @moduledoc """
  Owns Podman network names, container names, and ownership labels.

  Two kinds of container carry a Biot's label: the runtime and the build worker. The role label
  tells them apart, so a lookup for one never finds the other.
  """

  alias Biot.Node.NetworkId
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.IncarnationId

  @biot_label "io.biot.biot-id"
  @incarnation_label "io.biot.incarnation-id"
  @environment_label "io.biot.environment-id"
  @role_label "io.biot.role"
  @phase_label "io.biot.worker-phase"

  @type role :: :runtime | :worker | :probe
  @type worker_phase :: :fetch | :build | :collect

  @spec network(NetworkId.t()) :: String.t()
  def network(network_id), do: "biot-network-" <> NetworkId.to_string(network_id)

  @spec container(IncarnationId.t()) :: String.t()
  def container(incarnation_id), do: "biot-" <> IncarnationId.to_string(incarnation_id)

  @doc """
  The one build worker name an allocation ever uses. Recovery finds a surviving worker by this
  name alone, which is why the phase is a label and not part of it.
  """
  @spec worker(BiotId.t()) :: String.t()
  def worker(biot_id), do: "biot-worker-" <> BiotId.to_string(biot_id)

  @spec label_arguments(BiotId.t(), IncarnationId.t(), EnvironmentId.t()) :: [String.t()]
  def label_arguments(biot_id, incarnation_id, environment_id) do
    %{
      @biot_label => BiotId.to_string(biot_id),
      @incarnation_label => IncarnationId.to_string(incarnation_id),
      @environment_label => EnvironmentId.to_string(environment_id),
      @role_label => "runtime"
    }
    |> Enum.sort()
    |> Enum.flat_map(fn {key, value} -> ["--label", "#{key}=#{value}"] end)
  end

  @doc "The worker that proves at startup that this host can sandbox a build. It owns no Biot."
  @spec worker_probe() :: String.t()
  def worker_probe, do: "biot-worker-probe"

  @spec probe_label_arguments() :: [String.t()]
  def probe_label_arguments, do: ["--label", "#{@role_label}=probe"]

  @spec worker_label_arguments(BiotId.t(), worker_phase()) :: [String.t()]
  def worker_label_arguments(biot_id, phase) do
    %{
      @biot_label => BiotId.to_string(biot_id),
      @role_label => "worker",
      @phase_label => Atom.to_string(phase)
    }
    |> Enum.sort()
    |> Enum.flat_map(fn {key, value} -> ["--label", "#{key}=#{value}"] end)
  end

  @doc "A Podman filter that selects one role, so a runtime lookup never returns a worker."
  @spec role_filter(role()) :: String.t()
  def role_filter(role), do: "label=#{@role_label}=#{Atom.to_string(role)}"

  @spec owner_filter(BiotId.t()) :: String.t()
  def owner_filter(biot_id), do: "label=#{@biot_label}=#{BiotId.to_string(biot_id)}"

  @doc "The biot a set of container labels says owns the container."
  @spec owner(term()) :: {:ok, BiotId.t()} | {:error, :invalid_format}
  def owner(%{@biot_label => value}), do: BiotId.parse(value)
  def owner(_labels), do: {:error, :invalid_format}

  @doc "The role a set of container labels claims. An unlabelled container claims none."
  @spec role(term()) :: {:ok, role()} | {:error, :invalid_format}
  def role(%{@role_label => "runtime"}), do: {:ok, :runtime}
  def role(%{@role_label => "worker"}), do: {:ok, :worker}
  def role(%{@role_label => "probe"}), do: {:ok, :probe}
  def role(_labels), do: {:error, :invalid_format}

  @spec biot_label() :: String.t()
  def biot_label, do: @biot_label

  @spec incarnation_label() :: String.t()
  def incarnation_label, do: @incarnation_label

  @spec environment_label() :: String.t()
  def environment_label, do: @environment_label

  @spec role_label() :: String.t()
  def role_label, do: @role_label
end
