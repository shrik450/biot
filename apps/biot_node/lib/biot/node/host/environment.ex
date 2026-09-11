defmodule Biot.Node.Host.Environment do
  @moduledoc """
  Inspects, resolves, prepares, installs, and releases one Biot's environments.

  Every Nix action runs in that Biot's own build worker, so nothing here starts Nix on the node.
  Resolution stages the inputs, preparation evaluates them, and release gives back both the
  directory that held them and the store space the collection frees.

  An environment lives under the allocation, so releasing one is removing a directory inside the
  Biot's own root. Ownership is still checked against the journal, because the records outlive the
  directory and a cross-Biot selection must fail before anything is removed.
  """

  alias Biot.Node.Allocation
  alias Biot.Node.ArtifactId
  alias Biot.Node.Diagnostic
  alias Biot.Node.EnvironmentBundle
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Context
  alias Biot.Node.Host.EnvironmentInspection
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.Podman
  alias Biot.Node.Host.PrivateStore
  alias Biot.Node.Host.SourceStaging
  alias Biot.Node.Host.StagedInputs
  alias Biot.Node.Host.Worker
  alias Biot.Node.Host.Worker.Layout
  alias Biot.Node.Installation
  alias Biot.Node.Journal
  alias Biot.Node.NodeState
  alias Biot.Node.Resolution
  alias Biot.Node.StorePath
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.Manifest
  alias Biot.Protocol.Platform

  @spec resolutions(Config.t(), BiotId.t(), [Resolution.t()]) :: %{
          EnvironmentId.t() => NodeState.resolution_state()
        }
  def resolutions(config, biot_id, rows) do
    rows
    |> Enum.map(&{&1, SourceStaging.staged_fact(config, biot_id, &1.environment_id)})
    |> EnvironmentInspection.resolutions()
  end

  @spec prepared(Config.t(), BiotId.t(), [Resolution.t()]) :: NodeState.prepared()
  def prepared(config, biot_id, rows) do
    rows
    |> Enum.map(&{&1.environment_id, artifact(config, biot_id, &1.environment_id)})
    |> EnvironmentInspection.prepared()
  end

  @spec installation(Installation.t() | nil, NodeState.prepared()) ::
          NodeState.installation_state()
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
        %Allocation{biot_id: biot_id} = allocation
      ) do
    case Journal.resolution(biot_id, environment_id) do
      %Resolution{} -> :ok
      nil -> create_resolution(context, allocation, environment_id, selection)
    end
  end

  @doc """
  Builds one environment's bundle from the inputs its resolution staged, and nothing else.

  The manifest the action carries says what the server believes was resolved; the staged inputs
  say what this Biot's store actually holds. Only the second can be built from, so only the second
  reaches the worker.
  """
  @spec prepare(Context.t(), EnvironmentId.t(), Manifest.t(), Allocation.t()) ::
          :ok | {:error, Outcome.t()}
  def prepare(
        %Context{biot_id: biot_id, config: config} = context,
        environment_id,
        %Manifest{},
        %Allocation{biot_id: biot_id} = allocation
      ) do
    with {:ok, staged} <- SourceStaging.read(config, biot_id, environment_id),
         mounts = staged_mounts(config, biot_id, staged),
         {:ok, result} <-
           Worker.run(
             context,
             allocation,
             {:build, environment_id, mounts},
             build_arguments(config, environment_id, staged)
           ),
         :ok <- built(result),
         {:ok, _artifact_id} <- built_artifact(config, biot_id, environment_id) do
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

  @doc """
  Gives back one environment's staged inputs, prepared artifact, and store space.

  The order is the only thing that makes a crash survivable. A surviving build worker can still be
  writing this directory, so it goes first. The resolution record goes last, because until the
  collection has run it is the only durable reason to run this action again: remove and collect
  both converge when repeated, but a deleted row leaves nothing to repeat from.
  """
  @spec release(Context.t(), EnvironmentId.t(), Allocation.t()) :: :ok | {:error, Outcome.t()}
  def release(
        %Context{biot_id: biot_id, config: config} = context,
        environment_id,
        %Allocation{biot_id: biot_id} = allocation
      ) do
    case Journal.resolution_owner(environment_id) do
      nil ->
        release_unrecorded_environment(config, biot_id, environment_id)

      ^biot_id ->
        with :ok <- Worker.cancel(config, biot_id),
             {:ok, _removed} <- remove_environment(config, biot_id, environment_id),
             {:ok, _collected} <- collect(context, allocation),
             {:ok, _records} <- delete_environment_records(biot_id, environment_id) do
          :ok
        end

      _other_biot_id ->
        {:error,
         Outcome.new(
           :ownership_mismatch,
           Diagnostic.text("another biot owns the environment")
         )}
    end
  end

  @spec bundle(Config.t(), BiotId.t(), EnvironmentId.t()) ::
          {:ok, EnvironmentBundle.t()} | {:error, Outcome.t()}
  def bundle(config, biot_id, environment_id) do
    case read_bundle(config, biot_id, environment_id) do
      {:present, content} ->
        parse_bundle(content)

      :absent ->
        {:error, Outcome.new(:host_unavailable, Diagnostic.text("the prepared bundle is absent"))}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  defp create_resolution(context, allocation, environment_id, selection) do
    with {:ok, staged} <- SourceStaging.fetch(context, allocation, environment_id, selection),
         {:ok, manifest} <- manifest(staged, selection),
         {:ok, _resolution} <- record_resolution(context.biot_id, environment_id, manifest) do
      :ok
    end
  end

  defp manifest(staged, selection) do
    case StagedInputs.manifest(staged, selection) do
      {:ok, manifest} ->
        {:ok, manifest}

      {:error, :invalid_format} ->
        {:error,
         Outcome.new(
           :resolution_failed,
           Diagnostic.text("the fetch phase staged inputs the selection does not describe")
         )}
    end
  end

  defp record_resolution(biot_id, environment_id, manifest) do
    case Journal.put_resolution(biot_id, environment_id, manifest) do
      {:ok, resolution} ->
        {:ok, resolution}

      {:error, :stale} ->
        {:ok, :stale}

      {:error, :ownership_mismatch} ->
        {:error,
         Outcome.new(
           :ownership_mismatch,
           Diagnostic.text("another biot owns the environment")
         )}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  # `--pure-eval` refuses every absolute path, so each staged input is named by the hash the fetch
  # phase recorded for it, at the mount the node gave it.
  defp build_arguments(config, environment_id, staged) do
    [
      "nix",
      "build",
      "--option",
      "pure-eval",
      "true",
      "--expr",
      build_expression(staged.build_support),
      "--argstr",
      "staged",
      Jason.encode!(encode_staged(staged)),
      "--argstr",
      "system",
      Platform.to_string(config.platform),
      "--out-link",
      Layout.bundle_link(environment_id)
    ] ++ Layout.store_arguments()
  end

  defp build_expression(build_support) do
    ~s|import (#{fetch_tree("build-support", build_support)} + "/nix/build.nix")|
  end

  defp encode_staged(staged) do
    %{
      "nixpkgs" => encode_input("nixpkgs", staged.base_nixpkgs.input),
      "layers" =>
        Enum.with_index(staged.layers, fn source, index ->
          encode_input("layer-#{index}", source.input)
        end)
    }
  end

  defp encode_input(entry, input) do
    %{"path" => staged_path(entry, input), "narHash" => input.nar_hash}
  end

  defp fetch_tree(entry, input) do
    ~s|builtins.fetchTree { type = "path"; path = "#{staged_path(entry, input)}"; | <>
      ~s|narHash = "#{input.nar_hash}"; }|
  end

  defp staged_path(entry, input) do
    Layout.staged_input(entry, StorePath.object_name(input.store_path))
  end

  defp staged_mounts(config, biot_id, staged) do
    Enum.map(StagedInputs.entries(staged), fn {entry, input} ->
      {entry, StorePath.object_name(input.store_path),
       PrivateStore.host_path(config, biot_id, input.store_path)}
    end)
  end

  defp built(%Command.Result{status: 0}), do: :ok

  defp built(%Command.Result{} = result),
    do: {:error, Outcome.from_command(:build_failed, result)}

  defp built_artifact(config, biot_id, environment_id) do
    case artifact(config, biot_id, environment_id) do
      {:present, artifact_id} ->
        {:ok, artifact_id}

      :absent ->
        {:error,
         Outcome.new(
           :build_failed,
           Diagnostic.text("the build worker did not create its output link")
         )}

      {:error, {_reason, detail}} ->
        {:error, Outcome.new(:host_unavailable, Diagnostic.text(detail))}
    end
  end

  defp artifact(config, biot_id, environment_id) do
    case read_bundle(config, biot_id, environment_id) do
      {:present, content} -> parse_artifact_content(content)
      :absent -> :absent
      {:error, reason} -> {:error, {reason, "the environment bundle could not be read"}}
    end
  end

  defp read_bundle(config, biot_id, environment_id) do
    link = Paths.environment_root(config, biot_id, environment_id)

    case PrivateStore.object_at(config, biot_id, link) do
      {:present, path} -> FileSystem.read(Path.join(path, "bundle.json"))
      :absent -> :absent
      {:error, reason} -> {:error, reason}
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
      _error ->
        {:error,
         Outcome.new(
           :invalid_configuration,
           Diagnostic.text("the prepared bundle is invalid")
         )}
    end
  end

  # The worker wrote this tree as the allocation's user, so the node takes ownership back before
  # removing it, the same way it does for working data.
  defp remove_environment(config, biot_id, environment_id) do
    path = Paths.environment(config, biot_id, environment_id)

    with :ok <- Podman.reclaim(config, path),
         :ok <- FileSystem.remove_tree(path) do
      {:ok, :removed}
    else
      {:error, %Outcome{} = outcome} -> {:error, outcome}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  # Removing the out-links leaves their closures unrooted, and only a worker may write the store.
  defp collect(context, allocation) do
    case Worker.run(
           context,
           allocation,
           :collect,
           ["nix", "store", "gc"] ++ Layout.store_arguments()
         ) do
      {:ok, %Command.Result{status: 0}} ->
        {:ok, :collected}

      {:ok, %Command.Result{} = result} ->
        {:error, Outcome.from_command(:host_unavailable, result)}

      {:error, %Outcome{} = outcome} ->
        {:error, outcome}
    end
  end

  defp release_unrecorded_environment(config, biot_id, environment_id) do
    case FileSystem.directory(Paths.environment(config, biot_id, environment_id)) do
      :absent ->
        :ok

      {:present, :directory} ->
        {:error,
         Outcome.new(
           :host_unavailable,
           Diagnostic.text("the environment directory has no ownership record")
         )}

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
end
