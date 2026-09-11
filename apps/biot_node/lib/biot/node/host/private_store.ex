defmodule Biot.Node.Host.PrivateStore do
  @moduledoc """
  Reads one Biot's private Nix store from the node's side of the mount.

  A bundle, an out-link, and a garbage collection root all name `/nix/store/...`, which is true
  inside a worker and inside a runtime and false on the node. This module owns the one translation
  from that logical path to the host directory holding it, and the one procedure that follows an
  out-link through it.
  """

  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Paths
  alias Biot.Node.StorePath
  alias Biot.Protocol.BiotId

  @typedoc "What an out-link resolves to. `absent` is a link that was never written or was removed."
  @type resolution :: :absent | {:present, String.t()} | {:error, :unreadable | term()}

  @doc "The host directory holding one logical store path."
  @spec host_path(Config.t(), BiotId.t(), StorePath.t()) :: String.t()
  def host_path(config, biot_id, path) do
    Path.join(Paths.store_root(config, biot_id), StorePath.to_string(path))
  end

  @doc """
  Follows one out-link into the private store.

  The link's target is a logical store path, so it dangles on the node; only the store root it
  belongs to can say where its bytes are.
  """
  @spec object_at(Config.t(), BiotId.t(), String.t()) :: resolution()
  def object_at(config, biot_id, link) do
    case File.read_link(link) do
      {:ok, target} -> resolved(config, biot_id, target)
      {:error, :enoent} -> :absent
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolved(config, biot_id, target) do
    case StorePath.parse(target) do
      {:ok, store_path} -> {:present, host_path(config, biot_id, store_path)}
      {:error, :invalid_format} -> {:error, :unreadable}
    end
  end
end
