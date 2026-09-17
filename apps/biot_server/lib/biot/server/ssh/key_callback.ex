defmodule Biot.Server.Ssh.KeyCallback do
  @moduledoc """
  The SSH daemon's public key callback.

  `validate/1` reads and decodes the operator's OpenSSH host key file once, at boot, and returns the
  decoded keys and the host key algorithms they support. `host_key/2` selects from that pinned value
  in `:key_cb_private`. Pinning matters because a file re-read on each handshake would let a replaced
  file change the host key a running daemon serves, and every client that already pinned the old key
  would then fail. `is_auth_key/3` authenticates the offered public key against `SshKeys` and records
  the connection's authentication under its key, so removing the key can close the live connection.
  """

  @behaviour :ssh_server_key_api

  alias Biot.Protocol.SshPublicKey
  alias Biot.Server.Ssh.Authentications
  alias Biot.Server.SshKeys

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
  the pinned keys and the host key algorithms the daemon should offer.
  """
  @spec validate(String.t()) :: {:ok, %{keys: [term()], algorithms: [atom()]}} | {:error, term()}
  def validate(path) do
    with {:ok, keys} <- decode(path),
         algorithms =
           keys
           |> Enum.flat_map(fn {key, _attrs} -> algorithms(key) end)
           |> Enum.uniq(),
         true <- algorithms != [] do
      {:ok, %{keys: keys, algorithms: algorithms}}
    else
      _unusable -> {:error, :invalid_host_key}
    end
  end

  defp decode(path) do
    with {:ok, bytes} <- File.read(path),
         keys when is_list(keys) <- :ssh_file.decode(bytes, :public_key) do
      {:ok, keys}
    else
      {:error, reason} -> {:error, reason}
      _unusable -> {:error, :invalid_host_key}
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
