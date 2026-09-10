defmodule Biot.Node.BiotController do
  @moduledoc """
  Owns one biot on this node. It turns durable intent plus host inspection into one host action at
  a time, reports what it inspected, retries what may pass on its own, and stops in a way an
  operator can see when it cannot.

  Every event runs the same loop: inspect the biot's resources, report the observation and any
  resolution the node holds, ask `Reconcile.next/3` for one action, run that action in one linked
  task, and start over when the task finishes. The controller never trusts an effect's account of
  what happened; only the next inspection decides what is true. A crash therefore costs nothing:
  the restarted controller loads the same durable intent and the same `RetryState` from the
  journal, and inspects before it acts.

  The controller and its effect share a failure group. The task is linked, so a bug inside an
  effect takes the controller down with it, and the supervisor's restart inspects first.

  One `phase` field says what the controller is doing, and what may wake it:

  - `:idle` waits for a message. Nothing is scheduled, because only a new intent, a container
    exit, or the next synchronization can change what a recorded failure decides.
  - `{:running, effect}` has one action in flight. The loop does not ask `Reconcile.next/3` for
    another one until that task finishes.
  - `{:cancelling, effect, wake}` has asked a task to stop, and the wake is the grace period after
    which the task is killed.
  - `{:backing_off, wake}` owes an automatic retry, and the wake is its delay.
  - `{:waiting, reason, wake}` could not read a resource, and the wake looks again.
  - `{:settled, wake}` has nothing to do, and the wake re-inspects on the observation interval,
    which is how the node notices a container that stopped without an event.

  A new desired revision drops a backoff, a wait, and a settled reminder, because they belong to
  the revision that is gone. It never drops a cancellation: the task the controller cancelled is
  still stopping, and its grace period must still end.

  A destroyed biot is the one desired state a controller finishes. It writes the final report to
  the journal, hands it to the outbox, and exits normally, so `restart: :transient` keeps the
  supervisor from starting it again.
  """

  use GenServer, restart: :transient

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
  alias Biot.Node.RetryState
  alias Biot.Node.RuntimeLogs
  alias Biot.Protocol.BiotSpec
  alias Biot.Protocol.ExecutionReport
  alias Biot.Protocol.Failure

  defmodule Effect do
    @moduledoc false

    @enforce_keys [:action, :revision, :task]
    defstruct [:action, :revision, :task]

    @type t :: %__MODULE__{action: Action.t(), revision: pos_integer(), task: Task.t()}
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

    @enforce_keys [:biot_id, :context, :spec, :retry] ++ @settings
    defstruct @enforce_keys ++ [phase: :idle, pending_exit: nil]

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

  @doc "Tells one controller that a container it owns stopped."
  @spec container_exited(GenServer.server()) :: :ok
  def container_exited(controller), do: GenServer.cast(controller, :container_exited)

  @impl true
  def init(options) do
    biot_id = Keyword.fetch!(options, :biot_id)

    case Journal.intent(biot_id) do
      nil -> :ignore
      %LocalIntent{} = intent -> start_state(intent, options)
    end
  end

  @impl true
  def handle_continue(:converge, state), do: converge(state)

  @impl true
  def handle_cast(:intent_changed, state), do: reload(state)

  # An exit event is a hint that inspection may now say something new, and the loop reads the
  # container itself, so a hint about a container that is still running costs one inspection.
  def handle_cast(:container_exited, state), do: converge(state)

  @impl true
  def handle_info(
        {reference, result},
        %State{phase: {:running, %Effect{task: %Task{ref: reference}} = effect}} = state
      ) do
    Process.demonitor(reference, [:flush])
    state = put_phase(state, :idle)
    after_retry_write(state, record(state, effect, result), &reload/1)
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

  # A stored destruction report means this node already finished the biot and is waiting for the
  # server to acknowledge the receipt. Refusing to start here is the whole rule: the starter and
  # `Controllers.intent_changed/1` both go through `init/1`, so neither needs its own check, and
  # the control connection replays the report without a controller.
  defp start_state(%LocalIntent{destruction_report: %ExecutionReport{}}, _options), do: :ignore

  defp start_state(%LocalIntent{biot_id: biot_id, biot_spec: spec}, options) do
    case Host.context(biot_id) do
      {:ok, context} ->
        state = build_state(biot_id, context, spec, options)
        {:ok, resume_backoff(state), {:continue, :converge}}

      {:error, reason} ->
        {:stop, {:host_not_configured, reason}}
    end
  end

  defp build_state(biot_id, context, spec, options) do
    settings =
      Map.new(State.settings(), fn key -> {key, Keyword.get(options, key, setting(key))} end)

    struct!(
      State,
      Map.merge(settings, %{
        biot_id: biot_id,
        context: context,
        spec: spec,
        retry: load_retry(biot_id, revision(spec))
      })
    )
  end

  defp setting(key), do: Application.fetch_env!(:biot_node, key)

  defp load_retry(biot_id, revision) do
    biot_id |> Journal.retry_state() |> RetryState.for_revision(biot_id, revision)
  end

  # The backoff a crashed controller owed is still owed, so the restart serves the rest of it
  # rather than retrying at once and spending the budget faster than the delay allows.
  defp resume_backoff(%State{retry: %RetryState{next_attempt_at: nil}} = state), do: state

  defp resume_backoff(%State{retry: %RetryState{next_attempt_at: due}} = state) do
    put_phase(state, {:backing_off, wake(remaining_ms(state, due))})
  end

  # A saved wake outlives the process that scheduled it, and the clock can move under it. Clamping
  # to one maximum backoff bounds both a time that has passed and a time far in the future.
  defp remaining_ms(%State{} = state, %DateTime{} = due) do
    due
    |> DateTime.diff(DateTime.utc_now(), :millisecond)
    |> min(state.retry_backoff_max_ms)
    |> max(0)
  end

  # A biot whose intent is gone is one the server no longer assigns here. The controller stops and
  # leaves its host resources alone; the node reports them as orphaned allocations.
  defp reload(state) do
    case Journal.intent(state.biot_id) do
      nil ->
        {:stop, :normal, state}

      %LocalIntent{biot_spec: spec} ->
        state |> accept(spec) |> converge()
    end
  end

  # A new desired revision supersedes every fact the controller carried for the old one, so it
  # reads the retry record again and drops the exit it had not reported yet. The journal already
  # dropped the superseded record in the transaction that accepted the new revision.
  defp accept(%State{} = state, %BiotSpec{} = spec) do
    if revision(spec) == revision(state.spec) do
      %{state | spec: spec}
    else
      %{
        state
        | spec: spec,
          retry: load_retry(state.biot_id, revision(spec)),
          pending_exit: nil
      }
      |> drop_stale_wake()
    end
  end

  defp drop_stale_wake(%State{phase: {:running, _effect}} = state), do: state
  defp drop_stale_wake(%State{phase: {:cancelling, _effect, _wake}} = state), do: state
  defp drop_stale_wake(%State{} = state), do: put_phase(state, :idle)

  defp converge(state) do
    {state, node_state} = observe(state)
    decide(state, node_state, report(state, node_state))
  end

  defp observe(%State{} = state) do
    inspection = Host.inspect_state(state.biot_id, state.context)
    :ok = RuntimeLogs.attach(state.context.config, state.biot_id, inspection.container)

    node_state =
      inspection
      |> Observation.node_state(
        state.spec.execution.desired,
        state.pending_exit,
        recorded_failure(state.retry)
      )

    {%{state | pending_exit: node_state.pending_exit}, node_state}
  end

  defp recorded_failure(%RetryState{failure: nil}), do: nil

  defp recorded_failure(%RetryState{} = retry), do: {retry.target_revision, retry.failure}

  # Every inspection is reported, so the server learns what this node sees even when nothing
  # changed. A link that is down drops the report and the next synchronization asks for it again.
  defp report(%State{} = state, %NodeState{} = node_state) do
    report = report_observation(state, node_state)
    report_resolution(state, node_state)
    report
  end

  defp report_observation(%State{} = state, %NodeState{} = node_state) do
    report = Observation.report(state.spec, node_state)
    :ok = Control.report_observation(state.biot_id, report)
    report
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
  defp decide(%State{phase: {:cancelling, _effect, _wake}} = state, _node_state, _report) do
    {:noreply, state}
  end

  defp decide(%State{phase: {:backing_off, _wake}} = state, _node_state, _report) do
    {:noreply, state}
  end

  defp decide(%State{} = state, %NodeState{} = node_state, report) do
    case Reconcile.next(state.spec.execution, node_state, current_action(state)) do
      :settled ->
        settle(state.spec.execution.desired.state, state, report)

      {:run, action} ->
        after_retry_write(state, run(state, action), &{:noreply, &1})

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

      {:failed, failure} ->
        after_retry_write(state, fail(state, failure, node_state), &{:noreply, &1})
    end
  end

  # A refused retry write leaves its keyed diagnostic in place. The next write for that key
  # replaces it, while the controller drops this work and reads the intent now in force.
  defp after_retry_write(%State{}, {:ok, %State{} = written}, next), do: next.(written)
  defp after_retry_write(%State{} = state, :superseded, _next), do: reload(state)

  # Destruction is the one desired state a controller can finish. The report of the inspection that
  # found it finished is the receipt the server waits for, so the journal keeps it until the server
  # sends intent that no longer names this biot. The outbox already holds this same report, because
  # every inspection is reported before it is decided on.
  defp settle(:destroyed, %State{} = state, %ExecutionReport{} = report) do
    {:ok, _intent} = Journal.put_destruction_report(state.biot_id, report)
    {:stop, :normal, state}
  end

  # Nothing to do until something changes, and a container that stops is one of those things, so a
  # settled biot looks again on its observation interval even when no event reaches it.
  defp settle(:running, %State{} = state, %ExecutionReport{}),
    do: {:noreply, observe_later(state)}

  defp settle(:stopped, %State{} = state, %ExecutionReport{}),
    do: {:noreply, observe_later(state)}

  defp observe_later(%State{} = state) do
    put_phase(state, {:settled, wake(state.observation_interval_ms)})
  end

  defp current_action(%State{phase: {:running, %Effect{action: action}}}), do: action
  defp current_action(%State{}), do: nil

  # The attempt is durable before the action starts, so an action a crash interrupts still costs
  # the budget and a command that kills this node cannot be retried without end. A refused attempt
  # is therefore also a refused action.
  defp run(%State{} = state, action) do
    with {:ok, counted} <- count_attempt(state, Action.stage(action)) do
      task = Task.async(fn -> Host.run(action, counted.context) end)
      effect = %Effect{action: action, revision: revision(counted.spec), task: task}
      {:ok, put_phase(counted, {:running, effect})}
    end
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

  # A result belongs to the revision its effect started under, so a result from an effect started
  # for another revision is not this revision's result. This is the mistake the journal cannot see:
  # by the time the result arrives, the stored intent can already hold the revision this controller
  # accepted, and the journal would take the write.
  defp record(%State{} = state, %Effect{} = effect, result) do
    if effect.revision == revision(state.spec) do
      record_result(state, effect, result)
    else
      {:ok, state}
    end
  end

  # A successful action clears the recorded failure but not the attempts spent on this revision, so
  # a container that keeps exiting still runs out of budget across its restarts.
  defp record_result(%State{} = state, %Effect{revision: revision}, :ok) do
    put_retry(state, Journal.clear_failure(state.biot_id, revision))
  end

  defp record_result(%State{} = state, %Effect{} = effect, {:error, %Outcome{} = outcome}) do
    attempt = RetryState.attempts(state.retry, Action.stage(effect.action))

    failure =
      effect.action
      |> Retry.classify(outcome.outcome, attempt, state.retry_budget)
      |> with_diagnostic(state, outcome)

    case record_failure(state, effect.revision, failure, attempt) do
      {:ok, recorded} -> {:ok, recorded}
      :superseded -> :superseded
    end
  end

  # A failure reconciliation derived from inspection carries no action, so no attempt was counted
  # for it yet. It spends the same budget, because a container that keeps exiting is the same kind
  # of repeated work as an action that keeps failing.
  defp fail(%State{} = state, %Failure{} = failure, %NodeState{} = node_state) do
    with {:ok, counted} <- count_attempt(state, failure.stage),
         attempt = RetryState.attempts(counted.retry, failure.stage),
         budgeted = Retry.with_budget(failure, attempt, counted.retry_budget),
         {:ok, recorded} <- record_failure(counted, revision(counted.spec), budgeted, attempt) do
      _report =
        report_observation(recorded, %{
          node_state
          | failure: recorded_failure(recorded.retry),
            pending_exit: recorded.pending_exit
        })

      {:ok, recorded}
    end
  end

  # The failure being recorded is the report the carried exit was waiting for.
  defp record_failure(%State{} = state, revision, %Failure{} = failure, attempt) do
    due = next_attempt_at(state, failure, attempt)

    with {:ok, recorded} <-
           put_retry(state, Journal.record_failure(state.biot_id, revision, failure, due)) do
      {:ok, recorded |> Map.put(:pending_exit, nil) |> await_retry(due)}
    end
  end

  defp next_attempt_at(%State{} = state, %Failure{retry: :automatic}, attempt) do
    delay_ms = Backoff.delay(attempt, state.retry_backoff_min_ms, state.retry_backoff_max_ms)
    DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)
  end

  # An after-change failure waits for a new revision and an operator failure waits for a person, so
  # neither has a wake.
  defp next_attempt_at(%State{}, %Failure{retry: :after_change}, _attempt), do: nil
  defp next_attempt_at(%State{}, %Failure{retry: :operator}, _attempt), do: nil

  defp await_retry(%State{} = state, nil), do: put_phase(state, :idle)

  defp await_retry(%State{} = state, %DateTime{} = due) do
    put_phase(state, {:backing_off, wake(remaining_ms(state, due))})
  end

  defp count_attempt(%State{} = state, stage) do
    put_retry(state, Journal.record_attempt(state.biot_id, revision(state.spec), stage))
  end

  # A journal write the node cannot make leaves the controller unable to say what it has spent, so
  # there is no clause for an error: the crash restarts a controller that reads the durable record.
  defp put_retry(%State{} = state, {:ok, %RetryState{} = retry}),
    do: {:ok, %{state | retry: retry}}

  defp put_retry(%State{}, :superseded), do: :superseded

  defp with_diagnostic(%Failure{} = failure, %State{}, %Outcome{diagnostic: nil}), do: failure

  defp with_diagnostic(
         %Failure{} = failure,
         %State{} = state,
         %Outcome{diagnostic: diagnostic}
       ) do
    diagnostic_ref =
      Diagnostics.put(
        state.biot_id,
        revision(state.spec),
        failure.stage,
        diagnostic
      )

    %{failure | diagnostic_ref: diagnostic_ref}
  end

  defp revision(%BiotSpec{execution: execution}), do: execution.desired.revision
end
