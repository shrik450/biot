defmodule Dev.LocalBootstrap do
  alias Biot.Protocol.{Certificates, NodeId, RegistrationId}

  @subuid_path "/etc/subuid"
  @subgid_path "/etc/subgid"
  @uid_range_count 1_024

  def main do
    run_directory = fetch_env!("BIOT_RUN_DIRECTORY")
    node_data_root = fetch_env!("BIOT_DATA_DIRECTORY")
    certificate_directory = Path.join(run_directory, "certificates")
    uid_range = subordinate_range!()

    File.mkdir_p!(run_directory)
    {:ok, _authority} = Certificates.create_authority(certificate_directory)
    {:ok, server} = Certificates.issue(certificate_directory, :server)
    {:ok, node} = Certificates.issue(certificate_directory, {:node, "local"})

    node_id = identifier(NodeId)
    registration_id = identifier(RegistrationId)
    ports = %{http: free_port(), control: free_port(), ssh: free_port()}
    ssh_host_key = generate_host_key(run_directory)
    registration_file = Path.join(run_directory, "registrations.json")

    write_registration(registration_file, node_id, registration_id, node.fingerprint)

    write_environment(
      run_directory,
      certificate_directory,
      server,
      node,
      node_id,
      registration_id,
      ssh_host_key,
      registration_file,
      ports,
      uid_range,
      node_data_root
    )

    IO.puts("local bootstrap ready: #{run_directory}")
  end

  defp write_registration(path, node_id, registration_id, peer_identity) do
    registration = [
      %{
        "node_id" => to_string(node_id),
        "registration_id" => to_string(registration_id),
        "peer_identity" => peer_identity,
        "max_biots" => 1,
        "status" => "enabled"
      }
    ]

    File.write!(path, Jason.encode!(registration, pretty: true))
  end

  defp write_environment(
         run_directory,
         certificate_directory,
         server,
         node,
         node_id,
         registration_id,
         ssh_host_key,
         registration_file,
         ports,
         uid_range,
         node_data_root
       ) do
    environment = %{
      "BIOT_CONTROL_CACERTFILE" => Path.join(certificate_directory, "ca.pem"),
      "BIOT_CONTROL_CERTFILE" => server.cert,
      "BIOT_CONTROL_KEYFILE" => server.key,
      "BIOT_CONTROL_PORT" => ports.control,
      "BIOT_DEFAULT_NODE_ID" => node_id,
      "BIOT_DEV_NODE_ID" => node_id,
      "BIOT_DEV_READY_FILE" => Path.join(run_directory, "ready"),
      "BIOT_NODE_BINARY_CACHE_KEYS" =>
        Enum.join(Application.fetch_env!(:biot_node, :binary_cache_keys), " "),
      "BIOT_NODE_BINARY_CACHE_URLS" =>
        Enum.join(Application.fetch_env!(:biot_node, :binary_cache_urls), " "),
      "BIOT_NODE_BUILDER_IMAGE" => Application.fetch_env!(:biot_node, :builder_image),
      "BIOT_NODE_CACERTFILE" => Path.join(certificate_directory, "ca.pem"),
      "BIOT_NODE_CERTFILE" => node.cert,
      "BIOT_NODE_DATA_ROOT" => node_data_root,
      "BIOT_NODE_KEYFILE" => node.key,
      "BIOT_NODE_REGISTRATION_ID" => registration_id,
      "BIOT_NODE_UID_RANGE_BASE" => uid_range.base,
      "BIOT_NODE_UID_RANGE_COUNT" => uid_range.count,
      "BIOT_NODE_UID_RANGE_LIMIT" => uid_range.limit,
      "BIOT_NODE_WORKER_TIMEOUT_MS" => 1_200_000,
      "BIOT_SERVER_DATABASE" => Path.join(run_directory, "server.sqlite3"),
      "BIOT_SERVER_FINGERPRINT" => server.fingerprint,
      "BIOT_SERVER_HOST" => "127.0.0.1",
      "BIOT_SERVER_PORT" => ports.control,
      "BIOT_NODE_REGISTRATIONS" => registration_file,
      "BIOT_SSH_ADVERTISED_HOST" => "127.0.0.1",
      "BIOT_SSH_HOST_KEY_FILE" => ssh_host_key,
      "BIOT_SSH_PORT" => ports.ssh,
      "PORT" => ports.http
    }

    path = Path.join(run_directory, "environment")

    contents =
      environment
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(fn {key, value} -> "export #{key}=#{shell_quote(value)}\n" end)

    File.write!(path, contents)
    File.chmod!(path, 0o600)
  end

  defp identifier(module) do
    {:ok, identifier} = module.parse(Ecto.UUID.generate())
    identifier
  end

  defp generate_host_key(directory) do
    path = Path.join(directory, "ssh-host-key")

    case System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-f", path, "-q"],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> path
      {output, status} -> raise "ssh-keygen failed (#{status}): #{output}"
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp subordinate_range! do
    user = current_user!()
    uid_range = read_subordinate_range!(@subuid_path, user, "UID")
    gid_range = read_subordinate_range!(@subgid_path, user, "GID")

    if uid_range.start != gid_range.start do
      raise(
        "subordinate UID and GID ranges for #{user} must start at the same ID; " <>
          "#{@subuid_path} starts at #{uid_range.start}, " <>
          "#{@subgid_path} starts at #{gid_range.start}"
      )
    end

    available_count = min(uid_range.count, gid_range.count)

    %{
      base: uid_range.start,
      count: min(@uid_range_count, available_count),
      limit: uid_range.start + available_count
    }
  end

  defp current_user! do
    case System.cmd("id", ["-un"], stderr_to_stdout: true) do
      {output, 0} ->
        String.trim(output)

      {output, status} ->
        raise "could not determine the running user (id exited #{status}): #{output}"
    end
  end

  defp read_subordinate_range!(path, user, kind) do
    case File.read(path) do
      {:ok, contents} ->
        case Enum.find_value(String.split(contents, "\n"), &parse_subordinate_entry(&1, user)) do
          {start, count} -> %{start: start, count: count}
          nil -> missing_subordinate_range!(path, user, kind)
        end

      {:error, reason} ->
        raise(
          "could not read #{path} for user #{user}: #{:file.format_error(reason)}; " <>
            "add an entry such as #{user}:524288:65536"
        )
    end
  end

  defp parse_subordinate_entry(line, user) do
    case String.split(line, ":", parts: 3) do
      [^user, start, count] ->
        with {start, ""} <- Integer.parse(start),
             {count, ""} <- Integer.parse(count),
             true <- start >= 0 and count > 0 do
          {start, count}
        else
          _invalid -> nil
        end

      _other ->
        nil
    end
  end

  defp missing_subordinate_range!(path, user, kind) do
    raise(
      "no subordinate #{kind} range for user #{user} in #{path}; " <>
        "add an entry such as #{user}:524288:65536"
    )
  end

  defp shell_quote(value) do
    value
    |> to_string()
    |> String.replace("'", "'\\''")
    |> then(&("'" <> &1 <> "'"))
  end

  defp fetch_env!(name), do: System.fetch_env!(name)
end

Dev.LocalBootstrap.main()
