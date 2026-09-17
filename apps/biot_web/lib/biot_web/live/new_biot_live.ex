defmodule BiotWeb.Live.NewBiotLive do
  @moduledoc "Creates a Biot and coordinates optional initial credential delivery."

  use BiotWeb, :live_view

  import BiotWeb.Components.AppShell

  alias Biot.Protocol.{BiotId, Failure, RepositorySource}
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Biots.Unchanged
  alias Biot.Server.FetchCredentials
  alias Biot.Server.Queries.Nodes
  alias Biot.Server.Secrets
  alias BiotWeb.Live.BiotDetailData
  alias BiotWeb.Live.Navigation
  alias BiotWeb.Live.NewBiotForm
  alias BiotWeb.Live.NewBiotWorkflow
  alias BiotWeb.UserMessage

  @workflow_poll_ms 2_000

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(Navigation.counts(socket.assigns.actor))
      |> assign(:current_section, :biots)
      |> assign(:form_error, nil)
      |> assign(:creation_biot_id, nil)
      |> assign(:creation_workflow, nil)
      |> assign(:creation_view, nil)
      |> assign(:repository, "")
      |> assign(:name, "")
      |> assign(:node_id, "")
      |> assign(:base_source, "nixpkgs")
      |> assign(:base_ref, "")
      |> assign(:initial_state, "running")
      |> assign(:layers, [NewBiotForm.empty_layer(0)])
      |> assign(:runtime_secrets, [NewBiotForm.empty_runtime_secret(0)])
      |> assign(:source_credentials, [NewBiotForm.empty_source_credential(0)])
      |> assign(:node_options_state, :loading)

    if connected?(socket), do: send(self(), :load_node_options)

    {:ok, socket}
  end

  @impl true
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(:load_node_options, socket) do
    state =
      case Nodes.list(socket.assigns.actor) do
        {:ok, nodes} -> {:loaded, Enum.filter(nodes, &(&1.status == :enabled))}
        {:error, reason} -> {:error, reason}
      end

    {:noreply, assign(socket, :node_options_state, state)}
  end

  def handle_info({:creation_progress, biot_id}, socket) do
    case socket.assigns.creation_workflow do
      %NewBiotWorkflow{biot_id: ^biot_id} = workflow ->
        advance_workflow(socket, workflow)

      _other ->
        {:noreply, socket}
    end
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("change", params, socket), do: {:noreply, preserve_form(socket, params)}

  def handle_event("add-layer", _params, socket) do
    {:noreply,
     assign(
       socket,
       :layers,
       socket.assigns.layers ++ [NewBiotForm.empty_layer(next_id(socket.assigns.layers))]
     )}
  end

  def handle_event("remove-layer", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, :layers, remove_row(socket.assigns.layers, id, &NewBiotForm.empty_layer/1))}
  end

  def handle_event("add-runtime-secret", _params, socket) do
    rows = socket.assigns.runtime_secrets

    {:noreply,
     assign(socket, :runtime_secrets, rows ++ [NewBiotForm.empty_runtime_secret(next_id(rows))])}
  end

  def handle_event("remove-runtime-secret", %{"id" => id}, socket) do
    {:noreply,
     assign(
       socket,
       :runtime_secrets,
       remove_row(socket.assigns.runtime_secrets, id, &NewBiotForm.empty_runtime_secret/1)
     )}
  end

  def handle_event("add-source-credential", _params, socket) do
    rows = socket.assigns.source_credentials

    {:noreply,
     assign(
       socket,
       :source_credentials,
       rows ++ [NewBiotForm.empty_source_credential(next_id(rows))]
     )}
  end

  def handle_event("remove-source-credential", %{"id" => id}, socket) do
    {:noreply,
     assign(
       socket,
       :source_credentials,
       remove_row(socket.assigns.source_credentials, id, &NewBiotForm.empty_source_credential/1)
     )}
  end

  def handle_event("create", _params, %{assigns: %{creation_workflow: workflow}} = socket)
      when not is_nil(workflow),
      do: {:noreply, socket}

  def handle_event("create", params, socket) do
    socket = preserve_form(socket, params)

    case NewBiotForm.parse(params) do
      {:error, error} ->
        {:noreply, assign(socket, :form_error, error)}

      {:ok,
       %{
         command: command,
         final_state: final_state,
         runtime_secrets: runtime_secrets,
         source_credentials: source_credentials
       }} ->
        biot_id = socket.assigns.creation_biot_id || BiotId.generate()

        case Biots.create(socket.assigns.actor, biot_id, command) do
          {:ok, %Accepted{biot_id: created_id}} ->
            start_creation(
              socket,
              created_id,
              final_state,
              runtime_secrets,
              source_credentials
            )

          {:ok, %Unchanged{biot_id: existing_id}} ->
            start_creation(
              socket,
              existing_id,
              final_state,
              runtime_secrets,
              source_credentials
            )

          {:error, error} ->
            {:noreply,
             socket
             |> assign(:creation_biot_id, biot_id)
             |> assign(:form_error, error)}
        end
    end
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :creation_fetch_source,
        creation_fetch_source(Map.get(assigns, :creation_view))
      )
      |> assign(
        :form_summary,
        UserMessage.summary(assigns.form_error, [
          :repository,
          :name,
          :node_id,
          :environment,
          :runtime_secrets,
          :source_credentials
        ])
      )

    ~H"""
    <.app_shell current_section={@current_section} biot_count={@biot_count} node_count={@node_count}>
      <p class="breadcrumb"><.link navigate={~p"/biots"}>biots</.link> / new</p>
      <div class="page-header">
        <div>
          <p class="eyebrow">workspace</p>
          <h1>new biot</h1>
          <p class="page-lede">Create a development environment from a pinned source selection.</p>
        </div>
      </div>

      <section
        :if={@creation_workflow}
        class={
          if(workflow_failed?(@creation_workflow),
            do: "surface workflow-notice workflow-failed",
            else: "surface workflow-notice"
          )
        }
        aria-live="polite"
      >
        <h2>
          {if workflow_failed?(@creation_workflow), do: "creation stopped", else: "creating biot"}
        </h2>
        <p>{workflow_message(@creation_workflow)}</p>
        <p :if={workflow_failed?(@creation_workflow)} class="muted">
          The Biot remains stopped. Open its detail page to inspect the operation or deliver the missing value.
        </p>
        <div :if={@creation_fetch_source} class="workflow-wait" role="status">
          <strong>fetch credential required</strong>
          <span>
            The node is waiting for access to <code translate="no">{@creation_fetch_source}</code>.
          </span>
          <.link
            class="button button-secondary"
            navigate={~p"/biots/#{@creation_workflow.biot_id}/secrets"}
          >deliver credential</.link>
        </div>
        <.link
          class="button button-secondary"
          navigate={~p"/biots/#{@creation_workflow.biot_id}"}
        >
          open biot
        </.link>
      </section>

      <form
        :if={is_nil(@creation_workflow)}
        id="new-biot-form"
        class="biot-form"
        phx-change="change"
        phx-submit="create"
        phx-hook="FormBehavior"
        data-unsaved-changes="true"
      >
        <p :if={@form_summary} class="form-error" role="alert">{@form_summary}</p>

        <div class="form-field">
          <label for="biot-repository">repository HTTPS URL</label>
          <input
            id="biot-repository"
            name="repository"
            type="url"
            value={@repository}
            required
            autocomplete="url"
            placeholder="https://example.com/project.git…"
          />
          <p
            :for={error <- UserMessage.field_errors(@form_error, :repository)}
            class="field-error"
            role="alert"
          >
            {UserMessage.field_error(:repository, error)}
          </p>
        </div>

        <div class="form-field">
          <label for="biot-name">biot name</label>
          <input
            id="biot-name"
            name="name"
            type="text"
            value={@name}
            required
            autocomplete="off"
            spellcheck="false"
          />
          <p
            :for={error <- UserMessage.field_errors(@form_error, :name)}
            class="field-error"
            role="alert"
          >
            {UserMessage.field_error(:name, error)}
          </p>
        </div>

        <div class="form-field">
          <label for="biot-node">node</label>
          <select id="biot-node" name="node_id">
            <option value="" selected={@node_id in ["", "default"]}>server picks</option>
            <option
              :for={node <- node_options(@node_options_state)}
              value={to_string(node.id)}
              selected={@node_id == to_string(node.id)}
            >
              {to_string(node.id)}
            </option>
          </select>
          <p :if={match?({:error, _reason}, @node_options_state)} class="field-hint">
            Node options are unavailable; server picks will still be validated at creation.
          </p>
          <p
            :for={error <- UserMessage.field_errors(@form_error, :node_id)}
            class="field-error"
            role="alert"
          >
            {UserMessage.field_error(:node_id, error)}
          </p>
        </div>

        <fieldset class="form-group">
          <legend>base package-set source</legend>
          <div class="form-grid-two">
            <div class="form-field">
              <label for="base-source">source or nixpkgs</label>
              <input
                id="base-source"
                name="base_source"
                type="text"
                value={@base_source}
                required
                autocomplete="off"
                spellcheck="false"
                placeholder="nixpkgs…"
              />
            </div>
            <div class="form-field">
              <label for="base-ref">ref</label>
              <input
                id="base-ref"
                name="base_ref"
                type="text"
                value={@base_ref}
                autocomplete="off"
                spellcheck="false"
              />
            </div>
          </div>
          <p
            :for={error <- UserMessage.field_errors(@form_error, :environment)}
            class="field-error"
            role="alert"
          >
            {UserMessage.field_error(:environment, error)}
          </p>
        </fieldset>

        <fieldset class="form-group">
          <legend>layers</legend>
          <div :for={layer <- @layers} class="repeatable-row">
            <div class="form-field">
              <label for={"layer-source-#{layer.id}"}>source</label>
              <input
                id={"layer-source-#{layer.id}"}
                name={"layers[#{layer.id}][source]"}
                type="url"
                value={layer.source}
                autocomplete="url"
              />
            </div>
            <div class="form-field">
              <label for={"layer-ref-#{layer.id}"}>ref</label>
              <input
                id={"layer-ref-#{layer.id}"}
                name={"layers[#{layer.id}][ref]"}
                type="text"
                value={layer.ref}
                autocomplete="off"
                spellcheck="false"
              />
            </div>
            <button
              class="button button-secondary row-remove"
              type="button"
              phx-click="remove-layer"
              phx-value-id={layer.id}
            >remove</button>
          </div>
          <p
            :for={error <- UserMessage.field_errors(@form_error, :environment)}
            class="field-error"
            role="alert"
          >
            {UserMessage.field_error(:environment, error)}
          </p>
          <button class="button button-secondary" type="button" phx-click="add-layer">add layer</button>
        </fieldset>

        <fieldset class="form-group">
          <legend>after creation</legend>
          <div class="choice-row" role="radiogroup" aria-label="after creation">
            <label class="choice-label"><input
              type="radio"
              name="initial_state"
              value="running"
              checked={@initial_state == "running"}
            /> start</label>
            <label class="choice-label"><input
              type="radio"
              name="initial_state"
              value="stopped"
              checked={@initial_state == "stopped"}
            /> stay stopped</label>
          </div>
        </fieldset>

        <fieldset class="form-group">
          <legend>runtime secrets <span class="field-hint">optional</span></legend>
          <p class="field-hint">Values are delivered to the node and never stored by the server.</p>
          <div :for={secret <- @runtime_secrets} class="repeatable-row">
            <div class="form-field">
              <label for={"secret-name-#{secret.id}"}>name</label>
              <input
                id={"secret-name-#{secret.id}"}
                name={"runtime_secrets[#{secret.id}][name]"}
                type="text"
                value={secret.name}
                autocomplete="off"
                spellcheck="false"
              />
            </div>
            <div class="form-field">
              <label for={"secret-value-#{secret.id}"}>value</label>
              <input
                id={"secret-value-#{secret.id}"}
                name={"runtime_secrets[#{secret.id}][value]"}
                type="password"
                autocomplete="new-password"
              />
            </div>
            <button
              class="button button-secondary row-remove"
              type="button"
              phx-click="remove-runtime-secret"
              phx-value-id={secret.id}
            >remove</button>
          </div>
          <p
            :for={error <- UserMessage.field_errors(@form_error, :runtime_secrets)}
            class="field-error"
            role="alert"
          >
            {UserMessage.field_error(:runtime_secrets, error)}
          </p>
          <button class="button button-secondary" type="button" phx-click="add-runtime-secret">add secret</button>
        </fieldset>

        <fieldset class="form-group">
          <legend>source-fetch credentials <span class="field-hint">optional</span></legend>
          <p class="field-hint">Each authorization value is scoped to its exact HTTPS source.</p>
          <div :for={credential <- @source_credentials} class="repeatable-row">
            <div class="form-field">
              <label for={"credential-source-#{credential.id}"}>source URL</label>
              <input
                id={"credential-source-#{credential.id}"}
                name={"source_credentials[#{credential.id}][source]"}
                type="url"
                value={credential.source}
                autocomplete="url"
              />
            </div>
            <div class="form-field">
              <label for={"credential-value-#{credential.id}"}>authorization</label>
              <input
                id={"credential-value-#{credential.id}"}
                name={"source_credentials[#{credential.id}][value]"}
                type="password"
                autocomplete="new-password"
              />
            </div>
            <button
              class="button button-secondary row-remove"
              type="button"
              phx-click="remove-source-credential"
              phx-value-id={credential.id}
            >remove</button>
          </div>
          <p
            :for={error <- UserMessage.field_errors(@form_error, :source_credentials)}
            class="field-error"
            role="alert"
          >
            {UserMessage.field_error(:source_credentials, error)}
          </p>
          <button class="button button-secondary" type="button" phx-click="add-source-credential">add credential</button>
        </fieldset>

        <button class="button button-primary form-submit" type="submit" phx-disable-with="creating…">create</button>
      </form>
    </.app_shell>
    """
  end

  defp start_creation(socket, biot_id, _final_state, [], []) do
    {:noreply, push_navigate(socket, to: ~p"/biots/#{biot_id}")}
  end

  defp start_creation(socket, biot_id, final_state, runtime_secrets, source_credentials) do
    workflow = NewBiotWorkflow.new(biot_id, final_state, runtime_secrets, source_credentials)

    send(self(), {:creation_progress, biot_id})

    {:noreply,
     socket
     |> assign(:creation_biot_id, biot_id)
     |> assign(:creation_workflow, workflow)
     |> assign(:creation_view, nil)
     |> assign(:form_error, nil)}
  end

  defp advance_workflow(socket, %NewBiotWorkflow{status: :failed}), do: {:noreply, socket}

  defp advance_workflow(socket, %NewBiotWorkflow{} = workflow) do
    case load_created_view(socket, workflow.biot_id) do
      {:ok, view} ->
        socket
        |> assign(:creation_view, view)
        |> apply_workflow_decision(workflow, NewBiotWorkflow.advance(workflow, view), view)

      {:error, reason} ->
        socket
        |> assign(:creation_view, nil)
        |> workflow_failure(workflow, workflow.phase, {:uncertain, reason})
    end
  end

  defp apply_workflow_decision(socket, workflow, {:wait, workflow}, _view),
    do: schedule_workflow(socket, workflow)

  defp apply_workflow_decision(socket, workflow, {:deliver_sources, workflow}, _view),
    do: deliver_sources(socket, workflow)

  defp apply_workflow_decision(socket, workflow, {:deliver_runtime_secrets, workflow}, _view),
    do: deliver_runtime_secrets(socket, workflow)

  defp apply_workflow_decision(socket, workflow, {:start, workflow}, view),
    do: start_after_credentials(socket, workflow, view)

  defp apply_workflow_decision(socket, workflow, {:finish, workflow}, _view),
    do: finish_creation(socket, workflow)

  defp apply_workflow_decision(socket, _workflow, {:failed, failed_workflow}, _view),
    do: {:noreply, assign(socket, :creation_workflow, failed_workflow)}

  defp deliver_sources(socket, %NewBiotWorkflow{source_credentials: []} = workflow) do
    schedule_workflow(socket, NewBiotWorkflow.sources_delivered(workflow))
  end

  defp deliver_sources(socket, %NewBiotWorkflow{source_credentials: credentials} = workflow) do
    result =
      Enum.reduce_while(credentials, :ok, fn %{source: source, value: value}, :ok ->
        case FetchCredentials.deliver(socket.assigns.actor, workflow.biot_id, source, value) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      :ok ->
        schedule_workflow(socket, NewBiotWorkflow.sources_delivered(workflow))

      {:error, reason} ->
        workflow_failure(socket, workflow, :source_credentials, delivery_reason(reason))
    end
  end

  defp deliver_runtime_secrets(socket, %NewBiotWorkflow{runtime_secrets: []} = workflow) do
    schedule_workflow(socket, NewBiotWorkflow.runtime_secrets_delivered(workflow))
  end

  defp deliver_runtime_secrets(socket, %NewBiotWorkflow{runtime_secrets: secrets} = workflow) do
    result =
      Enum.reduce_while(secrets, :ok, fn %{name: name, value: value}, :ok ->
        case Secrets.deliver(socket.assigns.actor, workflow.biot_id, name, value) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      :ok ->
        schedule_workflow(socket, NewBiotWorkflow.runtime_secrets_delivered(workflow))

      {:error, reason} ->
        workflow_failure(socket, workflow, :runtime_secrets, delivery_reason(reason))
    end
  end

  defp start_after_credentials(socket, %NewBiotWorkflow{} = workflow, view) do
    case Biots.start(socket.assigns.actor, workflow.biot_id, view.desired.revision) do
      {:ok, _result} ->
        {:noreply,
         push_navigate(assign(socket, :creation_workflow, nil),
           to: ~p"/biots/#{workflow.biot_id}"
         )}

      {:error, reason} ->
        workflow_failure(socket, workflow, :start, reason)
    end
  end

  defp finish_creation(socket, %NewBiotWorkflow{} = workflow) do
    {:noreply,
     push_navigate(assign(socket, :creation_workflow, nil),
       to: ~p"/biots/#{workflow.biot_id}"
     )}
  end

  defp load_created_view(socket, biot_id),
    do: Biot.Server.Queries.Biots.get(socket.assigns.actor, biot_id)

  defp schedule_workflow(socket, %NewBiotWorkflow{} = workflow) do
    Process.send_after(self(), {:creation_progress, workflow.biot_id}, @workflow_poll_ms)
    {:noreply, assign(socket, :creation_workflow, workflow)}
  end

  defp workflow_failure(socket, %NewBiotWorkflow{} = workflow, phase, reason) do
    {:noreply,
     assign(socket, :creation_workflow, NewBiotWorkflow.failed(workflow, phase, reason))}
  end

  defp workflow_failed?(%NewBiotWorkflow{status: :failed}), do: true
  defp workflow_failed?(_workflow), do: false

  defp workflow_message(%NewBiotWorkflow{
         status: :failed,
         phase: phase,
         reason: %Failure{} = failure
       }),
       do: "#{phase_label(phase)} failed: #{UserMessage.failure_message(failure)}"

  defp workflow_message(%NewBiotWorkflow{status: :failed, phase: phase, reason: reason}),
    do: "#{phase_label(phase)} failed: #{UserMessage.error(reason)}"

  defp workflow_message(%NewBiotWorkflow{phase: :allocation}),
    do: "Waiting for the node to allocate the Biot."

  defp workflow_message(%NewBiotWorkflow{phase: :preparation}),
    do: "Waiting for environment preparation to finish."

  defp workflow_message(%NewBiotWorkflow{phase: :starting, final_state: :stopped}),
    do: "Finishing preparation; the Biot will remain stopped."

  defp workflow_message(%NewBiotWorkflow{phase: :starting, final_state: :running}),
    do: "Waiting for the Biot to start."

  defp workflow_message(%NewBiotWorkflow{phase: phase, reason: reason}),
    do: "#{phase_label(phase)} failed: #{UserMessage.error(reason)}"

  defp phase_label(:source_credentials), do: "source credential delivery"
  defp phase_label(:runtime_secrets), do: "runtime secret delivery"
  defp phase_label(phase), do: Atom.to_string(phase)

  defp creation_fetch_source(view) do
    case BiotDetailData.waiting_fetch_source(view) do
      %RepositorySource{url: url} -> url
      nil -> nil
    end
  end

  defp delivery_reason({:error, reason}), do: reason
  defp delivery_reason(reason), do: reason

  defp preserve_form(socket, params) do
    socket
    |> assign(:repository, Map.get(params, "repository", socket.assigns.repository))
    |> assign(:name, Map.get(params, "name", socket.assigns.name))
    |> assign(:node_id, Map.get(params, "node_id", socket.assigns.node_id))
    |> assign(:base_source, Map.get(params, "base_source", socket.assigns.base_source))
    |> assign(:base_ref, Map.get(params, "base_ref", socket.assigns.base_ref))
    |> assign(:initial_state, Map.get(params, "initial_state", socket.assigns.initial_state))
    |> assign(:layers, preserve_rows(Map.get(params, "layers", %{}), :layer))
    |> assign(
      :runtime_secrets,
      preserve_rows(Map.get(params, "runtime_secrets", %{}), :runtime_secret)
    )
    |> assign(
      :source_credentials,
      preserve_rows(Map.get(params, "source_credentials", %{}), :source_credential)
    )
  end

  defp preserve_rows(params, kind) do
    rows =
      if is_map(params), do: Enum.sort_by(params, fn {key, _} -> row_index(key) end), else: []

    case Enum.map(rows, &preserve_row(&1, kind)) do
      [] -> [empty_row(kind)]
      preserved -> preserved
    end
  end

  defp preserve_row({id, row}, :layer),
    do: %{id: to_string(id), source: Map.get(row, "source", ""), ref: Map.get(row, "ref", "")}

  defp preserve_row({id, row}, :runtime_secret),
    do: %{id: to_string(id), name: Map.get(row, "name", "")}

  defp preserve_row({id, row}, :source_credential),
    do: %{id: to_string(id), source: Map.get(row, "source", "")}

  defp empty_row(:layer), do: NewBiotForm.empty_layer(0)
  defp empty_row(:runtime_secret), do: NewBiotForm.empty_runtime_secret(0)
  defp empty_row(:source_credential), do: NewBiotForm.empty_source_credential(0)

  defp next_id(rows) do
    rows
    |> Enum.map(&to_string(&1.id))
    |> Enum.map(&Integer.parse/1)
    |> Enum.flat_map(fn
      {id, ""} -> [id]
      _other -> []
    end)
    |> then(fn ids -> if ids == [], do: 0, else: Enum.max(ids) + 1 end)
  end

  defp row_index(key) do
    case Integer.parse(to_string(key)) do
      {index, ""} -> {0, index}
      _other -> {1, to_string(key)}
    end
  end

  defp remove_row(rows, id, empty) do
    rows = Enum.reject(rows, &(to_string(&1.id) == id))
    if rows == [], do: [empty.(0)], else: rows
  end

  defp node_options({:loaded, nodes}), do: nodes
  defp node_options(_state), do: []
end
