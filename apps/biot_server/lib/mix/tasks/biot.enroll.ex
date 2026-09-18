defmodule Mix.Tasks.Biot.Enroll do
  @shortdoc "Adds or updates a node in the operator's enrollment file"

  @moduledoc """
  Writes one node into the server's enrollment file, `BIOT_NODE_REGISTRATIONS`.

      mix biot.enroll --file FILE --registration-id UUID --max-biots N \\
        (--fingerprint HEX | --name NAME [--certs-dir DIR]) [--node-id UUID]

  The file is the JSON list the server imports at boot. Running the task again with a new
  registration adds a node; running it again with a registration already in the file updates that
  node and keeps the `node_id` it was first given.

  The fingerprint is the node certificate's peer identity, which `mix biot.certs node` prints. Give
  it directly with `--fingerprint`, or give the node's name with `--name` to read
  `node-NAME-cert.pem` from `--certs-dir` and compute it. `--max-biots` is the node's capacity.

  After writing, the server reimports the file at boot, or without a restart with:

      /opt/biot/server/bin/server rpc "Biot.Server.Nodes.reload()"
  """

  use Mix.Task

  alias Biot.Protocol.{Certificates, Hostname, NodeId, RegistrationId}
  alias Biot.Server.Nodes.Enrollment

  @switches [
    file: :string,
    node_id: :string,
    registration_id: :string,
    fingerprint: :string,
    name: :string,
    certs_dir: :string,
    max_biots: :integer,
    help: :boolean
  ]
  @aliases [h: :help]
  @default_certs_dir "/etc/biot/certs"

  @impl Mix.Task
  def run(arguments) do
    {options, positional, invalid} =
      OptionParser.parse(arguments, strict: @switches, aliases: @aliases)

    if options[:help] do
      Mix.shell().info(@moduledoc)
    else
      enroll(options, positional, invalid)
    end
  end

  defp enroll(options, positional, invalid) do
    reject!(positional, invalid)

    file =
      options[:file] || System.get_env("BIOT_NODE_REGISTRATIONS") ||
        Mix.raise("--file is required")

    registration_id = registration_id!(required!(options, :registration_id, "--registration-id"))
    max_biots = max_biots!(options[:max_biots])
    peer_identity = peer_identity!(options)

    entries = read!(file)
    node_id = node_id!(options, entries, registration_id)

    entry = %{
      "node_id" => to_string(node_id),
      "registration_id" => to_string(registration_id),
      "peer_identity" => peer_identity,
      "max_biots" => max_biots,
      "status" => status(entries, registration_id)
    }

    validate!(entry, file)
    write!(file, Enrollment.upsert(entries, entry))
    report(file, entry)
  end

  defp reject!([], []), do: :ok

  defp reject!(_positional, [{option, _value} | _rest]) do
    Mix.raise("unknown option #{option}")
  end

  defp reject!([argument | _rest], []), do: Mix.raise("unexpected argument #{argument}")

  defp required!(options, key, flag) do
    options[key] || Mix.raise("#{flag} is required")
  end

  defp registration_id!(value) do
    case RegistrationId.parse(value) do
      {:ok, registration_id} ->
        registration_id

      {:error, :invalid_format} ->
        Mix.raise("a registration id must be a lowercase canonical UUID")
    end
  end

  defp max_biots!(value) when is_integer(value) and value > 0, do: value
  defp max_biots!(_value), do: Mix.raise("--max-biots must be a positive integer")

  defp peer_identity!(options) do
    sources =
      [
        options[:fingerprint] && {:fingerprint, options[:fingerprint]},
        options[:name] && {:name, options[:name]}
      ]
      |> Enum.reject(&is_nil/1)

    case sources do
      [{:fingerprint, value}] -> fingerprint!(value)
      [{:name, name}] -> certificate_fingerprint!(name, options[:certs_dir] || @default_certs_dir)
      [] -> Mix.raise("give --fingerprint or --name so the node certificate identity is known")
      _both -> Mix.raise("give only one of --fingerprint and --name")
    end
  end

  defp fingerprint!(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value) do
      value
    else
      Mix.raise("a certificate fingerprint must be 64 lowercase hex characters")
    end
  end

  defp certificate_fingerprint!(name, certs_dir) do
    case Hostname.parse(name) do
      {:ok, label} ->
        path = Path.join(certs_dir, "node-#{label}-cert.pem")

        case Certificates.fingerprint(path) do
          {:ok, fingerprint} ->
            fingerprint

          {:error, :missing_certificate} ->
            Mix.raise("no certificate at #{path}; run mix biot.certs node #{certs_dir} #{label}")

          {:error, :malformed_certificate} ->
            Mix.raise("the certificate at #{path} could not be read")
        end

      {:error, :invalid_format} ->
        Mix.raise("a node name is a lowercase DNS label")
    end
  end

  defp node_id!(options, entries, registration_id) do
    cond do
      options[:node_id] ->
        parse_node_id!(options[:node_id])

      entry = Enrollment.find(entries, to_string(registration_id)) ->
        parse_node_id!(entry["node_id"])

      true ->
        NodeId.generate()
    end
  end

  defp parse_node_id!(value) do
    case NodeId.parse(value) do
      {:ok, node_id} -> node_id
      {:error, :invalid_format} -> Mix.raise("a node id must be a lowercase canonical UUID")
    end
  end

  defp status(entries, registration_id) do
    case Enrollment.find(entries, to_string(registration_id)) do
      %{"status" => status} -> status
      _new_entry -> "enabled"
    end
  end

  defp read!(file) do
    case File.read(file) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, entries} when is_list(entries) ->
            Enum.each(entries, &validate_existing!(&1, file))
            entries

          {:ok, _other} ->
            Mix.raise("#{file} must hold a JSON list")

          {:error, error} ->
            Mix.raise("#{file} contains invalid JSON: #{Exception.message(error)}")
        end

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Mix.raise("could not read #{file}: #{:file.format_error(reason)}")
    end
  end

  defp validate_existing!(entry, file) do
    case Enrollment.validate(entry) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("#{file} has an entry the server would reject: #{inspect(reason)}")
    end
  end

  defp validate!(entry, file) do
    case Enrollment.validate(entry) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("#{file} would get an entry the server would reject: #{inspect(reason)}")
    end
  end

  defp write!(file, entries) do
    directory = Path.dirname(file)
    temporary = file <> ".new"
    File.mkdir_p!(directory)
    File.write!(temporary, Jason.encode!(entries, pretty: true) <> "\n")
    File.chmod!(temporary, mode(file))
    File.rename!(temporary, file)
  end

  defp mode(file) do
    case File.stat(file) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o777)
      {:error, _reason} -> 0o640
    end
  end

  defp report(file, entry) do
    Mix.shell().info("Wrote #{file}:")
    Mix.shell().info(Jason.encode!(entry, pretty: true))
    Mix.shell().info("")
    Mix.shell().info("Set BIOT_NODE_REGISTRATION_ID=#{entry["registration_id"]} on the node.")
    Mix.shell().info("Reimport on a running server with:")
    Mix.shell().info(~s|  /opt/biot/server/bin/server rpc "Biot.Server.Nodes.reload()"|)
  end
end
