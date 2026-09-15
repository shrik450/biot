defmodule Mix.Tasks.Biot.Certs do
  @shortdoc "Creates the control link's authority and issues or renews its certificates"

  @moduledoc """
  Manages the control link's certificates in one operator directory.

      mix biot.certs authority DIRECTORY
      mix biot.certs server DIRECTORY
      mix biot.certs node DIRECTORY NAME

  `authority` creates `ca.pem` and `ca-key.pem` once and never replaces them. `server` and `node`
  issue a certificate from that authority, or renew the one already there, and print its
  fingerprint: nodes pin the server's as `BIOT_SERVER_FINGERPRINT`, and the registrations file
  names each node's. Renewal keeps the fingerprint. A node name is a lowercase DNS label.

  Deploy `ca.pem` and each peer's own certificate and key. `ca-key.pem` never leaves this
  directory.
  """

  use Mix.Task

  alias Biot.Protocol.Certificates

  @usage """
  usage: mix biot.certs authority DIRECTORY
         mix biot.certs server DIRECTORY
         mix biot.certs node DIRECTORY NAME
  """

  @impl Mix.Task
  def run(["authority", directory]) do
    case Certificates.create_authority(directory) do
      {:ok, path} ->
        Mix.shell().info("Created #{path}")

      {:error, :authority_exists} ->
        Mix.raise("#{directory} already has an authority, and it is never replaced")

      {:error, reason} ->
        Mix.raise("could not create the authority: #{:file.format_error(reason)}")
    end
  end

  def run(["server", directory]), do: issue(directory, :server)
  def run(["node", directory, name]), do: issue(directory, {:node, name})
  def run(_args), do: Mix.raise(@usage)

  defp issue(directory, role) do
    case Certificates.issue(directory, role) do
      {:ok, leaf} ->
        Mix.shell().info(Jason.encode!(leaf, pretty: true))

      {:error, :invalid_node_name} ->
        Mix.raise("a node name is a lowercase DNS label")

      {:error, :missing_authority} ->
        Mix.raise("#{directory} has no authority; run mix biot.certs authority #{directory}")

      {:error, :malformed_authority} ->
        Mix.raise("the authority in #{directory} could not be read")

      {:error, :malformed_key} ->
        Mix.raise("the existing key for this certificate could not be read")

      {:error, reason} ->
        Mix.raise("could not issue the certificate: #{:file.format_error(reason)}")
    end
  end
end
