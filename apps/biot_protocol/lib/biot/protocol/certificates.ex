defmodule Biot.Protocol.Certificates do
  @moduledoc """
  Operator certificate tooling for the control link: one authority per deployment, and the server
  and node certificates issued from it.

  The authority's private key stays in the operator's directory, so a node added later gets a
  certificate from the same authority and nothing else is reissued. An operator with an existing
  authority puts its `ca.pem` and `ca-key.pem` in the directory instead of creating one.

  Issuing a leaf again renews it. The leaf's existing key is reused, and a peer's identity is the
  SHA-256 of its public key, so a renewed certificate keeps every registration and pinned
  fingerprint valid.

  Every private key file is readable by its owner alone before any key material is written to it.
  """

  alias Biot.Protocol.Hostname
  alias Biot.Protocol.PeerIdentity
  alias X509.Certificate
  alias X509.Certificate.Extension
  alias X509.Certificate.Template
  alias X509.PrivateKey
  alias X509.PublicKey

  @authority_certificate "ca.pem"
  @authority_key "ca-key.pem"

  @typedoc "`{:node, name}` takes a lowercase DNS label, which names the node's files."
  @type role :: :server | {:node, String.t()}
  @type leaf :: %{cert: Path.t(), key: Path.t(), fingerprint: String.t()}
  @type issue_error ::
          :invalid_node_name
          | :missing_authority
          | :malformed_authority
          | :malformed_key
          | File.posix()

  @doc "Creates the deployment's authority. An existing authority is never replaced."
  @spec create_authority(Path.t()) :: {:ok, Path.t()} | {:error, :authority_exists | File.posix()}
  def create_authority(directory) do
    certificate_path = Path.join(directory, @authority_certificate)
    key_path = Path.join(directory, @authority_key)

    if File.exists?(certificate_path) or File.exists?(key_path) do
      {:error, :authority_exists}
    else
      key = PrivateKey.new_ec(:secp256r1)
      certificate = Certificate.self_signed(key, "/CN=Biot CA", template: :root_ca)

      with :ok <- File.mkdir_p(directory),
           :ok <- write_private(key_path, PrivateKey.to_pem(key)),
           :ok <- File.write(certificate_path, Certificate.to_pem(certificate), [:exclusive]) do
        {:ok, certificate_path}
      end
    end
  end

  @doc "Issues the certificate for one role from the directory's authority, or renews it."
  @spec issue(Path.t(), role()) :: {:ok, leaf()} | {:error, issue_error()}
  def issue(directory, role) do
    with {:ok, name, subject, template} <- leaf(role),
         {:ok, authority_certificate, authority_key} <- read_authority(directory),
         key_path = Path.join(directory, name <> "-key.pem"),
         {:ok, key} <- leaf_key(key_path),
         certificate =
           Certificate.new(
             PublicKey.derive(key),
             subject,
             authority_certificate,
             authority_key,
             template: template
           ),
         certificate_path = Path.join(directory, name <> "-cert.pem"),
         :ok <- File.write(certificate_path, Certificate.to_pem(certificate)),
         {:ok, fingerprint} <- PeerIdentity.from_certificate(Certificate.to_der(certificate)) do
      {:ok, %{cert: certificate_path, key: key_path, fingerprint: fingerprint}}
    end
  end

  @doc """
  Returns the peer identity of a certificate PEM file, the same value `issue/2` prints.

  This lets an operator enroll a node from its issued certificate instead of copying the
  fingerprint by hand.
  """
  @spec fingerprint(Path.t()) ::
          {:ok, String.t()} | {:error, :missing_certificate | :malformed_certificate}
  def fingerprint(path) do
    with {:ok, pem} <- File.read(path),
         {:ok, certificate} <- Certificate.from_pem(pem),
         {:ok, fingerprint} <- PeerIdentity.from_certificate(Certificate.to_der(certificate)) do
      {:ok, fingerprint}
    else
      {:error, :enoent} -> {:error, :missing_certificate}
      _other -> {:error, :malformed_certificate}
    end
  end

  defp leaf(:server), do: {:ok, "server", "/CN=biot-server", :server}

  defp leaf({:node, name}) do
    case Hostname.parse(name) do
      {:ok, _label} -> {:ok, "node-" <> name, "/CN=biot-node-" <> name, node_template()}
      {:error, :invalid_format} -> {:error, :invalid_node_name}
    end
  end

  # A node only ever dials the server, so its certificate authenticates a client and nothing else.
  defp node_template do
    Template.new(:server, extensions: [ext_key_usage: Extension.ext_key_usage([:clientAuth])])
  end

  defp read_authority(directory) do
    with {:ok, certificate_pem} <- File.read(Path.join(directory, @authority_certificate)),
         {:ok, key_pem} <- File.read(Path.join(directory, @authority_key)),
         {:ok, certificate} <- Certificate.from_pem(certificate_pem),
         {:ok, key} <- PrivateKey.from_pem(key_pem) do
      {:ok, certificate, key}
    else
      {:error, :enoent} -> {:error, :missing_authority}
      {:error, reason} when reason in [:malformed, :not_found] -> {:error, :malformed_authority}
      {:error, reason} -> {:error, reason}
    end
  end

  defp leaf_key(path) do
    case File.read(path) do
      {:ok, pem} ->
        case PrivateKey.from_pem(pem) do
          {:ok, key} -> {:ok, key}
          {:error, _reason} -> {:error, :malformed_key}
        end

      {:error, :enoent} ->
        key = PrivateKey.new_ec(:secp256r1)
        with :ok <- write_private(path, PrivateKey.to_pem(key)), do: {:ok, key}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The file is created empty, restricted, and only then written, so no reader ever sees the key
  # under the umask's wider mode.
  defp write_private(path, content) do
    case File.open(path, [:write, :exclusive, :binary], &restrict_and_write(&1, path, content)) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp restrict_and_write(file, path, content) do
    with :ok <- File.chmod(path, 0o600), do: IO.binwrite(file, content)
  end
end
