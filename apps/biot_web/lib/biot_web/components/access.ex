defmodule BiotWeb.Components.Access do
  @moduledoc "Renders owner-only access grants and sharing controls."

  use BiotWeb, :html

  alias Biot.Protocol.Port
  alias Biot.Server.Queries.AccessDisplayView.Grant
  alias BiotWeb.UserMessage

  attr :access_state, :any, required: true
  attr :publications, :list, required: true
  attr :share_email, :string, required: true
  attr :share_kind, :string, required: true
  attr :share_error, :any, default: nil
  attr :action_error, :any, default: nil
  attr :armed_revoke, :any, default: nil
  attr :pending, :boolean, default: false
  attr :enforcement, :any, required: true
  attr :access_revision, :integer, required: true
  attr :target, :any, default: nil

  @spec access_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def access_panel(assigns) do
    assigns =
      assigns
      |> assign(:action_summary, UserMessage.summary(assigns.action_error, []))
      |> assign(:share_summary, UserMessage.summary(assigns.share_error, [:email, :kind]))

    ~H"""
    <section class="surface access-panel" aria-labelledby="access-heading">
      <div class="section-heading">
        <div>
          <h2 id="access-heading">access</h2>
          <p class="section-description">
            access revision {@access_revision} · {UserMessage.enforcement(@enforcement)}
          </p>
        </div>
      </div>

      <div :if={@access_state == :loading} class="loading-state" role="status">loading access…</div>

      <div :if={match?({:error, _reason}, @access_state)} class="error-state" role="alert">
        <p>access is unavailable for this role or state.</p>
        <p class="muted">{UserMessage.error(@access_state)}</p>
        <button
          class="button button-secondary"
          type="button"
          phx-click="refresh-detail"
          phx-target={@target}
        >try again</button>
      </div>

      <div :if={match?({:loaded, _access}, @access_state)}>
        <% {:loaded, access} = @access_state %>
        <div class="table-wrap">
          <table class="data-table access-table">
            <caption class="sr-only">Owner and explicit access grants</caption>
            <thead>
              <tr>
                <th scope="col">permission</th>
                <th scope="col">principal</th>
                <th scope="col"><span class="sr-only">actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr class="owner-row">
                <th scope="row">owner</th>
                <td><.principal identity={access.owner} /></td>
                <td class="muted">—</td>
              </tr>
              <tr :for={grant <- access.grants}>
                <th scope="row">{grant_label(grant.kind)}</th>
                <td><.principal identity={grant.principal} /></td>
                <td class="row-action">
                  <button
                    :if={!revoke_armed?(@armed_revoke, grant)}
                    class="button button-danger"
                    type="button"
                    phx-click="arm-revoke"
                    phx-target={@target}
                    phx-value-kind={kind_value(grant.kind)}
                    phx-value-principal-id={to_string(grant.principal.id)}
                    phx-value-port={port_value(grant.kind)}
                  >revoke</button>
                  <span :if={revoke_armed?(@armed_revoke, grant)} class="confirm-action">
                    <span>revoke this grant?</span>
                    <button
                      class="button button-danger"
                      type="button"
                      phx-click="revoke"
                      phx-target={@target}
                      phx-value-kind={kind_value(grant.kind)}
                      phx-value-principal-id={to_string(grant.principal.id)}
                      phx-value-port={port_value(grant.kind)}
                      disabled={@pending}
                      phx-disable-with="revoking…"
                    >confirm</button>
                    <button
                      class="text-button"
                      type="button"
                      phx-click="cancel-revoke"
                      phx-target={@target}
                    >cancel</button>
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={access.grants == []} class="empty-state compact-empty">
          <p>no explicit grants.</p>
          <p class="muted">Share shell or one active publication below.</p>
        </div>

        <p :if={@action_summary} class="form-error" role="alert">
          {@action_summary}
        </p>

        <form
          id="share-form"
          class="share-form"
          phx-submit="share"
          phx-target={@target}
          phx-hook="FormBehavior"
        >
          <div class="form-field">
            <label for="share-email">principal email</label>
            <input
              id="share-email"
              name="email"
              type="email"
              value={@share_email}
              autocomplete="email"
              spellcheck="false"
              required
              placeholder="person@example.com…"
            />
            <p
              :for={error <- UserMessage.field_errors(@share_error, :email)}
              class="field-error"
              role="alert"
            >
              {UserMessage.field_error(:email, error)}
            </p>
          </div>
          <div class="form-field">
            <label for="share-kind">grant</label>
            <select id="share-kind" name="kind">
              <option value="shell" selected={@share_kind == "shell"}>shell</option>
              <option
                :for={publication <- @publications}
                value={"view:#{Port.to_string(publication.port)}"}
                selected={@share_kind == "view:#{Port.to_string(publication.port)}"}
              >
                view :{Port.to_string(publication.port)}
              </option>
            </select>
            <p
              :for={error <- UserMessage.field_errors(@share_error, :kind)}
              class="field-error"
              role="alert"
            >
              {UserMessage.field_error(:kind, error)}
            </p>
          </div>
          <button
            class="button button-secondary"
            type="submit"
            disabled={@pending}
            phx-disable-with="sharing…"
          >
            share
          </button>
        </form>
        <p :if={@share_summary} class="form-error" role="alert">{@share_summary}</p>
      </div>
    </section>
    """
  end

  attr :identity, :any, required: true

  defp principal(assigns) do
    ~H"""
    <div class="principal-detail">
      <strong>{identity_label(@identity)}</strong>
      <span class="muted breakable">id {to_string(@identity.id)}</span>
      <span :if={@identity.email} class="muted breakable">email {@identity.email}</span>
      <span :if={@identity.name} class="muted breakable">name {@identity.name}</span>
    </div>
    """
  end

  defp identity_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp identity_label(%{email: email}) when is_binary(email) and email != "", do: email
  defp identity_label(%{id: id}), do: "principal " <> to_string(id)

  defp grant_label(:shell), do: "shell"
  defp grant_label({:view, %Port{} = port}), do: "view :" <> Port.to_string(port)

  defp kind_value(:shell), do: "shell"
  defp kind_value({:view, _port}), do: "view"

  defp port_value(:shell), do: ""
  defp port_value({:view, %Port{} = port}), do: Port.to_string(port)

  defp revoke_armed?(%{kind: kind, principal_id: principal_id, port: port}, %Grant{} = grant) do
    kind == kind_value(grant.kind) and
      principal_id == to_string(grant.principal.id) and port == port_value(grant.kind)
  end

  defp revoke_armed?(_armed, _grant), do: false
end
