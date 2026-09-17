defmodule Biot.Server.Ssh.KeyCallback do
  @moduledoc """
  The SSH daemon's public key callback.

  `validate/1` reads and decodes the operator's OpenSSH host key file once, at boot, and returns the
  decoded keys, the host key algorithms they support, and the host keys the deployment API
  advertises. `host_key/2` selects from that pinned value in `:key_cb_private`. Pinning matters
  because a file re-read on each handshake would let a replaced file change the host key a running
  daemon serves, and every client that already pinned the old key would then fail. `is_auth_key/3`
  authenticates the offered public key against `SshKeys` and records the connection's authentication
  under its key, so removing the key can close the live connection.

  The same key listed twice is dropped in silence; two different keys of one type are refused. The
  repeat still names one key, so it is not an error, while the clash is: the daemon selects one key
  per offered algorithm and the deployment API advertises by type, so serving either of two would
  be a choice the operator did not make.
  """

  @behaviour :ssh_server_key_api

  alias Biot.Protocol.SshPublicKey
  alias Biot.Server.Ssh.Authentications
  alias Biot.Server.SshKeys

  @type host_key :: %{
          type: String.t(),
          public_key: String.t(),
          fingerprint: String.t()
        }

  @type pinned :: %{keys: [term()], algorithms: [atom()], host_keys: [host_key()]}

  @typedoc "Why `validate/1` refused the operator's host key file."
  @type reason ::
          :missing_host_key_file
          | {:unreadable_host_key_file, File.posix()}
          | :invalid_host_key_file
          | :unsupported_host_key_type
          | {:duplicate_host_key_type, String.t()}

  @impl true
  def host_key(algorithm, options) do
    options |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:pinned) |> select(algorithm)
  end

  @impl true
  def is_auth_key(public_key, _user, _options) do
    with {:ok, ssh_public_key} <- to_ssh_public_key(public_key),
         {:ok, authentication} <- SshKeys.authenticate(ssh_public_key) do
      Authentications.register(authentication)
      true
    else
      _rejected -> false
    end
  end

  @doc """
  Reads and decodes the operator's host key once, so boot fails on an unusable file, and returns
  the pinned keys, the host key algorithms the daemon should offer, and the host keys to advertise.

  Each way the file can be unusable is its own reason; none of them is flattened into a general one,
  because the operator's next step differs for each.
  """
  @spec validate(String.t()) :: {:ok, pinned()} | {:error, reason()}
  def validate(path) do
    with {:ok, keys} <- read(path),
         {:ok, host_keys} <- build_public_keys(keys),
         {:ok, algorithms} <- supported_algorithms(keys),
         :ok <- unique_key_types(host_keys) do
      {:ok, %{keys: keys, algorithms: algorithms, host_keys: host_keys}}
    end
  end

  @doc "The sentence an operator reads at boot for a host key file `validate/1` refused."
  @spec message(String.t(), reason()) :: String.t()
  def message(path, :missing_host_key_file),
    do:
      "the SSH host key file #{path} does not exist; point BIOT_SSH_HOST_KEY_FILE at an existing OpenSSH private key"

  def message(path, {:unreadable_host_key_file, reason}),
    do:
      "the SSH host key file #{path} could not be read: #{to_string(:file.format_error(reason))}; give the service user read access"

  def message(path, :invalid_host_key_file),
    do: "the SSH host key file #{path} is not a valid OpenSSH private key"

  def message(path, :unsupported_host_key_type),
    do:
      "the SSH host key file #{path} has no host key of a type Biot serves; use RSA, Ed25519, or ECDSA"

  def message(path, {:duplicate_host_key_type, type}),
    do:
      "the SSH host key file #{path} has two #{type} keys; keep at most one host key of each type"

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> decode(bytes)
      {:error, :enoent} -> {:error, :missing_host_key_file}
      {:error, reason} -> {:error, {:unreadable_host_key_file, reason}}
    end
  end

  defp decode(bytes) do
    case :ssh_file.decode(bytes, :public_key) do
      keys when is_list(keys) -> {:ok, keys}
      {:error, _reason} -> {:error, :invalid_host_key_file}
    end
  end

  defp build_public_keys(keys), do: Enum.reduce_while(keys, {:ok, []}, &add_public_key/2)

  # A repeated fingerprint names one key, so it is dropped rather than refused.
  # `unique_key_types/1` refuses the other case, two different keys of one type.
  defp add_public_key({key, _attrs}, {:ok, public_keys}) do
    case to_ssh_public_key(key) do
      {:ok, %SshPublicKey{} = public_key} ->
        entry = public_key_entry(public_key)

        if Enum.any?(public_keys, &(&1.fingerprint == entry.fingerprint)),
          do: {:cont, {:ok, public_keys}},
          else: {:cont, {:ok, public_keys ++ [entry]}}

      {:error, _reason} ->
        {:halt, {:error, :invalid_host_key_file}}
    end
  end

  defp public_key_entry(%SshPublicKey{} = public_key) do
    %{
      type: public_key.line |> String.split() |> hd(),
      public_key: public_key.line,
      fingerprint: public_key.fingerprint
    }
  end

  defp supported_algorithms(keys) do
    supported =
      keys
      |> Enum.flat_map(fn {key, _attrs} -> algorithms(key) end)
      |> Enum.uniq()

    case supported do
      [] -> {:error, :unsupported_host_key_type}
      supported -> {:ok, supported}
    end
  end

  # Two different keys of one type are refused because `host_key/2` selects one for an offered
  # algorithm and `Daemon.host_keys/0` advertises by type, so either key would be a silent choice.
  # `add_public_key/2` drops the harmless case, the same fingerprint twice.
  defp unique_key_types(host_keys) do
    types = Enum.map(host_keys, & &1.type)

    case types -- Enum.uniq(types) do
      [] -> :ok
      [duplicate | _rest] -> {:error, {:duplicate_host_key_type, duplicate}}
    end
  end

  defp select(%{keys: keys}, algorithm) do
    Enum.find_value(keys, {:error, :no_key_found}, fn {key, _attrs} ->
      if algorithm in algorithms(key), do: {:ok, key}
    end)
  end

  # Biot's decision about which host key algorithms it offers, written down here instead of
  # inherited from an OTP-internal helper. The table names the algorithms of one decoded private
  # key, so an unsupported key type offers nothing and the handshake fails.
  defp algorithms({:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _}),
    do: [:"ssh-rsa", :"rsa-sha2-256", :"rsa-sha2-512"]

  defp algorithms({:ECPrivateKey, _, _, {:namedCurve, {1, 3, 101, 112}}, _, _}),
    do: [:"ssh-ed25519"]

  defp algorithms({:ECPrivateKey, _, _, {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}, _, _}),
    do: [:"ecdsa-sha2-nistp256"]

  defp algorithms({:ECPrivateKey, _, _, {:namedCurve, {1, 3, 132, 0, 34}}, _, _}),
    do: [:"ecdsa-sha2-nistp384"]

  defp algorithms({:ECPrivateKey, _, _, {:namedCurve, {1, 3, 132, 0, 35}}, _, _}),
    do: [:"ecdsa-sha2-nistp521"]

  defp algorithms(_key), do: []

  defp to_ssh_public_key(public_key) do
    line =
      :ssh_file.encode([{public_key, []}], :openssh_key)
      |> IO.iodata_to_binary()
      |> String.trim_trailing()

    SshPublicKey.parse(line)
  rescue
    _error -> {:error, :invalid_format}
  end
end
