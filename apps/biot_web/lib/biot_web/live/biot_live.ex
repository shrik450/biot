defmodule BiotWeb.Live.BiotLive do
  @moduledoc "The route-backed Biot detail and overview."

  use BiotWeb, :live_view

  import BiotWeb.Components.AppShell
  import BiotWeb.Components.BiotOverview
  import BiotWeb.Components.Operation
  import BiotWeb.Components.Role

  alias Biot.Protocol.BiotId

  alias Biot.Server.BiotChange
  alias Biot.Server.Biots
  alias Biot.Server.Biots.SelectEnvironment
  alias Biot.Server.Diagnostics
  alias BiotWeb.BiotState
  alias BiotWeb.Live.BiotDetailData
  alias BiotWeb.Live.BiotTabs
  alias BiotWeb.Live.Navigation
  alias BiotWeb.Live.ShellAvailability
  alias BiotWeb.UserMessage

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(Navigation.counts(socket.assigns.actor))
      |> assign(:current_section, :biots)
      |> reset_detail_state(nil, :overview)

    {:ok, socket}
  end

  @impl true
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(%{"id" => id}, _uri, socket) do
    current_tab = BiotTabs.from_action(socket.assigns.live_action)

    case BiotId.parse(id) do
      {:ok, biot_id} ->
        socket =
          socket
          |> subscribe_to_detail(biot_id)
          |> reset_detail_state(biot_id, current_tab)

        if connected?(socket) do
          Enum.each(BiotTabs.load_messages(current_tab, biot_id), &send(self(), &1))
        end

        {:noreply, socket}

      {:error, :invalid_format} ->
        unsubscribe_from_detail(socket)

        {:noreply,
         socket
         |> reset_detail_state(nil, current_tab)
         |> assign(:detail_state, {:error, :invalid_format})}
    end
  end

  @impl true
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:load_detail, biot_id}, %{assigns: %{biot_id: biot_id}} = socket),
    do: {:noreply, load_detail(socket)}

  def handle_info({:load_detail, _stale_biot_id}, socket), do: {:noreply, socket}

  def handle_info({:biot_tab_refresh, biot_id}, %{assigns: %{biot_id: biot_id}} = socket),
    do: {:noreply, load_detail(socket)}

  def handle_info({:biot_tab_refresh, _stale_biot_id}, socket), do: {:noreply, socket}

  def handle_info({:biot_tab_notice, biot_id, notice}, %{assigns: %{biot_id: biot_id}} = socket) do
    {:noreply,
     socket
     |> assign(:action_notice, notice)
     |> load_detail()}
  end

  def handle_info({:biot_tab_notice, _stale_biot_id, _notice}, socket), do: {:noreply, socket}

  def handle_info({:biot_changed, biot_id}, %{assigns: %{biot_id: biot_id}} = socket),
    do: {:noreply, load_detail(socket)}

  def handle_info({:biot_changed, _stale_biot_id}, socket), do: {:noreply, socket}

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("refresh-detail", _params, socket) do
    {:noreply, load_detail(socket)}
  end

  def handle_event("start", _params, socket), do: lifecycle(socket, :start)
  def handle_event("stop", _params, socket), do: lifecycle(socket, :stop)
  def handle_event("rebuild", _params, socket), do: lifecycle(socket, :rebuild)

  def handle_event("arm-destroy", _params, socket),
    do: {:noreply, assign(socket, :armed_destroy, true)}

  def handle_event("cancel-destroy", _params, socket),
    do: {:noreply, assign(socket, :armed_destroy, false)}

  def handle_event("destroy", _params, socket) do
    case loaded_detail(socket) do
      %{view: %{id: biot_id}} when socket.assigns.armed_destroy ->
        case Biots.destroy(socket.assigns.actor, biot_id) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign(:armed_destroy, false)
             |> assign(:action_notice, "destroy accepted; the Biot is being removed.")
             |> load_detail()}

          {:error, error} ->
            {:noreply, assign(socket, :action_error, error)}
        end

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("view-diagnostic", _params, socket) do
    case diagnostic_ref(loaded_detail(socket)) do
      nil ->
        {:noreply, socket}

      reference ->
        state =
          case Diagnostics.get(socket.assigns.actor, reference) do
            {:ok, {content, truncated}} -> {:loaded, content, truncated}
            {:error, reason} -> {:error, reason}
          end

        {:noreply, assign(socket, :diagnostic_state, state)}
    end
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <.app_shell current_section={@current_section} biot_count={@biot_count} node_count={@node_count}>
      <div :if={@detail_state == :loading} class="loading-state" role="status">loading biot…</div>

      <div :if={match?({:error, _reason}, @detail_state)} class="error-state" role="alert">
        <p>this biot could not be loaded.</p>
        <p class="muted">{UserMessage.error(@detail_state)}</p>
        <.link class="button button-secondary" navigate={~p"/biots"}>back to biots</.link>
      </div>

      <div :if={match?({:loaded, _detail}, @detail_state)}>
        <% {:loaded, detail} = @detail_state %>
        <% view = detail.view %>
        <p class="breadcrumb"><.link navigate={~p"/biots"}>biots</.link> / {to_string(view.name)}</p>
        <div class="detail-header page-header">
          <div>
            <p class="eyebrow">biot</p>
            <div class="detail-title-row">
              <h1>{to_string(view.name)}</h1>
              <span class="desired-marker">desired {view.desired.state}</span>
            </div>
            <div class="detail-meta">
              <span class="breakable">id {to_string(view.id)}</span>
              <span class="breakable">node {to_string(view.node_id)}</span>
              <.role role={view.role} />
            </div>
          </div>
          <div class="detail-actions">
            <.operation operation={view.operation} />
            <.link
              :if={shell_allowed?(view)}
              class="button button-mint"
              navigate={~p"/biots/#{view.id}/terminal"}
            >terminal</.link>
            <button
              :if={owner?(view) and view.desired.state == :stopped}
              class="button button-secondary"
              type="button"
              phx-click="start"
              disabled={@action_pending}
              phx-disable-with="starting…"
            >start</button>
            <button
              :if={owner?(view) and view.desired.state == :running}
              class="button button-secondary"
              type="button"
              phx-click="stop"
              disabled={@action_pending}
              phx-disable-with="stopping…"
            >stop</button>
            <button
              :if={owner?(view) and view.desired.state != :destroyed}
              class="button button-secondary"
              type="button"
              phx-click="rebuild"
              disabled={@action_pending}
              phx-disable-with="rebuilding…"
            >rebuild</button>
            <button
              :if={owner?(view) and view.desired.state != :destroyed and not @armed_destroy}
              class="button button-danger"
              type="button"
              phx-click="arm-destroy"
            >destroy</button>
            <span :if={owner?(view) and @armed_destroy} class="confirm-action">
              <span>destroy this Biot?</span>
              <button class="button button-danger" type="button" phx-click="destroy">confirm</button>
              <button class="text-button" type="button" phx-click="cancel-destroy">cancel</button>
            </span>
          </div>
        </div>

        <p :if={@action_error} class="form-error" role="alert">
          {UserMessage.error(@action_error)}
        </p>
        <p :if={@action_notice} class="inline-notice" role="status">{@action_notice}</p>

        <nav class="detail-tabs" aria-label="Biot sections">
          <.link
            class={tab_class(@current_tab, :overview)}
            aria-current={tab_current(@current_tab, :overview)}
            patch={~p"/biots/#{view.id}"}
          >overview</.link>
          <.link
            class={tab_class(@current_tab, :publications)}
            aria-current={tab_current(@current_tab, :publications)}
            patch={~p"/biots/#{view.id}/publications"}
          >
            publications
          </.link>
          <.link
            :if={owner?(view)}
            class={tab_class(@current_tab, :access)}
            aria-current={tab_current(@current_tab, :access)}
            patch={~p"/biots/#{view.id}/access"}
          >
            access
          </.link>
          <.link
            :if={owner?(view)}
            class={tab_class(@current_tab, :secrets)}
            aria-current={tab_current(@current_tab, :secrets)}
            patch={~p"/biots/#{view.id}/secrets"}
          >secrets</.link>
          <.link
            :if={logs_visible?(view)}
            class={tab_class(@current_tab, :logs)}
            aria-current={tab_current(@current_tab, :logs)}
            patch={~p"/biots/#{view.id}/logs"}
          >logs</.link>
        </nav>

        <.live_component
          :if={@current_tab != :overview and tab_visible?(view, @current_tab)}
          module={BiotWeb.Live.BiotTabLive}
          id={"biot-tab-#{view.id}"}
          actor={@actor}
          biot_id={view.id}
          view={view}
          tab={@current_tab}
        />

        <div
          :if={@current_tab != :overview and not tab_visible?(view, @current_tab)}
          class="error-state"
          role="alert"
        >
          <p>this section is not available for your role.</p>
          <.link class="button button-secondary" navigate={~p"/biots/#{view.id}"}>view overview</.link>
        </div>

        <div :if={@current_tab == :overview}>
          <.overview
            view={view}
            detail={detail}
            deployment_state={@deployment_state}
            diagnostic_state={@diagnostic_state}
          />
        </div>
      </div>
    </.app_shell>
    """
  end

  defp load_detail(socket) do
    states = BiotDetailData.load(socket.assigns.actor, socket.assigns.biot_id)

    socket
    |> assign(:detail_state, result_state(states.detail_state))
    |> assign(:deployment_state, result_state(states.deployment_state))
    |> assign(:action_pending, false)
  end

  defp subscribe_to_detail(socket, biot_id) do
    if connected?(socket) and socket.assigns.biot_id != biot_id do
      unsubscribe_from_detail(socket)
      :ok = BiotChange.subscribe(biot_id)
    end

    socket
  end

  defp unsubscribe_from_detail(socket) do
    if connected?(socket) do
      case socket.assigns.biot_id do
        %BiotId{} = biot_id -> BiotChange.unsubscribe(biot_id)
        nil -> :ok
      end
    end
  end

  defp reset_detail_state(socket, biot_id, current_tab) do
    socket
    |> assign(:biot_id, biot_id)
    |> assign(:current_tab, current_tab)
    |> assign(:detail_state, :loading)
    |> assign(:deployment_state, :loading)
    |> assign(:diagnostic_state, :idle)
    |> assign(:action_error, nil)
    |> assign(:action_notice, nil)
    |> assign(:armed_destroy, false)
    |> assign(:action_pending, false)
  end

  defp lifecycle(socket, :rebuild) do
    case loaded_detail(socket) do
      %{view: view, environment: environment} ->
        if owner?(view) and view.desired.state != :destroyed do
          socket = assign(socket, :action_pending, true)

          result =
            Biots.update_environment(
              socket.assigns.actor,
              view.id,
              %SelectEnvironment{selection: environment},
              view.desired.revision
            )

          handle_lifecycle_result(socket, result, "rebuild")
        else
          {:noreply, socket}
        end

      _other ->
        {:noreply, socket}
    end
  end

  defp lifecycle(socket, change) when change in [:start, :stop] do
    case loaded_detail(socket) do
      %{view: view} -> owned_lifecycle(socket, view, change)
      _other -> {:noreply, socket}
    end
  end

  defp owned_lifecycle(socket, view, change) do
    if owner?(view) do
      socket = assign(socket, :action_pending, true)

      result =
        case change do
          :start -> Biots.start(socket.assigns.actor, view.id, view.desired.revision)
          :stop -> Biots.stop(socket.assigns.actor, view.id, view.desired.revision)
        end

      handle_lifecycle_result(socket, result, Atom.to_string(change))
    else
      {:noreply, socket}
    end
  end

  defp handle_lifecycle_result(socket, {:ok, _result}, label) do
    {:noreply,
     socket
     |> assign(:action_pending, false)
     |> assign(:action_error, nil)
     |> assign(:action_notice, "#{label} accepted; the operation is now server-owned.")
     |> load_detail()}
  end

  defp handle_lifecycle_result(socket, {:error, {:revision_conflict, current_revision}}, _label) do
    {:noreply,
     socket
     |> assign(:action_pending, false)
     |> assign(:action_error, {:revision_conflict, current_revision})
     |> load_detail()}
  end

  defp handle_lifecycle_result(socket, {:error, error}, _label),
    do: {:noreply, assign(socket, action_pending: false, action_error: error)}

  defp result_state({:ok, value}), do: {:loaded, value}
  defp result_state({:error, reason}), do: {:error, reason}

  defp loaded_detail(%{assigns: %{detail_state: {:loaded, detail}}}), do: detail
  defp loaded_detail(%{assigns: %{detail_state: detail}}) when is_map(detail), do: detail
  defp loaded_detail(_socket), do: nil

  defp tab_class(current, tab),
    do: if(current == tab, do: "detail-tab is-active", else: "detail-tab")

  defp tab_current(current, tab), do: if(current == tab, do: "page")

  defp tab_visible?(view, tab), do: BiotTabs.visible?(view, tab)

  defp owner?(%{role: :owner}), do: true
  defp owner?(_view), do: false

  defp logs_visible?(view), do: BiotTabs.visible?(view, :logs)

  defp shell_allowed?(view), do: ShellAvailability.allowed?(view)

  defp diagnostic_ref(%{view: view}), do: diagnostic_ref(view)

  defp diagnostic_ref(view) do
    case BiotState.current_failure(view) do
      %{diagnostic_ref: reference} -> reference
      _none -> nil
    end
  end
end
