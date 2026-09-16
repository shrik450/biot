defmodule BiotWeb.Live.TerminalLive do
  @moduledoc "The route-backed terminal shell."

  use BiotWeb, :live_view

  import BiotWeb.Components.AppShell

  alias Biot.Protocol.BiotId
  alias Biot.Server.Queries.Biots
  alias BiotWeb.Live.Navigation
  alias BiotWeb.Live.ShellAvailability
  alias BiotWeb.UserMessage

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(Navigation.counts(socket.assigns.actor))
     |> assign(:current_section, :biots)
     |> assign(:terminal_state, load_terminal_state(socket.assigns.actor, id))}
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div>
      <main
        :if={match?({:loaded, _view}, @terminal_state)}
        class="terminal-page"
        aria-labelledby="terminal-title"
      >
        <% {:loaded, view} = @terminal_state %>
        <a class="skip-link" href="#biot-terminal">skip to terminal</a>
        <header class="terminal-toolbar">
          <.link class="terminal-back" navigate={~p"/biots/#{view.id}"}>← exit terminal</.link>
          <div class="terminal-title-block">
            <p class="eyebrow">terminal</p>
            <h1 id="terminal-title">{to_string(view.name)}</h1>
            <p class="terminal-meta">
              node <span class="breakable">{to_string(view.node_id)}</span>
              · id <span class="breakable">{to_string(view.id)}</span>
            </p>
          </div>
          <div class="terminal-connection">
            <span class="terminal-connection-label">connection</span>
            <p id="terminal-status" class="terminal-status" role="status" aria-live="polite">
              connecting…
            </p>
          </div>
        </header>
        <section
          id="biot-terminal"
          class="terminal-host"
          phx-hook="GhosttyTerminal"
          phx-update="ignore"
          data-socket-path={~p"/biots/#{view.id}/terminal/socket"}
          aria-label="terminal session"
        >
          <p class="terminal-loading">connecting…</p>
        </section>
      </main>

      <.app_shell
        :if={match?({:error, _reason}, @terminal_state)}
        current_section={@current_section}
        biot_count={@biot_count}
        node_count={@node_count}
      >
        <p class="breadcrumb"><.link navigate={~p"/biots"}>biots</.link> / terminal</p>
        <div class="error-state" role="alert">
          <p>terminal unavailable.</p>
          <p class="muted">{UserMessage.error(@terminal_state)}</p>
          <.link class="button button-secondary" navigate={~p"/biots"}>back to biots</.link>
        </div>
      </.app_shell>
    </div>
    """
  end

  defp load_terminal_state(actor, id) do
    with {:ok, biot_id} <- BiotId.parse(id),
         {:ok, view} <- Biots.get(actor, biot_id),
         true <- ShellAvailability.allowed?(view) do
      {:loaded, view}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, :not_found} -> {:error, :not_found}
      false -> {:error, :forbidden}
      _invalid -> {:error, :not_found}
    end
  end
end
