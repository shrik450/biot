defmodule BiotWeb.Live.NodesLive do
  @moduledoc "The registered node list with capacity and orphan reports."

  use BiotWeb, :live_view

  import BiotWeb.Components.AppShell
  import BiotWeb.Components.OrphanReport
  import BiotWeb.Components.Status

  alias Biot.Protocol.Platform
  alias Biot.Server.Queries.Nodes
  alias Biot.Server.Queries.NodeView
  alias BiotWeb.Live.Navigation
  alias BiotWeb.UserMessage

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    actor = socket.assigns.actor
    counts = Navigation.counts(actor)

    socket =
      socket
      |> assign(counts)
      |> assign(:current_section, :nodes)
      |> assign(:nodes_state, :loading)

    if connected?(socket), do: send(self(), :load_nodes)

    {:ok, socket}
  end

  @impl true
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(:load_nodes, socket) do
    state =
      case Nodes.list(socket.assigns.actor) do
        {:ok, nodes} -> {:loaded, nodes}
        {:error, reason} -> {:error, reason}
      end

    {:noreply, assign(socket, :nodes_state, state)}
  end

  @impl true
  def handle_event("retry-load", _params, socket) do
    send(self(), :load_nodes)
    {:noreply, assign(socket, :nodes_state, :loading)}
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <.app_shell current_section={@current_section} biot_count={@biot_count} node_count={@node_count}>
      <div class="page-header">
        <div>
          <p class="eyebrow">infrastructure</p>
          <h1>nodes</h1>
          <p class="page-lede">Registered machines available to Biot.</p>
        </div>
      </div>

      <section class="surface node-list-surface" aria-labelledby="nodes-heading">
        <h2 id="nodes-heading" class="sr-only">Registered nodes</h2>

        <div :if={@nodes_state == :loading} class="loading-state" role="status">
          loading nodes…
        </div>

        <div :if={match?({:error, _reason}, @nodes_state)} class="error-state" role="alert">
          <p>nodes could not be loaded.</p>
          <p class="muted">{UserMessage.error(@nodes_state)}</p>
          <button class="button button-secondary" type="button" phx-click="retry-load">try again</button>
        </div>

        <div :if={match?({:loaded, []}, @nodes_state)} class="empty-state">
          <p>no nodes registered.</p>
          <p class="muted">Register a node before assigning a Biot.</p>
        </div>

        <div :if={match?({:loaded, [_ | _]}, @nodes_state)} class="table-wrap">
          <table class="data-table node-table">
            <caption class="sr-only">Registered nodes</caption>
            <thead>
              <tr>
                <th scope="col">id</th>
                <th scope="col">status</th>
                <th scope="col">connection</th>
                <th scope="col">platform</th>
                <th scope="col">capacity</th>
                <th scope="col">orphan report</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={node <- loaded_nodes(@nodes_state)}>
                <td data-label="id" class="breakable">{to_string(node.id)}</td>
                <td data-label="status"><.status value={node.status} /></td>
                <td data-label="connection"><.status value={node.connection} /></td>
                <td data-label="platform">{display_platform(node.platform)}</td>
                <td data-label="capacity" class="capacity-cell">
                  <span>{node.assigned_biots} / {node.max_biots} assigned</span>
                  <progress
                    class="capacity-bar"
                    value={node.assigned_biots}
                    max={node.max_biots}
                    aria-label={capacity_label(node)}
                  >
                    {node.assigned_biots} / {node.max_biots}
                  </progress>
                </td>
                <td data-label="orphan report">
                  <.orphan_report report={node.orphans} node_id={node.id} />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </.app_shell>
    """
  end

  defp loaded_nodes({:loaded, nodes}), do: nodes

  defp display_platform(nil), do: "unknown"
  defp display_platform(platform), do: Platform.to_string(platform)

  defp capacity_label(%NodeView{assigned_biots: assigned, max_biots: max}),
    do: "#{assigned} of #{max} Biots assigned"
end
