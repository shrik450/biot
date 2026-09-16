defmodule BiotWeb.Components.BiotLogs do
  @moduledoc "Renders bounded runtime output for an owner or shell collaborator."

  use BiotWeb, :html

  alias BiotWeb.UserMessage

  attr :logs_state, :any, required: true
  attr :target, :any, default: nil

  @spec logs_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def logs_panel(assigns) do
    ~H"""
    <section class="surface logs-panel" aria-labelledby="logs-heading">
      <div class="section-heading">
        <div>
          <h2 id="logs-heading">runtime logs</h2>
          <p class="section-description">The latest bounded output from the assigned incarnation.</p>
        </div>
        <button
          class="button button-secondary"
          type="button"
          phx-click="refresh-logs"
          phx-target={@target}
          disabled={@logs_state == :loading}
          phx-disable-with="refreshing…"
        >refresh</button>
      </div>

      <div :if={@logs_state == :loading} class="loading-state" role="status">
        loading runtime logs…
      </div>
      <div :if={match?({:error, :not_found}, @logs_state)} class="error-state" role="alert">
        <p>runtime logs not found.</p>
        <p class="muted">This Biot has no retained output for its current incarnation.</p>
      </div>
      <div
        :if={match?({:error, :temporarily_unavailable}, @logs_state)}
        class="error-state"
        role="alert"
      >
        <p>runtime logs are temporarily unavailable.</p>
        <p class="muted">The assigned node is not ready to answer. Try again later.</p>
      </div>
      <div
        :if={
          match?({:error, _reason}, @logs_state) and not match?({:error, :not_found}, @logs_state) and
            not match?({:error, :temporarily_unavailable}, @logs_state)
        }
        class="error-state"
        role="alert"
      >
        <p>runtime logs could not be loaded.</p>
        <p class="muted">{UserMessage.error(@logs_state)}</p>
      </div>
      <div :if={match?({:loaded, _, _, _}, @logs_state)} class="logs-output-wrap">
        <% {:loaded, incarnation, output, truncated} = @logs_state %>
        <p class="log-incarnation">
          incarnation <code translate="no">{to_string(incarnation)}</code>
        </p>
        <p :if={truncated} class="log-truncation" role="status">
          output truncated to the server's bounded log limit.
        </p>
        <pre class="logs-output" tabindex="0" translate="no">{output}</pre>
      </div>
    </section>
    """
  end
end
