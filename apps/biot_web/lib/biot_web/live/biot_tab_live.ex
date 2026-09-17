defmodule BiotWeb.Live.BiotTabLive do
  @moduledoc "Owns one route-backed Biot tab's reads and mutations."

  use BiotWeb, :live_component

  import BiotWeb.Components.Access
  import BiotWeb.Components.BiotLogs
  import BiotWeb.Components.BiotSecrets
  import BiotWeb.Components.Publication

  alias Biot.Protocol.{
    AuthorizationValue,
    Port,
    PrincipalId,
    RepositorySource,
    SecretName,
    SecretValue
  }

  alias Biot.Server.Access
  alias Biot.Server.CommandError
  alias Biot.Server.FetchCredentials
  alias Biot.Server.Principals
  alias Biot.Server.Publications
  alias Biot.Server.Queries.AccessDisplayView
  alias Biot.Server.Secrets
  alias BiotWeb.Live.BiotDetailData
  alias BiotWeb.UserMessage

  @protocol_version Enum.max(Biot.Protocol.Version.supported())

  @impl true
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    {:ok,
     assign(socket,
       publication_state: :idle,
       access_state: :idle,
       secret_state: :idle,
       logs_state: :idle,
       publish_port: "",
       publish_error: nil,
       armed_unpublish: nil,
       publication_pending: false,
       share_email: "",
       share_kind: "shell",
       share_error: nil,
       access_action_error: nil,
       armed_revoke: nil,
       access_pending: false,
       secret_name: "",
       secret_error: nil,
       armed_secret: nil,
       secret_pending: false,
       fetch_error: nil,
       fetch_pending: false
     )}
  end

  @impl true
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(%{actor: actor, biot_id: biot_id, view: view, tab: tab}, socket) do
    biot_changed? = socket.assigns[:biot_id] != biot_id
    tab_changed? = socket.assigns[:tab] != tab

    socket =
      socket
      |> assign(:actor, actor)
      |> assign(:biot_id, biot_id)
      |> assign(:view, view)
      |> assign(:tab, tab)

    socket =
      cond do
        biot_changed? -> socket |> reset_state() |> load_tab(actor, biot_id, tab)
        tab_changed? -> load_tab(socket, actor, biot_id, tab)
        true -> socket
      end

    {:ok, socket}
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div>
      <div :if={@tab == :publications}>
        <.publication_panel
          publication_state={@publication_state}
          owner={@view.role == :owner}
          publish_port={@publish_port}
          publish_error={@publish_error}
          armed_unpublish={@armed_unpublish}
          pending={@publication_pending}
          enforcement={@view.access.enforcement}
          access_revision={@view.access.revision}
          target={@myself}
        />
      </div>
      <div :if={@tab == :access and @view.role == :owner}>
        <.access_panel
          access_state={@access_state}
          publications={loaded_publications(@publication_state)}
          share_email={@share_email}
          share_kind={@share_kind}
          share_error={@share_error}
          action_error={@access_action_error}
          armed_revoke={@armed_revoke}
          pending={@access_pending}
          enforcement={@view.access.enforcement}
          access_revision={@view.access.revision}
          target={@myself}
        />
      </div>
      <div :if={@tab == :secrets and @view.role == :owner}>
        <.secrets_panel
          secret_state={@secret_state}
          secret_name={@secret_name}
          secret_error={@secret_error}
          armed_remove={@armed_secret}
          pending={@secret_pending}
          fetch_source={BiotDetailData.waiting_fetch_source(@view)}
          fetch_error={@fetch_error}
          fetch_pending={@fetch_pending}
          target={@myself}
        />
      </div>
      <div :if={@tab == :logs}>
        <.logs_panel logs_state={@logs_state} target={@myself} />
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("refresh-detail", _params, socket) do
    send(self(), {:biot_tab_refresh, socket.assigns.biot_id})
    {:noreply, reload(socket)}
  end

  def handle_event("refresh-secrets", _params, socket), do: {:noreply, reload(socket)}

  def handle_event("refresh-logs", _params, socket), do: {:noreply, reload(socket)}

  def handle_event("publish", %{"port" => value}, socket) do
    socket = assign(socket, publish_port: value, publish_error: nil)

    with {:ok, port} <- Port.parse(value), :owner <- socket.assigns.view.role do
      socket = assign(socket, :publication_pending, true)

      case Publications.publish(socket.assigns.actor, socket.assigns.biot_id, port) do
        {:ok, result} ->
          {:noreply,
           socket
           |> assign(publish_port: "", publish_error: nil, publication_pending: false)
           |> notify_parent(policy_notice("publish", result))
           |> reload()}

        {:error, error} ->
          {:noreply, assign(socket, publication_pending: false, publish_error: error)}
      end
    else
      {:error, reason} ->
        {:noreply,
         assign(socket,
           publication_pending: false,
           publish_error: CommandError.invalid_input(%{port: [reason]})
         )}

      _not_owner ->
        {:noreply, socket}
    end
  end

  def handle_event("publish", _params, socket), do: {:noreply, socket}

  def handle_event("arm-unpublish", %{"port" => port}, socket) do
    if active_publication?(socket.assigns.publication_state, port),
      do: {:noreply, assign(socket, :armed_unpublish, port)},
      else: {:noreply, socket}
  end

  def handle_event("cancel-unpublish", _params, socket),
    do: {:noreply, assign(socket, :armed_unpublish, nil)}

  def handle_event("unpublish", %{"port" => value}, socket) do
    with true <- socket.assigns.armed_unpublish == value,
         {:ok, port} <- Port.parse(value),
         :owner <- socket.assigns.view.role do
      socket = assign(socket, :publication_pending, true)

      case Publications.unpublish(socket.assigns.actor, socket.assigns.biot_id, port) do
        {:ok, result} ->
          {:noreply,
           socket
           |> assign(armed_unpublish: nil, publication_pending: false, publish_error: nil)
           |> notify_parent(policy_notice("unpublish", result))
           |> reload()}

        {:error, error} ->
          {:noreply,
           assign(socket, armed_unpublish: nil, publication_pending: false, publish_error: error)}
      end
    else
      {:error, reason} ->
        {:noreply,
         assign(socket,
           armed_unpublish: nil,
           publication_pending: false,
           publish_error: CommandError.invalid_input(%{port: [reason]})
         )}

      _invalid ->
        {:noreply, socket}
    end
  end

  def handle_event("unpublish", _params, socket), do: {:noreply, socket}

  def handle_event("share", %{"email" => email, "kind" => kind}, socket) do
    socket = assign(socket, share_email: email, share_kind: kind, share_error: nil)

    with {:ok, grant} <- share_kind(kind, socket.assigns.publication_state),
         {:ok, principal_id} <- Principals.resolve_email(socket.assigns.actor, email),
         :owner <- socket.assigns.view.role do
      socket = assign(socket, :access_pending, true)

      result =
        case grant do
          :shell ->
            Access.grant_shell(socket.assigns.actor, socket.assigns.biot_id, principal_id)

          {:view, port} ->
            Access.grant_view(socket.assigns.actor, socket.assigns.biot_id, port, principal_id)
        end

      case result do
        {:ok, policy_result} ->
          {:noreply,
           socket
           |> assign(share_email: "", share_error: nil, access_pending: false)
           |> notify_parent(policy_notice("share", policy_result))
           |> reload()}

        {:error, error} ->
          {:noreply, assign(socket, access_pending: false, share_error: error)}
      end
    else
      {:error, :not_found} ->
        {:noreply,
         assign(socket,
           access_pending: false,
           share_error: CommandError.invalid_input(%{email: [:unknown_principal]})
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           access_pending: false,
           share_error: CommandError.invalid_input(%{kind: [reason]})
         )}

      _not_owner ->
        {:noreply, socket}
    end
  end

  def handle_event("share", _params, socket), do: {:noreply, socket}

  def handle_event("arm-revoke", params, socket) do
    case revoke_key(params, socket.assigns.access_state) do
      {:ok, key} -> {:noreply, assign(socket, :armed_revoke, key)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("cancel-revoke", _params, socket),
    do: {:noreply, assign(socket, :armed_revoke, nil)}

  def handle_event("revoke", params, socket) do
    with {:ok, key} <- revoke_key(params, socket.assigns.access_state),
         true <- socket.assigns.armed_revoke == key,
         {:ok, grant_kind} <- revoke_kind(key.kind, key.port),
         {:ok, principal_id} <- PrincipalId.parse(key.principal_id),
         :owner <- socket.assigns.view.role do
      socket = assign(socket, :access_pending, true)

      result =
        case grant_kind do
          :shell ->
            Access.revoke_shell(socket.assigns.actor, socket.assigns.biot_id, principal_id)

          {:view, port} ->
            Access.revoke_view(socket.assigns.actor, socket.assigns.biot_id, port, principal_id)
        end

      case result do
        {:ok, policy_result} ->
          {:noreply,
           socket
           |> assign(
             armed_revoke: nil,
             access_pending: false,
             share_error: nil,
             access_action_error: nil
           )
           |> notify_parent(policy_notice("revoke", policy_result))
           |> reload()}

        {:error, error} ->
          {:noreply,
           assign(socket, armed_revoke: nil, access_pending: false, access_action_error: error)}
      end
    else
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("deliver-secret", %{"name" => name, "value" => value}, socket) do
    with {:ok, secret_name, secret_value} <- parse_secret(name, value),
         :owner <- socket.assigns.view.role do
      socket = assign(socket, secret_name: name, secret_pending: true, secret_error: nil)

      case Secrets.deliver(
             socket.assigns.actor,
             socket.assigns.biot_id,
             secret_name,
             secret_value
           ) do
        :ok ->
          notice = "runtime secret #{secret_name} delivered; its value will not be shown."

          {:noreply,
           socket
           |> assign(
             secret_name: "",
             secret_pending: false,
             secret_error: nil
           )
           |> notify_parent(notice)
           |> reload()}

        {:error, error} ->
          {:noreply, assign(socket, secret_name: "", secret_pending: false, secret_error: error)}
      end
    else
      {:error, error} ->
        {:noreply, assign(socket, secret_name: "", secret_pending: false, secret_error: error)}

      _not_owner ->
        {:noreply, socket}
    end
  end

  def handle_event("arm-remove-secret", %{"name" => name}, socket) do
    if secret_present?(socket.assigns.secret_state, name),
      do: {:noreply, assign(socket, :armed_secret, name)},
      else: {:noreply, socket}
  end

  def handle_event("cancel-remove-secret", _params, socket),
    do: {:noreply, assign(socket, :armed_secret, nil)}

  def handle_event("remove-secret", %{"name" => name}, socket) do
    with true <- socket.assigns.armed_secret == name,
         {:ok, secret_name} <- SecretName.parse(name),
         true <- secret_present?(socket.assigns.secret_state, name),
         :owner <- socket.assigns.view.role do
      socket = assign(socket, :secret_pending, true)

      case Secrets.remove(socket.assigns.actor, socket.assigns.biot_id, secret_name) do
        :ok ->
          notice = "runtime secret #{secret_name} removed."

          {:noreply,
           socket
           |> assign(
             armed_secret: nil,
             secret_name: "",
             secret_pending: false,
             secret_error: nil
           )
           |> notify_parent(notice)
           |> reload()}

        {:error, error} ->
          {:noreply,
           assign(socket,
             armed_secret: nil,
             secret_name: "",
             secret_pending: false,
             secret_error: error
           )}
      end
    else
      {:error, reason} ->
        {:noreply,
         assign(socket,
           armed_secret: nil,
           secret_name: "",
           secret_pending: false,
           secret_error: CommandError.invalid_input(%{name: [reason]})
         )}

      _invalid ->
        {:noreply, socket}
    end
  end

  def handle_event("deliver-fetch-credential", %{"value" => value}, socket) do
    case BiotDetailData.waiting_fetch_source(socket.assigns.view) do
      %RepositorySource{} = source -> deliver_fetch_credential(socket, source, value)
      nil -> {:noreply, assign(socket, :fetch_error, :not_requested)}
    end
  end

  def handle_event("deliver-fetch-credential", _params, socket), do: {:noreply, socket}

  defp deliver_fetch_credential(socket, source, value) do
    with :owner <- socket.assigns.view.role,
         {:ok, authorization} <- AuthorizationValue.parse(value, @protocol_version) do
      socket = assign(socket, fetch_error: nil, fetch_pending: true)

      case FetchCredentials.deliver(
             socket.assigns.actor,
             socket.assigns.biot_id,
             source,
             authorization
           ) do
        :ok ->
          notice = "source-fetch credential delivered for #{source.url}."

          {:noreply,
           socket
           |> assign(fetch_pending: false, fetch_error: nil)
           |> notify_parent(notice)
           |> reload()}

        {:error, error} ->
          {:noreply, assign(socket, fetch_pending: false, fetch_error: error)}
      end
    else
      {:error, reason} ->
        {:noreply,
         assign(socket,
           fetch_pending: false,
           fetch_error: CommandError.invalid_input(%{value: [reason]})
         )}

      _not_owner ->
        {:noreply, assign(socket, fetch_pending: false, fetch_error: :not_requested)}
    end
  end

  defp reset_state(socket) do
    assign(socket,
      publication_state: :idle,
      access_state: :idle,
      secret_state: :idle,
      logs_state: :idle,
      publish_port: "",
      publish_error: nil,
      armed_unpublish: nil,
      publication_pending: false,
      share_email: "",
      share_kind: "shell",
      share_error: nil,
      access_action_error: nil,
      armed_revoke: nil,
      access_pending: false,
      secret_name: "",
      secret_error: nil,
      armed_secret: nil,
      secret_pending: false,
      fetch_error: nil,
      fetch_pending: false
    )
  end

  defp load_tab(socket, actor, biot_id, :publications) do
    assign(socket, :publication_state, result_state(Publications.discover(actor, biot_id)))
  end

  defp load_tab(socket, actor, biot_id, :access) do
    socket
    |> assign(:publication_state, result_state(Publications.discover(actor, biot_id)))
    |> assign(:access_state, result_state(AccessDisplayView.get(actor, biot_id)))
  end

  defp load_tab(socket, actor, biot_id, :secrets),
    do: start_secret_load(assign(socket, :secret_state, :loading), actor, biot_id)

  defp load_tab(socket, actor, biot_id, :logs),
    do: start_log_load(assign(socket, :logs_state, :loading), actor, biot_id)

  defp load_tab(socket, _actor, _biot_id, _tab), do: socket

  defp reload(socket),
    do: load_tab(socket, socket.assigns.actor, socket.assigns.biot_id, socket.assigns.tab)

  defp start_secret_load(socket, actor, biot_id) do
    if connected?(socket) do
      start_async(socket, {:load_secrets, biot_id}, fn -> Secrets.list(actor, biot_id) end)
    else
      socket
    end
  end

  defp start_log_load(socket, actor, biot_id) do
    if connected?(socket) do
      start_async(socket, {:load_logs, biot_id}, fn ->
        BiotDetailData.load_logs(actor, biot_id)
      end)
    else
      socket
    end
  end

  @impl true
  def handle_async({:load_secrets, biot_id}, {:ok, result}, socket) do
    if current_tab?(socket, biot_id, :secrets) do
      {:noreply, assign(socket, :secret_state, result_state(result))}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:load_secrets, biot_id}, {:exit, _reason}, socket) do
    if current_tab?(socket, biot_id, :secrets) do
      {:noreply, assign(socket, :secret_state, {:error, :temporarily_unavailable})}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:load_logs, biot_id}, {:ok, result}, socket) do
    if current_tab?(socket, biot_id, :logs) do
      {:noreply, assign(socket, :logs_state, logs_result_state(result))}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:load_logs, biot_id}, {:exit, _reason}, socket) do
    if current_tab?(socket, biot_id, :logs) do
      {:noreply, assign(socket, :logs_state, {:error, :temporarily_unavailable})}
    else
      {:noreply, socket}
    end
  end

  defp current_tab?(socket, biot_id, tab),
    do: socket.assigns.biot_id == biot_id and socket.assigns.tab == tab

  defp result_state({:ok, value}), do: {:loaded, value}
  defp result_state({:error, reason}), do: {:error, reason}

  defp logs_result_state({:ok, {incarnation, output, truncated}})
       when is_binary(output) and is_boolean(truncated),
       do: {:loaded, incarnation, output, truncated}

  defp logs_result_state({:error, reason}), do: {:error, reason}
  defp logs_result_state(_invalid), do: {:error, :temporarily_unavailable}

  defp loaded_publications({:loaded, publications}), do: publications
  defp loaded_publications(_state), do: []

  defp active_publication?({:loaded, publications}, value) do
    case Port.parse(value),
      do: (
        {:ok, port} -> Enum.any?(publications, &(&1.port == port))
        _ -> false
      )
  end

  defp active_publication?(_, _), do: false

  defp share_kind("shell", _state), do: {:ok, :shell}

  defp share_kind("view:" <> value, {:loaded, publications}) do
    with {:ok, port} <- Port.parse(value),
         true <- Enum.any?(publications, &(&1.port == port)) do
      {:ok, {:view, port}}
    else
      false -> {:error, :publication_not_active}
      {:error, reason} -> {:error, reason}
    end
  end

  defp share_kind(_, _), do: {:error, :publication_not_active}

  defp revoke_key(
         %{"kind" => kind, "principal-id" => principal_id, "port" => port},
         {:loaded, %AccessDisplayView{} = access}
       ) do
    with {:ok, _} <- PrincipalId.parse(principal_id),
         {:ok, grant_kind} <- revoke_kind(kind, port),
         true <- grant_exists?(access, grant_kind, principal_id) do
      {:ok, %{kind: kind, principal_id: principal_id, port: port}}
    else
      _invalid -> :error
    end
  end

  defp revoke_key(_, _), do: :error
  defp revoke_kind("shell", ""), do: {:ok, :shell}

  defp revoke_kind("view", value),
    do: with({:ok, port} <- Port.parse(value), do: {:ok, {:view, port}})

  defp revoke_kind(_, _), do: {:error, :invalid_format}

  defp grant_exists?(%AccessDisplayView{grants: grants}, grant_kind, principal_id),
    do: Enum.any?(grants, &(to_string(&1.principal.id) == principal_id and &1.kind == grant_kind))

  defp parse_secret(name, value) do
    with {:ok, secret_name} <- SecretName.parse(name),
         {:ok, secret_value} <- SecretValue.parse(value, @protocol_version),
         do: {:ok, secret_name, secret_value}
  end

  defp secret_present?({:loaded, secrets}, name),
    do: Enum.any?(secrets, &(to_string(&1.name) == name))

  defp secret_present?(_, _), do: false

  defp policy_notice(label, %{access_revision: revision, enforcement: enforcement}),
    do:
      "#{label} committed at access revision #{revision}; #{UserMessage.enforcement(enforcement)}."

  defp notify_parent(socket, notice) do
    send(self(), {:biot_tab_notice, socket.assigns.biot_id, notice})
    socket
  end
end
