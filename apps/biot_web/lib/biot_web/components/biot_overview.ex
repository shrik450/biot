defmodule BiotWeb.Components.BiotOverview do
  @moduledoc "Renders the truthful, read-only Biot overview."

  use BiotWeb, :html

  import BiotWeb.Components.Operation
  import BiotWeb.Components.Status

  alias Biot.Protocol.SourceSelector
  alias BiotWeb.BiotState
  alias BiotWeb.Live.BiotDetailData
  alias BiotWeb.Live.ShellAvailability
  alias BiotWeb.UserMessage

  attr :view, :any, required: true
  attr :detail, :any, required: true
  attr :deployment_state, :any, required: true
  attr :diagnostic_state, :any, required: true

  @spec overview(map()) :: Phoenix.LiveView.Rendered.t()
  def overview(assigns) do
    ~H"""
    <div>
      <div :if={refreshable?(@view)} class="detail-refresh">
        <button class="button button-secondary" type="button" phx-click="refresh-detail">refresh current state</button>
      </div>

      <div class="overview-grid">
        <section class="surface" aria-labelledby="desired-heading">
          <h2 id="desired-heading">desired execution</h2>
          <dl class="definition-list definition-list-single">
            <div>
              <dt>state</dt><dd><span class="desired-marker">{@view.desired.state}</span></dd>
            </div>
            <div>
              <dt>revision</dt><dd>{@view.desired.revision}</dd>
            </div>
            <div>
              <dt>environment</dt><dd class="breakable" translate="no">
                {to_string(@view.desired.environment_id)}
              </dd>
            </div>
          </dl>
        </section>

        <section class="surface" aria-labelledby="operation-heading">
          <h2 id="operation-heading">operation</h2>
          <.operation operation={@view.operation} />
          <div :if={operation_failure(@view)} class="failure-detail">
            <p><strong>{UserMessage.failure_label(operation_failure(@view))}</strong></p>
            <p>{operation_failure(@view).message}</p>
            <p class="muted">retry: {operation_failure(@view).retry}</p>
            <button
              :if={operation_failure(@view).diagnostic_ref}
              class="button button-secondary"
              type="button"
              phx-click="view-diagnostic"
            >view diagnostic</button>
          </div>
        </section>

        <section class="surface" aria-labelledby="observation-heading">
          <h2 id="observation-heading">latest observation</h2>
          <div :if={@view.actual == :never_reported} class="empty-state compact-empty">
            <p>never reported by the node.</p>
          </div>
          <dl :if={is_map(@view.actual)} class="definition-list definition-list-single">
            <div>
              <dt>freshness</dt><dd>{@view.actual.freshness}</dd>
            </div>
            <div>
              <dt>received</dt><dd><.timestamp value={@view.actual.received_at} /></dd>
            </div>
            <div>
              <dt>installed environment</dt><dd class="breakable">
                {display_id(@view.actual.installed_environment)}
              </dd>
            </div>
            <div>
              <dt>container</dt><dd>{container_state(@view.actual.container)}</dd>
            </div>
            <div>
              <dt>incarnation</dt><dd class="breakable">
                {incarnation_id(@view.actual.container)}
              </dd>
            </div>
            <div>
              <dt>data</dt><dd>{@view.actual.data}</dd>
            </div>
          </dl>
        </section>

        <section class="surface" aria-labelledby="environment-heading">
          <h2 id="environment-heading">environment &amp; source</h2>
          <dl class="definition-list definition-list-single">
            <div>
              <dt>repository</dt><dd class="breakable" translate="no">
                {to_string(@detail.repository)}
              </dd>
            </div>
            <div>
              <dt>base package set</dt><dd class="breakable" translate="no">
                {source_selector(@detail.environment.base_nixpkgs)}
              </dd>
            </div>
            <div>
              <dt>layers</dt><dd translate="no">{layer_list(@detail.environment.layers)}</dd>
            </div>
          </dl>
        </section>

        <section class="surface" aria-labelledby="assignment-heading">
          <h2 id="assignment-heading">assignment &amp; access</h2>
          <dl class="definition-list definition-list-single">
            <div>
              <dt>node</dt><dd>
                <span class="breakable" translate="no">{to_string(@view.node_id)}</span>
                <.status value={@view.node} />
              </dd>
            </div>
            <div>
              <dt>access revision</dt><dd>{@view.access.revision}</dd>
            </div>
            <div>
              <dt>enforcement</dt><dd>{UserMessage.enforcement(@view.access.enforcement)}</dd>
            </div>
          </dl>
        </section>

        <section class="surface" aria-labelledby="security-history-heading">
          <h2 id="security-history-heading">security history</h2>
          <p :if={@view.direct_secret_exposure_possible} class="history-marker">
            direct secret exposure possible
          </p>
          <p :if={!@view.direct_secret_exposure_possible} class="muted">
            no direct runtime secret delivery has been recorded for this Biot.
          </p>
          <p class="muted">
            This is a historical marker; it does not show whether a secret is present now.
          </p>
        </section>

        <section class="surface" aria-labelledby="deployment-heading">
          <h2 id="deployment-heading">shell connection</h2>
          <div :if={!shell_allowed?(@view)} class="empty-state compact-empty">
            <p>shell is not available for this role or state.</p>
          </div>
          <div :if={shell_allowed?(@view) and match?({:loaded, _}, @deployment_state)}>
            <p class="muted">advertised by this server</p>
            <code class="command-value" translate="no">ssh -p {deployment_port(@deployment_state)} {to_string(
              @view.id
            )}@{deployment_host(@deployment_state)}</code>
          </div>
          <div
            :if={shell_allowed?(@view) and match?({:error, _}, @deployment_state)}
            class="error-state compact-empty"
            role="alert"
          >
            <p>shell connection details unavailable.</p>
            <p class="muted">{UserMessage.error(@deployment_state)}</p>
          </div>
        </section>
      </div>

      <section
        :if={@diagnostic_state != :idle}
        class="surface diagnostic-panel"
        aria-labelledby="diagnostic-heading"
      >
        <h2 id="diagnostic-heading">diagnostic</h2>
        <div
          :if={match?({:error, :not_found}, @diagnostic_state)}
          class="error-state"
          role="alert"
        >
          <p>diagnostic not found.</p>
          <p class="muted">the diagnostic may have expired or was not retained.</p>
        </div>
        <div
          :if={
            match?({:error, _reason}, @diagnostic_state) and
              @diagnostic_state != {:error, :not_found}
          }
          class="error-state"
          role="alert"
        >
          <p>diagnostic unavailable.</p>
          <p class="muted">{UserMessage.error(@diagnostic_state)}</p>
        </div>
        <div :if={match?({:loaded, _, _}, @diagnostic_state)}>
          <p :if={diagnostic_truncated?(@diagnostic_state)} class="muted">
            output truncated to the server's diagnostic limit.
          </p>
          <pre class="terminal-output">{diagnostic_content(@diagnostic_state)}</pre>
        </div>
      </section>

      <section :if={fetch_source(@view)} class="overview-notice" aria-live="polite">
        <strong>fetch credential required</strong>
        <span>
          the node is waiting for access to <code class="breakable" translate="no">{fetch_source(@view)}</code>.
        </span>
        <.link
          :if={owner?(@view)}
          navigate={~p"/biots/#{@view.id}/secrets"}
        >deliver credential</.link>
      </section>

      <section
        :if={operation_failure(@view)}
        class="overview-notice overview-notice-failure"
        aria-live="polite"
      >
        <strong>operation failed</strong>
        <span>{operation_failure(@view).stage}: {operation_failure(@view).message}</span>
      </section>
    </div>
    """
  end

  defp owner?(%{role: :owner}), do: true
  defp owner?(_view), do: false

  defp shell_allowed?(view), do: ShellAvailability.allowed?(view)

  defp refreshable?(%{operation: %{outcome: outcome}}) when outcome in [:pending, :working],
    do: true

  defp refreshable?(view), do: not is_nil(BiotDetailData.waiting_fetch_source(view))

  defp fetch_source(view) do
    case BiotDetailData.waiting_fetch_source(view) do
      %Biot.Protocol.RepositorySource{url: url} -> url
      nil -> nil
    end
  end

  defp operation_failure(%{view: view}), do: BiotState.current_failure(view)
  defp operation_failure(view), do: BiotState.current_failure(view)

  defp source_selector(selector), do: SourceSelector.to_string(selector)
  defp layer_list([]), do: "none"
  defp layer_list(layers), do: Enum.map_join(layers, ", ", &source_selector/1)

  defp display_id(nil), do: "not reported"
  defp display_id(value), do: to_string(value)

  defp container_state(:unknown), do: "unknown"
  defp container_state(:absent), do: "absent"
  defp container_state({:present, _incarnation, :running}), do: "present · running"

  defp container_state({:present, _incarnation, {:exited, status}}),
    do: "present · exited (#{status})"

  defp container_state(_value), do: "not reported"

  defp incarnation_id({:present, incarnation, _state}), do: to_string(incarnation)
  defp incarnation_id(_container), do: "not reported"

  defp deployment_port({:loaded, deployment}), do: deployment.ssh.port
  defp deployment_host({:loaded, deployment}), do: deployment.ssh.host

  defp diagnostic_content({:loaded, content, _truncated}), do: content
  defp diagnostic_truncated?({:loaded, _content, truncated}), do: truncated

  attr :value, :any, required: true

  defp timestamp(assigns) do
    ~H"""
    <time
      id={"overview-received-at-#{DateTime.to_unix(@value)}"}
      datetime={DateTime.to_iso8601(@value)}
      title={DateTime.to_iso8601(@value)}
      phx-hook="LocalizedTime"
    >{DateTime.to_iso8601(@value)}</time>
    """
  end
end
