defmodule BiotWeb.Live.BiotsLive do
  @moduledoc "The paginated readable Biot list."

  use BiotWeb, :live_view

  import BiotWeb.Components.AppShell
  import BiotWeb.Components.BiotSummary
  import BiotWeb.Components.Operation
  import BiotWeb.Components.Role
  import BiotWeb.Components.Status

  alias Biot.Server.Queries.Biots
  alias Biot.Server.Queries.BiotView
  alias BiotWeb.Live.Navigation
  alias BiotWeb.UserMessage

  @page_size 20

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    actor = socket.assigns.actor
    counts = Navigation.counts(actor)

    socket =
      socket
      |> assign(counts)
      |> assign(:current_section, :biots)
      |> assign(:biots_state, :loading)
      |> assign(:biots_after, nil)
      |> assign(:biots_has_more, false)
      |> assign(:biots_loading_more, false)
      |> assign(:biots_page_error, nil)

    if connected?(socket), do: send(self(), :load_biots)

    {:ok, socket}
  end

  @impl true
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(:load_biots, socket) do
    {:noreply, load_page(socket, nil, false)}
  end

  def handle_info({:load_biots_page, after_id}, socket) do
    {:noreply, load_page(socket, after_id, true)}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("load-more", _params, socket) do
    if socket.assigns.biots_has_more and not socket.assigns.biots_loading_more do
      send(self(), {:load_biots_page, socket.assigns.biots_after})
      {:noreply, assign(socket, :biots_loading_more, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("retry-load", _params, socket) do
    send(self(), :load_biots)

    {:noreply,
     socket
     |> assign(:biots_state, :loading)
     |> assign(:biots_page_error, nil)}
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <.app_shell current_section={@current_section} biot_count={@biot_count} node_count={@node_count}>
      <div class="page-header">
        <div>
          <p class="eyebrow">workspace</p>
          <h1>biots</h1>
          <p class="page-lede">Development environments you can read.</p>
        </div>
        <.link class="button button-primary" navigate={~p"/biots/new"}>new biot</.link>
      </div>

      <section class="surface biot-list-surface" aria-labelledby="biots-heading">
        <h2 id="biots-heading" class="sr-only">Readable biots</h2>

        <div :if={@biots_state == :loading} class="loading-state" role="status">
          loading biots…
        </div>

        <div :if={match?({:error, _reason}, @biots_state)} class="error-state" role="alert">
          <p>biots could not be loaded.</p>
          <p class="muted">{UserMessage.error(@biots_state)}</p>
          <button class="button button-secondary" type="button" phx-click="retry-load">try again</button>
        </div>

        <div :if={match?({:loaded, []}, @biots_state)} class="empty-state">
          <p>no readable biots yet.</p>
          <p class="muted">Create a Biot to get started.</p>
        </div>

        <div :if={match?({:loaded, [_ | _]}, @biots_state)} class="table-wrap">
          <table class="data-table biot-table">
            <caption class="sr-only">Readable biots</caption>
            <thead>
              <tr>
                <th scope="col">name</th>
                <th scope="col">state</th>
                <th scope="col">operation / wait</th>
                <th scope="col">role</th>
                <th scope="col">node</th>
                <th scope="col">ports</th>
                <th scope="col">history</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={biot <- loaded_biots(@biots_state)} class="biot-row">
                <td data-label="name" class="biot-name-cell">
                  <.link
                    class="biot-row-target"
                    navigate={~p"/biots/#{biot.id}"}
                    aria-label={"open biot #{to_string(biot.name)}"}
                  >
                    <span class="sr-only">open biot {to_string(biot.name)}</span>
                  </.link>
                  <span class="biot-name">{to_string(biot.name)}</span>
                  <span class="biot-id breakable">{to_string(biot.id)}</span>
                </td>
                <td data-label="state"><.summary biot={biot} /></td>
                <td data-label="operation / wait" class="operation-cell">
                  <.operation operation={biot.operation} />
                  <span :if={waiting_for(biot.actual)} class="wait-detail">
                    waiting for {waiting_for(biot.actual)}
                  </span>
                </td>
                <td data-label="role"><.role role={biot.role} /></td>
                <td data-label="node" class="node-cell">
                  <span class="breakable">{to_string(biot.node_id)}</span>
                  <.status value={biot.node} />
                </td>
                <td data-label="ports" class="ports-cell">
                  <span :if={biot.publications == []} class="muted">none</span>
                  <span :for={publication <- biot.publications} class="port-link">
                    <a href={publication.url} target="_blank" rel="noreferrer">
                      {Biot.Protocol.Port.to_string(publication.port)}
                      <span class="new-tab-indicator">(new tab)</span>
                    </a>
                  </span>
                </td>
                <td data-label="history">
                  <span :if={biot.direct_secret_exposure_possible} class="history-marker">
                    direct secret exposure possible
                  </span>
                  <span :if={!biot.direct_secret_exposure_possible} class="muted">none</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@biots_page_error} class="inline-error" role="alert">
          Could not load more biots. {UserMessage.error(@biots_page_error)}
        </div>

        <div :if={match?({:loaded, [_ | _]}, @biots_state) and @biots_has_more} class="load-more">
          <button
            class="button button-secondary"
            type="button"
            phx-click="load-more"
            disabled={@biots_loading_more}
          >
            {if @biots_loading_more, do: "loading…", else: "load more biots"}
          </button>
        </div>
      </section>
    </.app_shell>
    """
  end

  @spec load_page(Phoenix.LiveView.Socket.t(), Biot.Protocol.BiotId.t() | nil, boolean()) ::
          Phoenix.LiveView.Socket.t()
  defp load_page(socket, after_id, append?) do
    case Biots.list(socket.assigns.actor, %{after: after_id, limit: @page_size}) do
      {:ok, page} ->
        biots = if append?, do: loaded_biots(socket.assigns.biots_state) ++ page, else: page
        last_id = page |> List.last() |> id_or_nil()

        socket
        |> assign(:biots_state, {:loaded, biots})
        |> assign(:biots_after, last_id)
        |> assign(:biots_has_more, length(page) == @page_size)
        |> assign(:biots_loading_more, false)
        |> assign(:biots_page_error, nil)

      {:error, reason} when append? ->
        socket
        |> assign(:biots_loading_more, false)
        |> assign(:biots_page_error, reason)

      {:error, reason} ->
        socket
        |> assign(:biots_state, {:error, reason})
        |> assign(:biots_loading_more, false)
    end
  end

  defp loaded_biots({:loaded, biots}), do: biots
  defp loaded_biots(_state), do: []

  defp id_or_nil(nil), do: nil
  defp id_or_nil(%BiotView{id: id}), do: id

  defp waiting_for(%{waiting_for: {:fetch_credential, source}}), do: source.url
  defp waiting_for(_actual), do: nil
end
