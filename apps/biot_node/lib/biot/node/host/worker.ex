defmodule Biot.Node.Host.Worker do
  @moduledoc """
  Runs one allocation's disposable Nix build worker, and the one container that proves at startup
  that this host can sandbox a build.

  Every evaluation, fetch, build, and store collection a Biot needs happens inside a container
  started from the operator's pinned builder image, under the allocation's UID range and on the
  allocation's isolated network. The node never runs Nix itself, so a user expression that reads
  an absolute path reads the worker's filesystem, which holds only that Biot's store, the inputs
  its resolution staged, and its scratch.

  One allocation has one worker name, and the phase is a label. Recovery finds a survivor by name
  without knowing what it was doing, which is the whole reason the model needs no worker adoption
  or completion protocol.

  Two functions divide the subject. `state/2` asks what holds that name right now and changes
  nothing. `cancel/2` ends what it finds and confirms the absence before returning; it is
  destructive, and every caller of it is about to write the private store, remove it, or release
  the range under it.

  One lifecycle serves both a worker and the startup probe: cancel whatever holds the name, start,
  and cancel again whatever the command did. A container found under a name is only ended when its
  labels say it is the thing that name is for, so a foreign container is an ownership failure
  rather than something to remove.

  Cancellation has two halves. A live caller's `Biot.Node.Host.Command.cancel/1` ends the
  `podman run` process group but leaves this process alive, so the cleanup half still runs. A
  caller that dies without reaching it leaves the container to the next `cancel/2`, which every
  writer and every controller restart performs first.

  Invariant: the private store is a Nix chroot store whose root is `Layout.store_root/0` in the
  worker, and its logical store directory is `/nix/store`. Every path the worker writes, every
  path a bundle names, and every binary cache substitute it accepts is therefore `/nix/store/...`,
  which is what makes the shared cache usable at all. The physical directory cannot also be
  mounted at `/nix/store` here, because that is where the builder image keeps the Nix that does
  the work; a runtime has no such problem and mounts it at `/nix/store`, read only.
  """

  alias Biot.Node.Allocation
  alias Biot.Node.Diagnostic
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Context
  alias Biot.Node.Host.Diagnostic, as: HostDiagnostic
  alias Biot.Node.Host.Git
  alias Biot.Node.Host.Names
  alias Biot.Node.Host.Network
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.Podman
  alias Biot.Node.Host.Worker.Layout
  alias Biot.Protocol.BiotId

  @typedoc "What a worker is doing, and to which environment. `Layout` decides what it can see."
  @type phase :: Layout.phase()

  defmodule Spec do
    @moduledoc """
    One worker container: what it is called, what it may see, and what it runs.

    Every worker the node starts is described here first, including the one that proves at startup
    that this host can sandbox a build. A spec with no allocation has no user range, no network,
    and none of an allocation's mounts; everything else about it is the same container, so a
    change to the boundary cannot leave startup green while real work fails.
    """

    alias Biot.Node.Host.Paths

    @enforce_keys [:name, :labels, :uid_map, :network, :mounts, :tmpfs, :command]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            name: String.t(),
            labels: [String.t()],
            uid_map: String.t() | nil,
            network: String.t(),
            mounts: [Paths.mount()],
            tmpfs: [String.t()],
            command: [String.t()]
          }
  end

  @typedoc """
  What holds a worker name right now. `foreign` is a container that holds the name without
  claiming to be what that name is for, which only a person can resolve.
  """
  @type state :: :absent | :owned | :foreign | {:unknown, Outcome.t()}

  @typedoc "What a name is for. The labels of the container holding it have to agree."
  @type claim :: {:worker, BiotId.t()} | :probe

  @doc "Ends this allocation's build worker and confirms it is gone."
  @spec cancel(Config.t(), BiotId.t()) :: :ok | {:error, Outcome.t()}
  def cancel(config, biot_id), do: cancel_claim(config, {:worker, biot_id})

  defp cancel_claim(config, claim) do
    case claimed_state(config, claim) do
      :absent -> :ok
      :owned -> remove(config, claim)
      :foreign -> {:error, Outcome.new(:ownership_mismatch)}
      {:unknown, outcome} -> {:error, outcome}
    end
  end

  @doc """
  Runs one command in a fresh worker and returns what it printed.

  The result is a value, not a success: an evaluation or build that fails is an expected failure
  whose output is the diagnostic an owner reads.
  """
  @spec run(Context.t(), Allocation.t(), phase(), [String.t()]) ::
          {:ok, Command.Result.t()} | {:error, Outcome.t()}
  def run(
        %Context{biot_id: biot_id, config: config},
        %Allocation{biot_id: biot_id} = allocation,
        phase,
        arguments
      ) do
    claim = {:worker, biot_id}

    with :ok <- cancel_claim(config, claim),
         :ok <- ensure_network(config, allocation) do
      config
      |> start(spec(config, allocation, phase, arguments))
      |> finish(config, claim)
    end
  end

  defp spec(config, allocation, phase, command) do
    %Spec{
      name: Names.worker(allocation.biot_id),
      labels: Names.worker_label_arguments(allocation.biot_id, Layout.phase_name(phase)),
      uid_map: uid_map(config, allocation),
      network: Names.network(allocation.network_id),
      mounts: Layout.mounts(config, allocation.biot_id, phase),
      tmpfs: Layout.image_tmpfs(),
      command: command
    }
  end

  # The worker ends with its command whatever the command did. A cancelled command returns control
  # here instead of a status, and that is the path that has to remove the container, because the
  # caller asked for the work to stop and the container is the work.
  defp finish(result, config, claim) do
    case {result, cancel_claim(config, claim)} do
      {{:ok, value}, :ok} -> {:ok, value}
      {{:ok, _value}, {:error, outcome}} -> {:error, outcome}
      {{:error, outcome}, _absence} -> {:error, outcome}
    end
  end

  @doc """
  Runs one command in a worker with no allocation behind it, and returns what it printed.

  Startup uses this to find out whether this host can sandbox a build before the node accepts any
  work. The caller owns what to run and what the result means; the container it runs in is the
  same one every build gets.
  """
  @spec probe(Config.t(), [String.t()]) ::
          {:ok, Command.Result.t()} | {:error, Outcome.t()}
  def probe(config, command) do
    with :ok <- cancel_claim(config, :probe) do
      config
      |> start(probe_spec(config, command))
      |> finish(config, :probe)
    end
  end

  defp probe_spec(config, command) do
    %Spec{
      name: Names.worker_probe(),
      labels: Names.probe_label_arguments(),
      uid_map: nil,
      network: "none",
      mounts: [{Paths.worker_nix_config(config), Layout.nix_config(), :ro}],
      tmpfs: [Layout.store_root() | Layout.image_tmpfs()],
      command: command ++ Layout.store_arguments()
    }
  end

  @spec state(Config.t(), BiotId.t()) :: state()
  def state(config, biot_id), do: claimed_state(config, {:worker, biot_id})

  defp claimed_state(config, claim) do
    case Podman.run(config, ["inspect", "--type", "container", name(claim)]) do
      {:ok, %Command.Result{status: 0, stdout: stdout}} ->
        parse_inspection(stdout, claim)

      {:ok, %Command.Result{} = result} ->
        if Podman.absent?(:container, result),
          do: :absent,
          else: unknown(HostDiagnostic.from_command(result))

      {:error, reason} ->
        unknown(Diagnostic.text("Podman could not inspect the build worker: #{inspect(reason)}"))
    end
  end

  defp start(config, %Spec{} = spec) do
    case Podman.run(config, podman_arguments(config, spec), timeout_ms: config.worker_timeout_ms) do
      {:ok, %Command.Result{} = result} -> {:ok, result}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  # Both isolation options are needed and neither is enough alone. Without an unmasked `/proc` the
  # build cannot mount its own and Nix reports that the kernel namespaces are unsupported; with it
  # but without `SYS_ADMIN` the build gets as far as naming its sandbox host and fails there.
  # Both act only within the worker's user namespace, over the allocation's mapped range.
  #
  # The image root is read only: a worker's writable state is the mounts it was given, and the
  # image paths Nix still writes to get a fresh tmpfs each run.
  defp podman_arguments(config, %Spec{} = spec) do
    [
      "run",
      "--name",
      spec.name,
      "--rm",
      "--read-only",
      "--network",
      spec.network,
      "--security-opt",
      "unmask=/proc/*",
      "--cap-add",
      "SYS_ADMIN",
      "--log-driver",
      "none"
    ] ++
      tmpfs_arguments(spec.tmpfs) ++
      uid_map_arguments(spec.uid_map) ++
      spec.labels ++
      environment_arguments() ++
      volume_arguments(spec.mounts) ++
      [config.builder_image | spec.command]
  end

  defp tmpfs_arguments(paths) do
    Enum.flat_map(paths, fn path -> ["--tmpfs", "#{path}:rw"] end)
  end

  defp uid_map_arguments(nil), do: []

  defp uid_map_arguments(uid_map) do
    ["--uidmap", uid_map, "--gidmap", uid_map]
  end

  defp environment_arguments do
    Enum.flat_map(Layout.variables() ++ Git.environment(), fn {name, value} ->
      ["--env", "#{name}=#{value}"]
    end)
  end

  defp volume_arguments(mounts) do
    Enum.flat_map(mounts, fn {source, target, mode} ->
      ["--volume", "#{source}:#{target}:#{mode}"]
    end)
  end

  defp uid_map(config, allocation) do
    first_subordinate_id = Allocation.subordinate_start(allocation, config.uid_range_base)
    "0:#{first_subordinate_id}:#{allocation.uid_range.count}"
  end

  defp ensure_network(config, allocation) do
    case Network.ensure(config, allocation.network_id) do
      :ok -> :ok
      {:error, %Outcome{} = outcome} -> {:error, outcome}
    end
  end

  defp name({:worker, biot_id}), do: Names.worker(biot_id)
  defp name(:probe), do: Names.worker_probe()

  defp remove(config, claim) do
    case Podman.run(config, ["rm", "--force", name(claim)]) do
      {:ok, %Command.Result{status: 0}} ->
        confirm_absent(config, claim)

      {:ok, %Command.Result{} = result} ->
        {:error, Outcome.from_command(:host_unavailable, result)}

      {:error, reason} ->
        {:error, Outcome.from_reason(reason)}
    end
  end

  # Removal reporting success is not the same fact as the worker being gone, and the writer that
  # follows depends on the second one.
  defp confirm_absent(config, claim) do
    case claimed_state(config, claim) do
      :absent ->
        :ok

      {:unknown, outcome} ->
        {:error, outcome}

      present when present in [:owned, :foreign] ->
        {:error,
         Outcome.new(:host_unavailable, Diagnostic.text("the build worker is still present"))}
    end
  end

  defp parse_inspection(stdout, claim) do
    case Jason.decode(stdout) do
      {:ok, [%{"Config" => %{"Labels" => labels}}]} -> claimed?(labels, claim)
      _error -> unknown(Diagnostic.text("Podman returned invalid container JSON"))
    end
  end

  defp claimed?(labels, {:worker, biot_id}) do
    case {Names.role(labels), Names.owner(labels)} do
      {{:ok, :worker}, {:ok, ^biot_id}} -> :owned
      _other -> :foreign
    end
  end

  defp claimed?(labels, :probe) do
    case Names.role(labels) do
      {:ok, :probe} -> :owned
      _other -> :foreign
    end
  end

  defp unknown(detail), do: {:unknown, Outcome.new(:host_unavailable, detail)}
end
