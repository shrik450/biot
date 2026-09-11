defmodule Biot.Node.Host.Secrets do
  @moduledoc """
  Owns the files behind one allocation's `/biot/secrets` mount.

  A secret is one file named for the environment variable it becomes. The directory is the node's,
  so the node can publish into it; each file is handed to the allocation's mapped user and left
  readable to nobody else, so the container can read the secret and nothing outside it can.

  Publication is a rename, which is what keeps a service that starts mid-write from reading half a
  value, and what makes a repeated delivery replace the file rather than edit it.

  An absent directory is `no_allocation` rather than something to create. This module is the one
  place that could quietly bring an allocation's private root back after `remove_data` removed it,
  and refusing to is what keeps a request from creating an allocation to service itself.
  """

  alias Biot.Node.Allocation
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.Podman
  alias Biot.Protocol.SecretName
  alias Biot.Protocol.SecretOutcome
  alias Biot.Protocol.SecretValue

  require Logger

  @file_mode 0o400

  @spec write(Config.t(), Allocation.t(), SecretName.t(), SecretValue.t()) :: SecretOutcome.t()
  def write(config, %Allocation{} = allocation, %SecretName{} = name, value) do
    directory = Paths.secrets(config, allocation.biot_id)

    case FileSystem.directory(directory) do
      {:present, :directory} -> publish(config, allocation, directory, name, value)
      :absent -> :no_allocation
      {:error, reason} -> failed("the secrets directory could not be inspected", reason)
    end
  end

  @spec remove(Config.t(), Allocation.t(), SecretName.t()) :: SecretOutcome.t()
  def remove(config, %Allocation{} = allocation, %SecretName{} = name) do
    directory = Paths.secrets(config, allocation.biot_id)

    case FileSystem.directory(directory) do
      {:present, :directory} -> unlink(Path.join(directory, SecretName.to_string(name)))
      :absent -> :no_allocation
      {:error, reason} -> failed("the secrets directory could not be inspected", reason)
    end
  end

  @spec list(Config.t(), Allocation.t()) :: SecretOutcome.listing()
  def list(config, %Allocation{} = allocation) do
    case File.ls(Paths.secrets(config, allocation.biot_id)) do
      {:ok, entries} ->
        {:ok, entries |> Enum.flat_map(&parsed_name/1) |> Enum.sort_by(&SecretName.to_string/1)}

      {:error, :enoent} ->
        :no_allocation

      {:error, reason} ->
        failed("the secrets directory could not be listed", reason)
    end
  end

  # The file is the allocation's and unreadable to anyone else before it has its final name, so no
  # reader ever sees one the node has not finished handing over.
  defp publish(config, allocation, directory, name, value) do
    prepare = fn path ->
      with :ok <- File.chmod(path, @file_mode), do: Podman.grant(config, allocation, [path])
    end

    case FileSystem.publish(
           directory,
           SecretName.to_string(name),
           SecretValue.reveal(value),
           prepare
         ) do
      :ok -> :ok
      {:error, reason} -> failed("a delivered secret could not be published", reason)
    end
  end

  defp unlink(path) do
    case FileSystem.unlink(path) do
      :ok -> :ok
      {:error, reason} -> failed("a secret could not be removed", reason)
    end
  end

  # A file whose name is not one this node would have written is not a secret; ignoring it keeps a
  # stray file from making the whole listing fail.
  defp parsed_name(entry) do
    case SecretName.parse(entry) do
      {:ok, name} -> [name]
      {:error, _reason} -> []
    end
  end

  defp failed(message, reason) do
    Logger.warning("#{message}: #{inspect(reason)}")
    {:failure, :write_failed}
  end
end
