defmodule BiotWeb.Components.BiotSecrets do
  @moduledoc "Renders owner-only runtime secrets and an active fetch-credential request."

  use BiotWeb, :html

  alias Biot.Protocol.RepositorySource
  alias BiotWeb.UserMessage

  attr :secret_state, :any, required: true
  attr :secret_name, :string, required: true
  attr :secret_error, :any, default: nil
  attr :armed_remove, :string, default: nil
  attr :pending, :boolean, default: false
  attr :fetch_source, :any, default: nil
  attr :fetch_error, :any, default: nil
  attr :fetch_pending, :boolean, default: false
  attr :target, :any, default: nil

  @spec secrets_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def secrets_panel(assigns) do
    assigns =
      assigns
      |> assign(:secret_summary, UserMessage.summary(assigns.secret_error, [:name, :value]))
      |> assign(:fetch_summary, UserMessage.summary(assigns.fetch_error, [:value]))

    ~H"""
    <div class="secrets-panels">
      <section class="surface" aria-labelledby="runtime-secrets-heading">
        <div class="section-heading">
          <div>
            <h2 id="runtime-secrets-heading">runtime secrets</h2>
            <p class="section-description">Names are visible; values are never listed.</p>
          </div>
        </div>

        <div :if={@secret_state == :loading} class="loading-state" role="status">
          loading runtime secret names…
        </div>
        <div :if={match?({:error, _reason}, @secret_state)} class="error-state" role="alert">
          <p>runtime secret names are unavailable.</p>
          <p class="muted">{UserMessage.error(@secret_state)}</p>
          <p class="muted">The assigned node may be offline. Try again when it is reachable.</p>
          <button
            class="button button-secondary"
            type="button"
            phx-click="refresh-secrets"
            phx-target={@target}
            phx-disable-with="loading…"
          >try again</button>
        </div>
        <div :if={match?({:loaded, []}, @secret_state)} class="empty-state">
          <p>no runtime secrets.</p>
          <p class="muted">Deliver a value below to add one.</p>
        </div>
        <div :if={match?({:loaded, [_ | _]}, @secret_state)} class="table-wrap">
          <table class="data-table secret-table">
            <caption class="sr-only">Runtime secret names</caption>
            <thead>
              <tr>
                <th scope="col">name</th>
                <th scope="col"><span class="sr-only">actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={secret <- secret_rows(@secret_state)}>
                <th scope="row" translate="no">{to_string(secret.name)}</th>
                <td class="row-action">
                  <button
                    :if={@armed_remove != to_string(secret.name)}
                    class="button button-danger"
                    type="button"
                    phx-click="arm-remove-secret"
                    phx-target={@target}
                    phx-value-name={to_string(secret.name)}
                  >remove</button>
                  <span :if={@armed_remove == to_string(secret.name)} class="confirm-action">
                    <span>remove {to_string(secret.name)}?</span>
                    <button
                      class="button button-danger"
                      type="button"
                      phx-click="remove-secret"
                      phx-target={@target}
                      phx-value-name={to_string(secret.name)}
                      disabled={@pending}
                      phx-disable-with="removing…"
                    >confirm</button>
                    <button
                      class="text-button"
                      type="button"
                      phx-click="cancel-remove-secret"
                      phx-target={@target}
                    >cancel</button>
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <form
          id="runtime-secret-form"
          class="secret-form"
          phx-submit="deliver-secret"
          phx-target={@target}
          phx-hook="FormBehavior"
          data-clear-sensitive="true"
        >
          <div class="form-field">
            <label for="runtime-secret-name">name</label>
            <input
              id="runtime-secret-name"
              name="name"
              type="text"
              value={@secret_name}
              autocomplete="off"
              spellcheck="false"
              required
              placeholder="DATABASE_URL…"
            />
            <p
              :for={error <- UserMessage.field_errors(@secret_error, :name)}
              class="field-error"
              role="alert"
            >
              {UserMessage.field_error(:name, error)}
            </p>
          </div>
          <div class="form-field">
            <label for="runtime-secret-value">value</label>
            <input
              id="runtime-secret-value"
              name="value"
              type="password"
              autocomplete="new-password"
              required
              placeholder="enter value…"
            />
            <p
              :for={error <- UserMessage.field_errors(@secret_error, :value)}
              class="field-error"
              role="alert"
            >
              {UserMessage.field_error(:value, error)}
            </p>
          </div>
          <button
            class="button button-secondary"
            type="submit"
            disabled={@pending}
            phx-disable-with="delivering…"
          >deliver / replace</button>
        </form>
        <p :if={@secret_summary} class="form-error" role="alert">{@secret_summary}</p>
      </section>

      <section :if={fetch_source(@fetch_source)} class="surface" aria-labelledby="fetch-heading">
        <div class="section-heading">
          <div>
            <h2 id="fetch-heading">source-fetch credential</h2>
            <p class="section-description">The node is waiting for authorization for this source.</p>
          </div>
        </div>
        <p class="fetch-source">
          source
          <code class="breakable" translate="no">{RepositorySource.to_string(@fetch_source)}</code>
        </p>
        <form
          id="fetch-credential-form"
          class="fetch-form"
          phx-submit="deliver-fetch-credential"
          phx-target={@target}
          phx-hook="FormBehavior"
          data-clear-sensitive="true"
        >
          <div class="form-field">
            <label for="fetch-credential-value">authorization value</label>
            <input
              id="fetch-credential-value"
              name="value"
              type="password"
              autocomplete="new-password"
              required
              placeholder="Bearer …"
            />
            <p
              :for={error <- UserMessage.field_errors(@fetch_error, :value)}
              class="field-error"
              role="alert"
            >
              {UserMessage.field_error(:value, error)}
            </p>
          </div>
          <button
            class="button button-secondary"
            type="submit"
            disabled={@fetch_pending}
            phx-disable-with="delivering…"
          >deliver for this source</button>
        </form>
        <p :if={@fetch_summary} class="form-error" role="alert">{@fetch_summary}</p>
      </section>
    </div>
    """
  end

  defp secret_rows({:loaded, secrets}), do: secrets

  defp fetch_source(%{__struct__: RepositorySource}), do: true
  defp fetch_source(_source), do: false
end
