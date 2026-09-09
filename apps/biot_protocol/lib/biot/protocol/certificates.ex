defmodule Biot.Protocol.Certificates do
  @moduledoc "Writes minimal operator-managed CA, server, and node certificate files with their fingerprints."

  alias Biot.Protocol.PeerIdentity
  alias X509.Certificate
  alias X509.Certificate.Extension
  alias X509.Certificate.Template
  alias X509.PrivateKey
  alias X509.PublicKey

  @spec generate(Path.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def generate(directory, node_count) when is_binary(directory) and node_count >= 0 do
    with :ok <- File.mkdir_p(directory) do
      ca_key = PrivateKey.new_ec(:secp256r1)
      ca_cert = Certificate.self_signed(ca_key, "/CN=Biot Development CA", template: :root_ca)
      server_key = PrivateKey.new_ec(:secp256r1)

      server_cert =
        Certificate.new(PublicKey.derive(server_key), "/CN=biot-server", ca_cert, ca_key,
          template: :server
        )

      :ok = write(directory, "ca.pem", Certificate.to_pem(ca_cert))
      :ok = write(directory, "server-cert.pem", Certificate.to_pem(server_cert))
      :ok = write_key(directory, "server-key.pem", PrivateKey.to_pem(server_key))

      {:ok, server_fingerprint} = PeerIdentity.from_certificate(Certificate.to_der(server_cert))
      nodes = Enum.map(1..node_count//1, &generate_node(directory, &1, ca_cert, ca_key))

      node_fingerprints =
        nodes
        |> Enum.with_index(1)
        |> Map.new(fn {node, number} -> {"node-#{number}", node.fingerprint} end)

      :ok =
        write(
          directory,
          "fingerprints.json",
          Jason.encode!(%{"server" => server_fingerprint, "nodes" => node_fingerprints},
            pretty: true
          )
        )

      {:ok,
       %{
         ca: Path.join(directory, "ca.pem"),
         server: %{
           cert: Path.join(directory, "server-cert.pem"),
           key: Path.join(directory, "server-key.pem"),
           fingerprint: server_fingerprint
         },
         nodes: nodes
       }}
    end
  end

  defp generate_node(directory, number, ca_cert, ca_key) do
    key = PrivateKey.new_ec(:secp256r1)

    cert =
      Certificate.new(PublicKey.derive(key), "/CN=biot-node-#{number}", ca_cert, ca_key,
        template: client_template()
      )

    cert_name = "node-#{number}-cert.pem"
    key_name = "node-#{number}-key.pem"
    :ok = write(directory, cert_name, Certificate.to_pem(cert))
    :ok = write_key(directory, key_name, PrivateKey.to_pem(key))
    {:ok, fingerprint} = PeerIdentity.from_certificate(Certificate.to_der(cert))

    %{
      cert: Path.join(directory, cert_name),
      key: Path.join(directory, key_name),
      fingerprint: fingerprint
    }
  end

  defp write(directory, name, content), do: File.write(Path.join(directory, name), content)

  defp write_key(directory, name, content) do
    path = Path.join(directory, name)

    with :ok <- File.write(path, content), do: File.chmod(path, 0o600)
  end

  defp client_template do
    Template.new(:server,
      extensions: [ext_key_usage: Extension.ext_key_usage([:clientAuth])]
    )
  end
end
