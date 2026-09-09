defmodule Biot.Node.Host.Environment do
  @moduledoc "Inspects, resolves, prepares, installs, and releases Biot-owned environments."

  alias Biot.Node.Allocation
  alias Biot.Node.ArtifactId
  alias Biot.Node.EnvironmentBundle
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Context
  alias Biot.Node.Host.EnvironmentInspection
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.SourceResolver
  alias Biot.Node.Installation
  alias Biot.Node.Journal
  alias Biot.Node.NodePrivatePath
  alias Biot.Node.Resolution
  alias Biot.Node.StorePath
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.Platform

  @spec resolutions(Config.t(), [Resolution.t()]) :: %{
          EnvironmentId.t() => Biot.Node.NodeState.resolution_state()
        }
  def resolutions(_config, rows) do
    rows
    |> Enum.map(&{&1, resolution_fact(&1)})
    |> EnvironmentInspection.resolutions()
  end

  @spec prepared(Config.t(), [Resolution.t()]) :: Biot.Node.NodeState.resource(map())
  def prepared(config, rows) do
    rows
    |> Enum.map(&{&1.environment_id, artifact(config, &1.environment_id)})
    |> EnvironmentInspection.prepared()
  end

  @spec installation(Installation.t() | nil, Biot.Node.NodeState.resource(map())) ::
          Biot.Node.NodeState.installation_state()
  defdelegate installation(installation, prepared), to: EnvironmentInspection

  @spec resolve(
          Context.t(),
          EnvironmentId.t(),
          EnvironmentSelection.t(),
          Allocation.t()
        ) :: :ok | {:error, Outcome.t()}
  def resolve(
        %Context{biot_id: biot_id} = context,
        environment_id,
        selection,
        %Allocation{biot_id: biot_id}
      ) do
    case Journal.resolution(biot_id, environment_id) do
      %Resolution{} -> :ok
      nil -> create_resolution(context, environment_id, selection)
    end
  end

  @spec prepare(Context.t(), EnvironmentId.t(), Manifest.t()) ::
          :ok | {:error, Outcome.t()}
  def prepare(%Context{config: config}, environment_id, manifest) do
    with {:ok, _directory} <- ensure_environment_directory(config, environment_id),
         {:ok, _manifest} <- persist_manifest(config, environment_id, manifest),
         {:ok, _build} <- build(config, environment_id),
         {:ok, _artifact_id} <- built_artifact(config, environment_id) do
      :ok
    end
  end

  @spec install(Context.t(), Allocation.t(), ArtifactId.t(), EnvironmentId.t()) ::
          :ok | {:error, Outcome.t()}
  def install(
        %Context{biot_id: biot_id},
        %Allocation{biot_id: biot_id} = allocation,
        artifact_id,
        environment_id
      ) do
    case Journal.put_installation(allocation, environment_id, artifact_id) do
      {:ok, _installation} -> :ok
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  @spec release(Context.t(), EnvironmentId.t()) :: :ok | {:error, Outcome.t()}
  def release(%Context{biot_id: biot_id, config: config}, environment_id) do
    case Journal.resolution_owner(environment_id) do
      nil ->
        release_unrecorded_environment(config, environment_id)

      ^biot_id ->
        with {:ok, _removed} <- remove_environment(config, environment_id),
             {:ok, _records} <- delete_environment_records(biot_id, environment_id) do
          :ok
        end

      _other_biot_id ->
        {:error, Outcome.new(:ownership_mismatch, "another biot owns the environment")}
    end
  end

  @spec bundle(Config.t(), EnvironmentId.t()) ::
          {:ok, EnvironmentBundle.t()} | {:error, Outcome.t()}
  def bundle(config, environment_id) do
    path = Path.join(Paths.environment_root(config, environment_id), "bundle.json")

    case FileSystem.read(path) do
      {:present, content} -> parse_bundle(content)
      :absent -> {:error, Outcome.new(:host_unavailable, "the prepared bundle is absent")}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp create_resolution(context, environment_id, selection) do
    with {:ok, manifest} <- pin_manifest(context.config, selection),
         {:ok, _resolution} <- record_resolution(context.biot_id, environment_id, manifest) do
      :ok
    end
  end

  defp pin_manifest(config, selection) do
    with {:ok, base_nixpkgs} <- SourceResolver.pin(config, selection.base_nixpkgs),
         {:ok, layers} <- pin_layers(config, selection.layers) do
      {:ok, Manifest.build(base_nixpkgs, layers, nil)}
    end
  end

  defp pin_layers(config, selectors) do
    Enum.reduce_while(selectors, {:ok, []}, fn selector, {:ok, pinned} ->
      case SourceResolver.pin(config, selector) do
        {:ok, source} -> {:cont, {:ok, [source | pinned]}}
        {:error, %Outcome{} = outcome} -> {:halt, {:error, outcome}}
      end
    end)
    |> reverse_pins()
  end

  defp reverse_pins({:ok, reversed}), do: {:ok, Enum.reverse(reversed)}
  defp reverse_pins({:error, %Outcome{} = outcome}), do: {:error, outcome}

  defp record_resolution(biot_id, environment_id, manifest) do
    case Journal.put_resolution(biot_id, environment_id, manifest) do
      {:ok, resolution} ->
        {:ok, resolution}

      {:error, :stale} ->
        {:ok, :stale}

      {:error, :ownership_mismatch} ->
        {:error, Outcome.new(:ownership_mismatch, "another biot owns the environment")}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp ensure_environment_directory(config, environment_id) do
    case File.mkdir_p(Paths.environment(config, environment_id)) do
      :ok -> {:ok, :directory}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp persist_manifest(config, environment_id, manifest) do
    case FileSystem.write_atomic(
           Paths.manifest(config, environment_id),
           encoded_manifest(manifest)
         ) do
      :ok -> {:ok, :manifest}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp build(config, environment_id) do
    result =
      Command.run(
        config.setsid_executable,
        config.nix_executable,
        [
          "build",
          "--extra-experimental-features",
          "nix-command",
          "--file",
          config.nix_build_file,
          "--argstr",
          "manifest",
          Paths.manifest(config, environment_id),
          "--argstr",
          "system",
          Platform.to_string(config.platform),
          "--out-link",
          Paths.environment_root(config, environment_id)
        ],
        timeout_ms: config.command_timeout_ms,
        max_output_bytes: config.command_max_output_bytes
      )

    case result do
      {:ok, %Command.Result{status: 0}} ->
        {:ok, :built}

      {:ok, %Command.Result{} = command_result} ->
        {:error, Outcome.from_command(:build_failed, command_result)}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp built_artifact(config, environment_id) do
    case artifact(config, environment_id) do
      {:present, artifact_id} ->
        {:ok, artifact_id}

      :absent ->
        {:error, Outcome.new(:build_failed, "nix build did not create its output link")}

      {:error, {_reason, detail}} ->
        {:error, Outcome.new(:host_unavailable, detail)}
    end
  end

  defp artifact(config, environment_id) do
    root = Paths.environment_root(config, environment_id)

    case FileSystem.directory(root) do
      {:present, :directory} -> parse_artifact(root)
      :absent -> :absent
      {:error, reason} -> {:error, {reason, "the environment root could not be inspected"}}
    end
  end

  defp parse_artifact(root) do
    path = Path.join(root, "bundle.json")

    case FileSystem.read(path) do
      {:present, content} -> parse_artifact_content(content)
      :absent -> {:error, {:unreadable, "the environment bundle is absent"}}
      {:error, reason} -> {:error, {reason, "the environment bundle could not be read"}}
    end
  end

  defp parse_artifact_content(content) do
    with {:ok, value} <- Jason.decode(content),
         {:ok, bundle} <- EnvironmentBundle.parse(value),
         {:ok, artifact_id} <- ArtifactId.parse(StorePath.to_string(bundle.closure_root)) do
      {:present, artifact_id}
    else
      _error -> {:error, {:unreadable, "the environment bundle is invalid"}}
    end
  end

  defp parse_bundle(content) do
    with {:ok, value} <- Jason.decode(content),
         {:ok, bundle} <- EnvironmentBundle.parse(value) do
      {:ok, bundle}
    else
      _error -> {:error, Outcome.new(:invalid_configuration, "the prepared bundle is invalid")}
    end
  end

  defp resolution_fact(%Resolution{snapshot_path: nil}), do: :not_needed

  defp resolution_fact(%Resolution{snapshot_path: snapshot_path}) do
    snapshot_path |> NodePrivatePath.to_string() |> FileSystem.directory()
  end

  defp remove_environment(config, environment_id) do
    case FileSystem.remove_tree(Paths.environment(config, environment_id)) do
      :ok -> {:ok, :removed}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp release_unrecorded_environment(config, environment_id) do
    case FileSystem.directory(Paths.environment(config, environment_id)) do
      :absent ->
        :ok

      {:present, :directory} ->
        {:error,
         Outcome.new(:host_unavailable, "the environment directory has no ownership record")}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp delete_environment_records(biot_id, environment_id) do
    case Journal.delete_environment(biot_id, environment_id) do
      :ok -> {:ok, :deleted}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  defp encoded_manifest(manifest), do: Jason.encode_to_iodata!(Manifest.encode(manifest))
end
