defmodule Biot.Node.Host.SourceStaging do
  @moduledoc """
  The trusted fetch phase: resolves a selection's moving refs and stages every input one build
  needs inside the Biot's own store.

  One worker run does all of it, because the pins and the staged copies have to be the same act:
  a revision the node recorded without the content behind it would send the user evaluation back
  to the network. The worker writes one out-link, `staged`, and that link is both the garbage
  collection root for every staged input and the record the node reads back.

  `Biot.Node.Host.StagedInputs` owns what that file means; this module owns getting it written and
  reading it back. Inspection, fetch completion, and preparation all take the same parsed value.

  Source credentials belong to this phase alone. The include file is rewritten before every fetch,
  so a credential delivered since the last one is in force and a removed one is not, and the build
  phase never runs in the same container to inherit either.
  """

  alias Biot.Node.Allocation
  alias Biot.Node.Diagnostic
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Context
  alias Biot.Node.Host.EnvironmentInspection
  alias Biot.Node.Host.FetchCredentials
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Git
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.Podman
  alias Biot.Node.Host.PrivateStore
  alias Biot.Node.Host.StagedInputs
  alias Biot.Node.Host.Worker
  alias Biot.Node.Host.Worker.Layout
  alias Biot.Node.InspectionFailure
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.EnvironmentId
  alias Biot.Protocol.EnvironmentSelection
  alias Biot.Protocol.Platform
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SourceSelector

  @doc "Stages this release's build support so a worker can read a copy that cannot change under it."
  @spec stage_build_support(Config.t(), BiotId.t()) :: :ok | {:error, Outcome.t()}
  def stage_build_support(config, biot_id) do
    destination = Paths.build_support(config, biot_id)

    with :ok <- FileSystem.remove_tree(destination),
         :ok <- File.mkdir_p(destination),
         :ok <- copy_support_trees(config, destination) do
      :ok
    else
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  @doc "Runs the fetch worker for one environment and returns what it staged."
  @spec fetch(Context.t(), Allocation.t(), EnvironmentId.t(), EnvironmentSelection.t()) ::
          {:ok, StagedInputs.t()} | {:error, Outcome.t()}
  def fetch(
        %Context{biot_id: biot_id, config: config} = context,
        allocation,
        environment_id,
        selection
      ) do
    with :ok <- stage_build_support(config, biot_id),
         :ok <- FetchCredentials.write_include(config, allocation),
         :ok <- ensure_environment_directory(config, allocation, environment_id),
         {:ok, result} <-
           Worker.run(
             context,
             allocation,
             {:fetch, environment_id},
             arguments(config, environment_id, selection)
           ),
         :ok <- succeeded(result, config, selection) do
      read(config, biot_id, environment_id)
    end
  end

  @doc """
  What one environment's fetch phase staged, read back from the out-link that retains it.

  Reading it is also what proves those inputs are still in the private store, because the file
  lives inside the store object the out-link roots.
  """
  @spec read(Config.t(), BiotId.t(), EnvironmentId.t()) ::
          {:ok, StagedInputs.t()} | {:error, Outcome.t()}
  def read(config, biot_id, environment_id) do
    case staged(config, biot_id, environment_id) do
      {:present, staged} -> {:ok, staged}
      :absent -> {:error, Outcome.new(:resolution_failed, staged_missing())}
      {:unknown, failure} -> {:error, Outcome.from_reason(failure)}
    end
  end

  @doc """
  Whether one environment's staged inputs are still readable, as a resolution fact.

  Staged inputs that are gone, or that no longer parse, are a lost resolution, which the node
  fixes by staging them again. A store it could not look in is unknown, which is not the same
  thing and must not become one.
  """
  @spec staged_fact(Config.t(), BiotId.t(), EnvironmentId.t()) ::
          EnvironmentInspection.resolution_fact()
  def staged_fact(config, biot_id, environment_id) do
    case staged(config, biot_id, environment_id) do
      {:present, _staged} -> :present
      :absent -> :absent
      {:unknown, failure} -> {:unknown, failure}
    end
  end

  @typedoc "One inspection of an environment's staged inputs."
  @type fact :: :absent | {:present, StagedInputs.t()} | {:unknown, InspectionFailure.t()}

  @spec staged(Config.t(), BiotId.t(), EnvironmentId.t()) :: fact()
  defp staged(config, biot_id, environment_id) do
    link = Paths.staged(config, biot_id, environment_id)

    case PrivateStore.object_at(config, biot_id, link) do
      {:present, path} -> pins(Path.join(path, "pins.json"))
      :absent -> :absent
      {:error, reason} -> {:unknown, unreadable(reason)}
    end
  end

  defp pins(path) do
    case FileSystem.read(path) do
      {:present, content} -> parsed(content)
      :absent -> :absent
      {:error, reason} -> {:unknown, unreadable(reason)}
    end
  end

  # Staged inputs whose pins do not parse are as unusable as missing ones, and staging them again
  # is what fixes both.
  defp parsed(content) do
    with {:ok, value} <- Jason.decode(content),
         {:ok, staged} <- StagedInputs.parse(value) do
      {:present, staged}
    else
      _error -> :absent
    end
  end

  defp unreadable(reason) do
    Outcome.inspection(
      :resolution,
      reason,
      Diagnostic.text("the environment's staged inputs could not be inspected")
    )
  end

  defp arguments(config, environment_id, selection) do
    [
      "nix",
      "build",
      "--impure",
      "--expr",
      "import #{Layout.build_support()}/nix/fetch.nix",
      "--argstr",
      "selection",
      Jason.encode!(encode_selection(config, selection)),
      "--arg",
      "buildSupport",
      Layout.build_support(),
      "--argstr",
      "system",
      Platform.to_string(config.platform),
      "--out-link",
      Layout.staged_link(environment_id)
    ] ++ Layout.store_arguments()
  end

  defp encode_selection(config, %EnvironmentSelection{} = selection) do
    %{
      "base_nixpkgs" => encode_selector(config, selection.base_nixpkgs),
      "layers" => Enum.map(selection.layers, &encode_selector(config, &1))
    }
  end

  defp encode_selector(config, %SourceSelector{source: :nixpkgs}) do
    %{"url" => config.nixpkgs_repository, "ref" => config.nixpkgs_ref}
  end

  defp encode_selector(_config, %SourceSelector{source: {:git, repository, ref}}) do
    %{"url" => RepositorySource.to_string(repository), "ref" => ref}
  end

  defp succeeded(%Command.Result{status: 0}, _config, _selection), do: :ok

  # The worker prints one stream for the whole phase, so which source stopped it is only in the
  # message. `Host.Git` owns reading that; a message about no source this selection named is an
  # ordinary resolution failure.
  defp succeeded(%Command.Result{} = result, config, selection) do
    case Git.authentication_failure(result.stdout <> result.stderr, sources(config, selection)) do
      {:credential_required, source} -> {:waiting_for, source}
      :none -> {:error, Outcome.from_command(:resolution_failed, result)}
    end
  end

  # Every repository this fetch could have reached, as parsed values, including the base package
  # set the operator configured rather than the selection named.
  defp sources(config, %EnvironmentSelection{} = selection) do
    [selection.base_nixpkgs | selection.layers]
    |> Enum.flat_map(&source(config, &1))
  end

  defp source(config, %SourceSelector{source: :nixpkgs}) do
    case RepositorySource.parse(config.nixpkgs_repository) do
      {:ok, repository} -> [repository]
      {:error, _reason} -> []
    end
  end

  defp source(_config, %SourceSelector{source: {:git, repository, _ref}}), do: [repository]

  # The worker writes its out-link inside this directory, so the allocation owns it; the node keeps
  # the directory above it, which is what lets release remove one environment.
  defp ensure_environment_directory(config, allocation, environment_id) do
    path = Paths.environment(config, allocation.biot_id, environment_id)

    case File.mkdir_p(path) do
      :ok -> Podman.grant(config, allocation, [path])
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  # Outside a release the build support trees are links to the source checkout; a release copies
  # the linked files in, so following links gives the same bytes either way.
  defp copy_support_trees(config, destination) do
    Enum.reduce_while(["nix", "agent"], :ok, fn tree, :ok ->
      source = Path.join(config.build_support_dir, tree)

      case File.cp_r(source, Path.join(destination, tree), dereference_symlinks: true) do
        {:ok, _copied} -> {:cont, :ok}
        {:error, reason, _path} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp staged_missing, do: Diagnostic.text("the environment's staged inputs are absent")
end
