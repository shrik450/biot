defmodule Biot.Node.BiotController do
  @moduledoc """
  Owns one biot on this node. It turns durable intent plus host inspection into one host action at
  a time, reports what it inspected, retries what may pass on its own, and stops in a way an
  operator can see when it cannot.

  Every event runs the same loop: inspect the biot's resources, report the observation and any
  resolution the node holds, ask `Reconcile.next/4` for one action, run that action in one linked
  task, and start over when the task finishes. The controller never trusts an effect's account of
  what happened; only the next inspection decides what is true. A crash therefore costs nothing:
  the restarted controller loads the same durable intent from the journal and inspects before it
  acts.

  The controller and its effect share a failure group. The task is linked, so a bug inside an
  effect takes the controller down with it, and the supervisor's restart inspects first.

  One `phase` field says what the controller is doing, and what may wake it:

  - `:idle` waits for a message. Nothing is scheduled, because only a new intent or the next
    synchronization can change what a recorded failure or an offline link decides.
  - `{:running, effect}` has one action in flight. The loop does not ask `Reconcile.next/4` for
    another one until that task finishes.
  - `{:cancelling, effect, wake}` has asked a task to stop, and the wake is the grace period after
    which the task is killed.
  - `{:backing_off, wake}` owes an automatic retry, and the wake is its delay.
  - `{:waiting, reason, wake}` could not read a resource, and the wake looks again.
  - `{:settled, wake}` has nothing to do, and the wake re-inspects on the observation interval,
    which is how the node notices a container that stopped on its own.

  A new desired revision drops a backoff, a wait, and a settled reminder, because they belong to
  the revision that is gone. It never drops a cancellation: the task the controller cancelled is
  still stopping, and its grace period must still end.
  """

  use GenServer

  alias Biot.Node.Action
  alias Biot.Node.Backoff
  alias Biot.Node.BlockReason
  alias Biot.Node.Control
  alias Biot.Node.Controllers
  alias Biot.Node.Diagnostics
  alias Biot.Node.Host
  alias Biot.Node.Host.Command
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Journal
  alias Biot.Node.LocalIntent
  alias Biot.Node.NodeState
  alias Biot.Node.Observation
  alias Biot.Node.Reconcile
  alias Biot.Node.Resolution
  alias Biot.Node.Retry
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.Failure

  defmodule Effect do
    @moduledoc false

    @enforce_keys [:action, :task]
    defstruct [:action, :task]

    @type t :: %__MODULE__{action: Action.t(), task: Task.t()}
  end

  defmodule Wake do
    @moduledoc false

    @enforce_keys [:token, :timer]
    defstruct [:token, :timer]

    @type t :: %__MODULE__{token: reference(), timer: reference()}
  end

  defmodule State do
    @moduledoc false

    @settings [
      :retry_budget,
      :retry_backoff_min_ms,
      :retry_backoff_max_ms,
      :observation_interval_ms,
      :inspection_retry_ms,
      :cancel_grace_ms
    ]

    @enforce_keys [:biot_id, :context, :spec] ++ @settings
    defstruct @enforce_keys ++
                [
                  phase: :idle,
                  pending_exit: nil,
                  failure: nil,
                  attempts: %{}
                ]

    @type phase ::
            :idle
            | {:running, Effect.t()}
            | {:cancelling, Effect.t(), Wake.t()}
            | {:backing_off, Wake.t()}
            | {:waiting, BlockReason.t(), Wake.t()}
            | {:settled, Wake.t()}

    @spec settings() :: [atom()]
    def settings, do: @settings
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    biot_id = Keyword.fetch!(options, :biot_id)
    GenServer.start_link(__MODULE__, options, name: Controllers.name(biot_id))
  end

  @doc "Tells one controller that its durable intent may have changed."
  @spec intent_changed(GenServer.server()) :: :ok
  def intent_changed(controller), do: GenServer.cast(controller, :intent_changed)

  @impl true
  def init(options) do
    biot_id = Keyword.fetch!(options, :biot_id)

    case Journal.intent(biot_id) do
      nil -> :ignore
      %LocalIntent{biot_spec: spec} -> start_state(biot_id, spec, options)
    end
  end

  @impl true
  def handle_continue(:converge, state), do: converge(state)

  @impl true
  def handle_cast(:intent_changed, state), do: reload(state)

  @impl true
  def handle_info(
        {reference, result},
        %State{phase: {:running, %Effect{task: %Task{ref: reference}} = effect}} = state
      ) do
    Process.demonitor(reference, [:flush])

    state
    |> put_phase(:idle)
    |> record(effect, result)
    |> reload()
  end

  # A cancelled effect's result says nothing worth recording: the controller cancelled it because
  # the biot's intent changed, and the next inspection decides what it left behind.
  def handle_info(
        {reference, _result},
        %State{phase: {:cancelling, %Effect{task: %Task{ref: reference}}, _wake}} = state
      ) do
    Process.demonitor(reference, [:flush])
    reload(put_phase(state, :idle))
  end

  # The task ignored its cancellation, so the failure group ends here and the next inspection says
  # what the half-finished effect left behind.
  def handle_info(
        {:wake, token},
        %State{phase: {:cancelling, effect, %Wake{token: token}}} = state
      ) do
    Task.shutdown(effect.task, :brutal_kill)
    reload(put_phase(state, :idle))
  end

  def handle_info({:wake, token}, %State{phase: {:backing_off, %Wake{token: token}}} = state) do
    converge(put_phase(state, :idle))
  end

  def handle_info({:wake, token}, %State{phase: {:waiting, _reason, %Wake{token: token}}} = state) do
    converge(put_phase(state, :idle))
  end

  def handle_info({:wake, token}, %State{phase: {:settled, %Wake{token: token}}} = state) do
    converge(put_phase(state, :idle))
  end

  # A wake whose phase is gone was already in the mailbox when the phase changed.
  def handle_info({:wake, _token}, state), do: {:noreply, state}

  defp start_state(biot_id, spec, options) do
    case Host.context(biot_id) do
      {:ok, context} ->
        {:ok, build_state(biot_id, context, spec, options), {:continue, :converge}}

      {:error, reason} ->
        {:stop, {:host_not_configured, reason}}
    end
  end

  defp build_state(biot_id, context, spec, options) do
    settings =
      Map.new(State.settings(), fn key -> {key, Keyword.get(options, key, setting(key))} end)

    struct!(State, Map.merge(settings, %{biot_id: biot_id, context: context, spec: spec}))
  end

  defp setting(key), do: Application.fetch_env!(:biot_node, key)

  # A biot whose intent is gone is one the server no longer assigns here. The controller stops and
  # leaves its host resources alone; the node reports them as orphaned allocations. Its
  # diagnostics go, because nobody can ask this node about that biot again.
  defp reload(state) do
    case Journal.intent(state.biot_id) do
      nil ->
        Diagnostics.forget(state.biot_id)
        {:stop, :normal, state}

      %LocalIntent{biot_spec: spec} ->
        state |> accept(spec) |> converge()
    end
  end

  # A new desired revision supersedes every fact the controller carried for the old one: its
  # recorded failure, its spent attempts, and the exit it had not reported yet.
  defp accept(%State{} = state, %BiotSpec{} = spec) do
    if revision(spec) == revision(state.spec) do
      %{state | spec: spec}
    else
      %{state | spec: spec, failure: nil, attempts: %{}, pending_exit: nil}
      |> drop_stale_wake()
    end
  end

  defp drop_stale_wake(%State{phase: {:running, _effect}} = state), do: state
  defp drop_stale_wake(%State{phase: {:cancelling, _effect, _wake}} = state), do: state
  defp drop_stale_wake(%State{} = state), do: put_phase(state, :idle)

  defp converge(state) do
    {state, node_state} = observe(state)
    report(state, node_state)
    decide(state, node_state, Control.status())
  end

  defp observe(%State{} = state) do
    node_state =
      state.biot_id
      |> Host.inspect_state(state.context)
      |> Observation.node_state(
        state.spec.execution.desired,
        state.pending_exit,
        state.failure
      )

    {%{state | pending_exit: node_state.pending_exit}, node_state}
  end

  # Every inspection is reported, so the server learns what this node sees even when nothing
  # changed. An offline link drops the report and the next synchronization asks for it again.
  defp report(%State{} = state, %NodeState{} = node_state) do
    report_observation(state, node_state)
    report_resolution(state, node_state)
  end

  defp report_observation(%State{} = state, %NodeState{} = node_state) do
    Control.report_observation(state.biot_id, Observation.report(state.spec, node_state))
  end

  # The node's own resolution record is the manifest's only home, so the server learns it from what
  # the node inspected rather than from an effect's return value. A crash or a disconnect between
  # the resolve and its report therefore cannot leave the server unresolved, and the outbox keeps
  # one resolution per environment, so repeating it costs nothing.
  defp report_resolution(%State{} = state, %NodeState{} = node_state) do
    environment_id = state.spec.execution.desired.environment_id

    case Map.get(node_state.resolutions, environment_id) do
      {:present, %Resolution{manifest: manifest}} ->
        Control.report_resolution(environment_id, manifest)

      _resolution ->
        :ok
    end
  end

  # A cancelling task and a backing-off retry are both promises not to act yet, so the loop reports
  # what it inspected and stops there.
  defp decide(%State{phase: {:cancelling, _effect, _wake}} = state, _node_state, _control) do
    {:noreply, state}
  end

  defp decide(%State{phase: {:backing_off, _wake}} = state, _node_state, _control) do
    {:noreply, state}
  end

  defp decide(%State{} = state, %NodeState{} = node_state, control) do
    case Reconcile.next(state.spec.execution, node_state, current_action(state), control) do
      # Nothing to do until something changes, and a container that stops is one of those things,
      # so a settled biot looks again on its observation interval.
      :settled ->
        {:noreply, put_phase(state, {:settled, wake(state.observation_interval_ms)})}

      {:run, action} ->
        {:noreply, run(state, action)}

      :cancel_current ->
        {:noreply, cancel(state)}

      {:blocked, {:inspection, _failure} = reason} ->
        {:noreply, put_phase(state, {:waiting, reason, wake(state.inspection_retry_ms)})}

      # The controller knows its own action, so this only means the task is still running.
      {:blocked, {:current_action, _action}} ->
        {:noreply, state}

      # A recorded failure stands until a new revision arrives, and the report already carries it.
      {:blocked, {:recorded_failure, _failure}} ->
        {:noreply, put_phase(state, :idle)}

      # The next synchronization pokes every controller, so an offline link needs no timer.
      {:blocked, :control_offline} ->
        {:noreply, put_phase(state, :idle)}

      {:failed, failure} ->
        {:noreply, fail(state, failure, node_state)}
    end
  end

  defp current_action(%State{phase: {:running, %Effect{action: action}}}), do: action
  defp current_action(%State{}), do: nil

  defp run(%State{} = state, action) do
    task = Task.async(fn -> Host.run(action, state.context) end)
    put_phase(state, {:running, %Effect{action: action, task: task}})
  end

  # Killing the Erlang task alone would leave `nix build` or `git clone` running, so the running
  # command ends its operating system process group first. The task then has a grace period to
  # return before this controller kills it.
  defp cancel(%State{phase: {:running, effect}} = state) do
    Command.cancel(effect.task.pid)
    put_phase(state, {:cancelling, effect, wake(state.cancel_grace_ms)})
  end

  # Replacing a phase drops its timer, so only the phase now in force can wake the controller. A
  # token still says which wake this is, because the replaced message may already be in the mailbox.
  defp put_phase(%State{} = state, phase) do
    cancel_wake(state.phase)
    %{state | phase: phase}
  end

  defp cancel_wake({_tag, %Wake{} = wake}), do: Process.cancel_timer(wake.timer)
  defp cancel_wake({_tag, _detail, %Wake{} = wake}), do: Process.cancel_timer(wake.timer)
  defp cancel_wake(_phase), do: :ok

  defp wake(delay_ms) do
    token = make_ref()
    %Wake{token: token, timer: Process.send_after(self(), {:wake, token}, delay_ms)}
  end

  # A successful action clears the recorded failure but not the attempts spent on this revision, so
  # a container that keeps exiting still runs out of budget across its restarts.
  defp record(%State{} = state, %Effect{}, :ok), do: %{state | failure: nil}

  defp record(%State{} = state, %Effect{action: action}, {:error, %Outcome{} = outcome}) do
    attempt = attempt(state, Action.stage(action))

    failure =
      action
      |> Retry.classify(outcome.outcome, attempt, state.retry_budget)
      |> with_diagnostic(state, outcome.diagnostic)

    record_failure(state, failure, attempt)
  end

  # A failure reconciliation derived from inspection carries no action, so the controller applies
  # the same attempt budget to it here.
  defp fail(%State{} = state, %Failure{} = failure, %NodeState{} = node_state) do
    attempt = attempt(state, failure.stage)

    state =
      record_failure(state, Retry.with_budget(failure, attempt, state.retry_budget), attempt)

    report_observation(state, %{
      node_state
      | failure: state.failure,
        pending_exit: state.pending_exit
    })

    state
  end

  # The failure being recorded is the report the carried exit was waiting for.
  defp record_failure(%State{} = state, %Failure{} = failure, attempt) do
    state = %{
      state
      | failure: {revision(state.spec), failure},
        attempts: Map.put(state.attempts, failure.stage, attempt),
        pending_exit: nil
    }

    await_retry(state, failure, attempt)
  end

  defp await_retry(%State{} = state, %Failure{retry: :automatic}, attempt) do
    delay_ms = Backoff.delay(attempt, state.retry_backoff_min_ms, state.retry_backoff_max_ms)
    put_phase(state, {:backing_off, wake(delay_ms)})
  end

  # An after-change or operator failure waits for a person or a new revision, not for a timer.
  defp await_retry(%State{} = state, %Failure{}, _attempt), do: put_phase(state, :idle)

  # Attempts count per desired revision and stage, including the attempt being recorded now.
  defp attempt(%State{} = state, stage), do: Map.get(state.attempts, stage, 0) + 1

  defp with_diagnostic(%Failure{} = failure, %State{}, nil), do: failure

  defp with_diagnostic(%Failure{} = failure, %State{} = state, diagnostic) do
    diagnostic_ref = Diagnostics.put(state.biot_id, revision(state.spec), diagnostic)
    %{failure | diagnostic_ref: diagnostic_ref}
  end

  defp revision(%BiotSpec{execution: execution}), do: execution.desired.revision
end
