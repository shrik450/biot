defmodule BiotWeb.Live.AccountLive do
  @moduledoc "The authenticated account and bearer credential page."

  use BiotWeb, :live_view

  import Phoenix.Controller, only: [get_csrf_token: 0]
  import BiotWeb.Components.AppShell

  alias Biot.Protocol.{CredentialId, SshKeyId}
  alias Biot.Server.CommandError
  alias Biot.Server.Credentials
  alias Biot.Server.Principals
  alias Biot.Server.Queries.Deployment
  alias Biot.Server.Queries.PrincipalView
  alias Biot.Server.Sessions
  alias Biot.Server.SshKeys
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
      |> assign(:current_section, :account)
      |> assign(:new_credential_token, nil)
      |> assign(:credential_notice_visible, false)
      |> assign(:credential_error, nil)
      |> assign(:armed_credential_id, nil)
      |> assign(:label, "")
      |> assign(:expires_at, "")
      |> assign(:principal_state, :loading)
      |> assign(:deployment_state, :loading)
      |> assign(:credentials_state, :loading)
      |> assign(:ssh_keys_state, :loading)
      |> assign(:ssh_key_label, "")
      |> assign(:ssh_key_line, "")
      |> assign(:ssh_key_error, nil)
      |> assign(:armed_ssh_key_id, nil)
      |> assign(:ssh_key_pending, false)
      |> load_account(actor)
      |> attach_hook(:biot_account_clear_token, :after_render, &clear_token/1)

    {:ok, socket}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("create-credential", %{"label" => label, "expires_at" => expires_at}, socket) do
    socket = assign(socket, label: label, expires_at: expires_at)

    with {:ok, parsed_expiry} <- parse_expiry(expires_at),
         {:ok, created} <-
           Credentials.create(socket.assigns.authentication, label, parsed_expiry) do
      credentials = [created.credential | credential_rows(socket.assigns.credentials_state)]

      {:noreply,
       socket
       |> assign(:credentials_state, {:loaded, credentials})
       |> assign(:new_credential_token, created.token)
       |> assign(:credential_notice_visible, true)
       |> assign(:credential_error, nil)
       |> assign(:label, "")
       |> assign(:expires_at, "")}
    else
      {:error, error} -> {:noreply, assign(socket, :credential_error, error)}
    end
  end

  def handle_event("dismiss-credential", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(:new_credential_token, nil)
       |> assign(:credential_notice_visible, false)}

  def handle_event("arm-revoke-credential", %{"id" => id}, socket) do
    {:noreply, assign(socket, :armed_credential_id, id)}
  end

  def handle_event("cancel-revoke-credential", _params, socket),
    do: {:noreply, assign(socket, :armed_credential_id, nil)}

  def handle_event("revoke-credential", %{"id" => id}, socket) do
    with {:ok, credential_id} <- CredentialId.parse(id),
         :ok <- Credentials.revoke(socket.assigns.actor, credential_id) do
      {:noreply,
       socket
       |> assign(
         :credentials_state,
         {:loaded,
          Enum.reject(
            credential_rows(socket.assigns.credentials_state),
            &(&1.id == credential_id)
          )}
       )
       |> assign(:armed_credential_id, nil)
       |> assign(:credential_error, nil)}
    else
      {:error, :invalid_format} ->
        {:noreply,
         assign(socket, :credential_error, CommandError.invalid_input(%{id: [:invalid_format]}))}

      {:error, error} ->
        {:noreply, assign(socket, :credential_error, error)}
    end
  end

  def handle_event("add-ssh-key", %{"label" => label, "public_key" => line}, socket) do
    socket = assign(socket, ssh_key_label: label, ssh_key_line: line, ssh_key_error: nil)

    socket = assign(socket, :ssh_key_pending, true)

    case SshKeys.add(socket.assigns.actor, line, label) do
      {:ok, key} ->
        keys = [key | ssh_key_rows(socket.assigns.ssh_keys_state)]

        {:noreply,
         socket
         |> assign(:ssh_keys_state, {:loaded, keys})
         |> assign(:ssh_key_label, "")
         |> assign(:ssh_key_line, "")
         |> assign(:ssh_key_error, nil)
         |> assign(:ssh_key_pending, false)}

      {:error, error} ->
        {:noreply, assign(socket, ssh_key_error: error, ssh_key_pending: false)}
    end
  end

  def handle_event("add-ssh-key", _params, socket), do: {:noreply, socket}

  def handle_event("arm-remove-ssh-key", %{"id" => id}, socket) do
    if ssh_key_present?(socket.assigns.ssh_keys_state, id),
      do: {:noreply, assign(socket, :armed_ssh_key_id, id)},
      else: {:noreply, socket}
  end

  def handle_event("cancel-remove-ssh-key", _params, socket),
    do: {:noreply, assign(socket, :armed_ssh_key_id, nil)}

  def handle_event("remove-ssh-key", %{"id" => id}, socket) do
    with true <- socket.assigns.armed_ssh_key_id == id,
         true <- ssh_key_present?(socket.assigns.ssh_keys_state, id),
         {:ok, key_id} <- SshKeyId.parse(id) do
      case SshKeys.remove(socket.assigns.actor, key_id) do
        :ok ->
          {:noreply,
           socket
           |> assign(
             :ssh_keys_state,
             {:loaded,
              Enum.reject(ssh_key_rows(socket.assigns.ssh_keys_state), &(&1.id == key_id))}
           )
           |> assign(:armed_ssh_key_id, nil)
           |> assign(:ssh_key_error, nil)}

        {:error, error} ->
          {:noreply,
           socket
           |> assign(:armed_ssh_key_id, nil)
           |> assign(:ssh_key_error, error)}
      end
    else
      {:error, :invalid_format} ->
        {:noreply,
         assign(socket, :ssh_key_error, CommandError.invalid_input(%{id: [:invalid_format]}))}

      _not_armed_or_present ->
        {:noreply, socket}
    end
  end

  def handle_event("remove-ssh-key", _params, socket), do: {:noreply, socket}

  def handle_event("set-theme", %{"theme" => theme}, socket)
      when theme in ["dark", "light", "system"] do
    {:noreply, push_event(socket, "biot-theme", %{theme: theme})}
  end

  def handle_event("set-theme", _params, socket), do: {:noreply, socket}

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :credential_summary,
        UserMessage.summary(assigns.credential_error, [:label, :expires_at])
      )
      |> assign(
        :ssh_key_summary,
        UserMessage.summary(assigns.ssh_key_error, [:label, :public_key])
      )
      |> assign(:deployment_loaded?, match?({:loaded, _deployment}, assigns.deployment_state))
      |> assign(:host_keys, deployment_host_keys(assigns.deployment_state))
      |> assign(:ssh_endpoint, ssh_endpoint(assigns.deployment_state))

    ~H"""
    <.app_shell
      current_section={@current_section}
      biot_count={@biot_count}
      node_count={@node_count}
    >
      <div class="page-header">
        <div>
          <p class="eyebrow">account</p>
          <h1>account</h1>
          <p class="page-lede">Your control-session identity and credentials.</p>
        </div>
      </div>

      <section class="surface account-session" aria-labelledby="session-heading">
        <div class="section-heading">
          <div>
            <h2 id="session-heading">session</h2>
            <p class="section-description">The identity attached to this control session.</p>
          </div>
          <form class="session-logout" action={~p"/logout"} method="post">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button class="button button-secondary" type="submit">log out</button>
          </form>
        </div>
        <div :if={match?({:loaded, _principal}, @principal_state)}>
          <dl class="definition-list">
            <div>
              <dt>name</dt>
              <dd>{display(loaded_principal(@principal_state).name)}</dd>
            </div>
            <div>
              <dt>email</dt>
              <dd>{display(loaded_principal(@principal_state).email)}</dd>
            </div>
            <div>
              <dt>principal id</dt>
              <dd class="breakable">{to_string(loaded_principal(@principal_state).id)}</dd>
            </div>
          </dl>
        </div>
        <div :if={match?({:error, _reason}, @principal_state)} class="error-state" role="alert">
          <p>principal details could not be loaded.</p>
          <p class="muted">{UserMessage.error(@principal_state)}</p>
          <p class="muted">Reload this page to try again.</p>
          <p class="breakable muted">principal id: {to_string(@actor.principal_id)}</p>
        </div>
        <p class="session-expiry">
          control session · expires <.timestamp id="session-expires-at" value={@session_expires_at} />
        </p>
      </section>

      <section class="surface" aria-labelledby="appearance-heading">
        <div class="section-heading">
          <div>
            <h2 id="appearance-heading">appearance</h2>
            <p class="section-description">Stored only in this browser.</p>
          </div>
        </div>
        <div
          id="appearance-controls"
          class="choice-row appearance-controls"
          role="group"
          aria-label="appearance"
          phx-hook="AppearanceControls"
        >
          <button
            type="button"
            class="button button-secondary"
            phx-click="set-theme"
            phx-value-theme="dark"
            data-theme-choice="dark"
            aria-pressed="false"
          >
            dark
          </button>
          <button
            type="button"
            class="button button-secondary"
            phx-click="set-theme"
            phx-value-theme="light"
            data-theme-choice="light"
            aria-pressed="false"
          >
            light
          </button>
          <button
            type="button"
            class="button button-secondary"
            phx-click="set-theme"
            phx-value-theme="system"
            data-theme-choice="system"
            aria-pressed="false"
          >
            system
          </button>
        </div>
      </section>

      <section class="surface" aria-labelledby="credentials-heading">
        <div class="section-heading">
          <div>
            <h2 id="credentials-heading">bearer credentials</h2>
            <p class="section-description">
              Credentials are shown once and cannot mint another credential.
            </p>
          </div>
        </div>

        <div
          :if={@new_credential_token && @credential_notice_visible}
          id="new-credential-notice"
          class="credential-notice"
          phx-hook="CredentialNotice"
          role="alert"
          aria-live="polite"
        >
          <strong>copy this token now</strong>
          <p>This is the only time biot will show the clear credential.</p>
          <code id="new-credential-value" class="secret-value" translate="no">{@new_credential_token}</code>
          <button
            id="copy-credential"
            type="button"
            class="button button-secondary"
            phx-hook="CopyCredential"
            data-copy-target="#new-credential-value"
            aria-live="polite"
          >copy token</button>
          <button type="button" class="button button-secondary" phx-click="dismiss-credential">dismiss</button>
        </div>

        <p :if={@credential_summary} class="form-error" role="alert">
          {@credential_summary}
        </p>

        <form
          id="credential-form"
          class="credential-form"
          phx-submit="create-credential"
          phx-hook="FormBehavior"
        >
          <div class="form-field">
            <label for="credential-label">label</label>
            <input
              id="credential-label"
              name="label"
              type="text"
              value={@label}
              required
              autocomplete="off"
            />
            <p
              :for={error <- UserMessage.field_errors(@credential_error, :label)}
              class="field-error"
              role="alert"
            >
              {UserMessage.field_error(:label, error)}
            </p>
          </div>
          <div class="form-field">
            <label for="credential-expires-at">expires at <span class="field-hint">utc</span></label>
            <input
              id="credential-expires-at"
              name="expires_at"
              type="datetime-local"
              value={@expires_at}
              required
              autocomplete="off"
            />
            <p
              :for={error <- UserMessage.field_errors(@credential_error, :expires_at)}
              class="field-error"
              role="alert"
            >
              {UserMessage.field_error(:expires_at, error)}
            </p>
          </div>
          <button class="button button-primary" type="submit">create token</button>
        </form>

        <div :if={match?({:error, _reason}, @credentials_state)} class="error-state" role="alert">
          <p>bearer credentials could not be loaded.</p>
          <p class="muted">{UserMessage.error(@credentials_state)}</p>
          <p class="muted">Reload this page to try again.</p>
        </div>
        <div :if={match?({:loaded, []}, @credentials_state)} class="empty-state">
          <p>no bearer credentials yet.</p>
          <p class="muted">Create one to use the command-line client.</p>
        </div>
        <div :if={match?({:loaded, [_ | _]}, @credentials_state)} class="table-wrap">
          <table class="data-table">
            <caption class="sr-only">Bearer credentials</caption>
            <thead>
              <tr>
                <th scope="col">label</th>
                <th scope="col">expires</th>
                <th scope="col">last used</th>
                <th scope="col"><span class="sr-only">actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={credential <- credential_rows(@credentials_state)}>
                <td class="breakable" translate="no">{credential.label}</td>
                <td>
                  <.timestamp
                    id={"credential-expires-#{to_string(credential.id)}"}
                    value={credential.expires_at}
                  />
                </td>
                <td>
                  <span :if={is_nil(credential.last_used_at)}>never</span>
                  <.timestamp
                    :if={credential.last_used_at}
                    id={"credential-last-used-#{to_string(credential.id)}"}
                    value={credential.last_used_at}
                  />
                </td>
                <td class="row-action">
                  <button
                    :if={@armed_credential_id != to_string(credential.id)}
                    type="button"
                    class="button button-danger"
                    phx-click="arm-revoke-credential"
                    phx-value-id={to_string(credential.id)}
                  >
                    revoke
                  </button>
                  <span :if={@armed_credential_id == to_string(credential.id)} class="confirm-action">
                    <span>revoke?</span>
                    <button
                      type="button"
                      class="button button-danger"
                      phx-click="revoke-credential"
                      phx-value-id={to_string(credential.id)}
                    >
                      confirm
                    </button>
                    <button type="button" class="text-button" phx-click="cancel-revoke-credential">cancel</button>
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="surface" aria-labelledby="keys-heading">
        <div class="section-heading">
          <div>
            <h2 id="keys-heading">ssh keys</h2>
            <p class="section-description">Registered public keys for shell access.</p>
          </div>
        </div>
        <p :if={@ssh_key_summary} class="form-error" role="alert">
          {@ssh_key_summary}
        </p>
        <form
          id="ssh-key-form"
          class="ssh-key-form"
          phx-submit="add-ssh-key"
          phx-hook="FormBehavior"
        >
          <div class="form-field">
            <label for="ssh-key-label">label</label>
            <input
              id="ssh-key-label"
              name="label"
              type="text"
              value={@ssh_key_label}
              autocomplete="off"
              required
              placeholder="work laptop…"
            />
            <p
              :for={error <- UserMessage.field_errors(@ssh_key_error, :label)}
              class="field-error"
              role="alert"
            >
              {UserMessage.field_error(:label, error)}
            </p>
          </div>
          <div class="form-field">
            <label for="ssh-key-public-key">public key</label>
            <textarea
              id="ssh-key-public-key"
              name="public_key"
              rows="3"
              autocomplete="off"
              spellcheck="false"
              required
              placeholder="ssh-ed25519 AAAA…"
            >{@ssh_key_line}</textarea>
            <p
              :for={error <- UserMessage.field_errors(@ssh_key_error, :public_key)}
              class="field-error"
              role="alert"
            >
              {UserMessage.field_error(:public_key, error)}
            </p>
          </div>
          <button
            class="button button-secondary"
            type="submit"
            disabled={@ssh_key_pending}
            phx-disable-with="adding…"
          >add key</button>
        </form>
        <div :if={match?({:error, _reason}, @ssh_keys_state)} class="error-state" role="alert">
          <p>ssh keys could not be loaded.</p>
          <p class="muted">{UserMessage.error(@ssh_keys_state)}</p>
          <p class="muted">Reload this page to try again.</p>
        </div>
        <div :if={match?({:loaded, []}, @ssh_keys_state)} class="empty-state">
          <p>no ssh keys registered.</p>
        </div>
        <div :if={match?({:loaded, [_ | _]}, @ssh_keys_state)} class="table-wrap">
          <table class="data-table">
            <caption class="sr-only">SSH keys</caption>
            <thead>
              <tr>
                <th scope="col">label</th>
                <th scope="col">public key</th>
                <th scope="col">fingerprint</th>
                <th scope="col"><span class="sr-only">actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={key <- ssh_key_rows(@ssh_keys_state)}>
                <td class="breakable" translate="no">{key.label}</td>
                <td class="breakable" translate="no">{to_string(key.public_key)}</td>
                <td class="breakable" translate="no">{key.fingerprint}</td>
                <td class="row-action">
                  <button
                    :if={@armed_ssh_key_id != to_string(key.id)}
                    type="button"
                    class="button button-danger"
                    phx-click="arm-remove-ssh-key"
                    phx-value-id={to_string(key.id)}
                  >remove</button>
                  <span :if={@armed_ssh_key_id == to_string(key.id)} class="confirm-action">
                    <span>remove key?</span>
                    <button
                      type="button"
                      class="button button-danger"
                      phx-click="remove-ssh-key"
                      phx-value-id={to_string(key.id)}
                      disabled={@ssh_key_pending}
                      phx-disable-with="removing…"
                    >confirm</button>
                    <button type="button" class="text-button" phx-click="cancel-remove-ssh-key">cancel</button>
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="surface" aria-labelledby="host-keys-heading">
        <div class="section-heading">
          <div>
            <h2 id="host-keys-heading">ssh host keys</h2>
            <p class="section-description">
              <code translate="no">biot ssh</code> checks these keys for you.
            </p>
          </div>
        </div>
        <div :if={match?({:error, _reason}, @deployment_state)} class="error-state" role="alert">
          <p>ssh host keys could not be loaded.</p>
          <p class="muted">{UserMessage.error(@deployment_state)}</p>
          <p class="muted">Reload this page to try again.</p>
        </div>
        <div :if={@deployment_loaded? and @host_keys == []} class="empty-state">
          <p>This server has no SSH host key configured.</p>
          <p class="muted">
            Plain <code translate="no">ssh</code> cannot be used until the server's SSH host keys
            are configured. <code translate="no">biot ssh</code> reports the same.
          </p>
        </div>
        <div :if={@host_keys != []}>
          <p class="section-description">
            To use plain <code translate="no">ssh</code>, connect to
            <code translate="no">{@ssh_endpoint}</code>
            as the Biot's ID and compare the <code translate="no">SHA256:</code>
            fingerprint your client prints on the first
            connection with one of these keys.
          </p>
          <div class="table-wrap">
            <table class="data-table">
              <caption class="sr-only">SSH host keys</caption>
              <thead>
                <tr>
                  <th scope="col">type</th>
                  <th scope="col">fingerprint</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={host_key <- @host_keys}>
                  <td class="breakable" translate="no">{host_key.type}</td>
                  <td class="breakable" translate="no">{host_key.fingerprint}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </.app_shell>
    """
  end

  defp load_account(socket, actor) do
    socket
    |> assign(:principal_state, load_principal(actor))
    |> assign(:deployment_state, load_deployment(actor))
    |> assign(:credentials_state, load_credentials(actor))
    |> assign(:ssh_keys_state, load_ssh_keys(actor))
    |> assign(:session_expires_at, Sessions.expires_at(socket.assigns.authentication))
  end

  defp load_principal(actor) do
    case Principals.get(actor) do
      {:ok, %PrincipalView{} = principal} -> {:loaded, principal}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_deployment(actor) do
    case Deployment.get(actor) do
      {:ok, deployment} -> {:loaded, deployment}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_credentials(actor) do
    case Credentials.list(actor) do
      {:ok, credentials} -> {:loaded, credentials}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_ssh_keys(actor) do
    case SshKeys.list(actor) do
      {:ok, ssh_keys} -> {:loaded, ssh_keys}
      {:error, reason} -> {:error, reason}
    end
  end

  defp loaded_principal({:loaded, principal}), do: principal
  defp credential_rows({:loaded, credentials}), do: credentials
  defp credential_rows(_state), do: []
  defp ssh_key_rows({:loaded, ssh_keys}), do: ssh_keys
  defp ssh_key_rows(_state), do: []
  defp deployment_host_keys({:loaded, deployment}), do: deployment.ssh_host_keys || []
  defp deployment_host_keys(_state), do: []

  defp ssh_endpoint({:loaded, deployment}), do: "#{deployment.ssh.host}:#{deployment.ssh.port}"
  defp ssh_endpoint(_state), do: nil

  defp ssh_key_present?(state, id) do
    Enum.any?(ssh_key_rows(state), &(to_string(&1.id) == id))
  end

  defp clear_token(socket), do: assign(socket, :new_credential_token, nil)

  defp parse_expiry(value) when is_binary(value) do
    with {:ok, iso8601} <- browser_expiry_iso8601(value),
         {:ok, datetime, 0} <- DateTime.from_iso8601(iso8601) do
      # credentials.expires_at is :utc_datetime_usec; Ecto refuses any other precision, so the
      # boundary must raise the parsed browser value to microsecond precision here.
      {:ok, DateTime.add(datetime, 0, :microsecond)}
    else
      _error -> CommandError.invalid_input(%{expires_at: [:invalid_format]})
    end
  end

  defp parse_expiry(_value), do: CommandError.invalid_input(%{expires_at: [:invalid_format]})

  # A datetime-local control sends minute precision, while ISO 8601 needs seconds before parsing.
  defp browser_expiry_iso8601(value) do
    case String.split(value, "T", parts: 2) do
      [date, time] ->
        case String.split(time, ":") do
          [hour, minute] -> {:ok, "#{date}T#{hour}:#{minute}:00Z"}
          [hour, minute, second] -> {:ok, "#{date}T#{hour}:#{minute}:#{second}Z"}
          _parts -> :error
        end

      _parts ->
        :error
    end
  end

  defp display(nil), do: "—"
  defp display(value), do: value

  attr :id, :string, required: true
  attr :value, :any, required: true

  defp timestamp(assigns) do
    ~H"""
    <time
      id={@id}
      datetime={DateTime.to_iso8601(@value)}
      title={DateTime.to_iso8601(@value)}
      phx-hook="LocalizedTime"
    >{DateTime.to_iso8601(@value)}</time>
    """
  end
end
