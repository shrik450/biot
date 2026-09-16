defmodule BiotWeb.Components.Publication do
  @moduledoc "Renders the authoritative publications panel."

  use BiotWeb, :html

  alias Biot.Protocol.Port
  alias BiotWeb.UserMessage

  attr :publication_state, :any, required: true
  attr :owner, :boolean, required: true
  attr :publish_port, :string, required: true
  attr :publish_error, :any, default: nil
  attr :armed_unpublish, :string, default: nil
  attr :pending, :boolean, default: false
  attr :enforcement, :any, required: true
  attr :access_revision, :integer, required: true
  attr :target, :any, default: nil

  @spec publication_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def publication_panel(assigns) do
    ~H"""
    <section class="surface publication-panel" aria-labelledby="publications-heading">
      <div class="section-heading">
        <div>
          <h2 id="publications-heading">active publications</h2>
          <p class="section-description">
            access revision {@access_revision} · {UserMessage.enforcement(@enforcement)}
          </p>
        </div>
      </div>

      <p :if={@owner} class="section-description">
        Unpublishing retains the stable hostname for later republishing and removes view grants for that port.
      </p>

      <div :if={@publication_state == :loading} class="loading-state" role="status">
        loading publications…
      </div>

      <div :if={match?({:error, _reason}, @publication_state)} class="error-state" role="alert">
        <p>publications could not be loaded.</p>
        <p class="muted">{UserMessage.error(@publication_state)}</p>
        <button
          class="button button-secondary"
          type="button"
          phx-click="refresh-detail"
          phx-target={@target}
        >try again</button>
      </div>

      <div :if={match?({:loaded, []}, @publication_state)} class="empty-state">
        <p>no active publications.</p>
        <p class="muted">
          {if @owner,
            do: "Publish a port when its service is ready.",
            else: "No publication is visible to this role."}
        </p>
      </div>

      <div :if={match?({:loaded, [_ | _]}, @publication_state)} class="table-wrap">
        <table class="data-table publication-table">
          <caption class="sr-only">Active publications</caption>
          <thead>
            <tr>
              <th scope="col">port</th>
              <th scope="col">HTTPS URL</th>
              <th :if={@owner} scope="col"><span class="sr-only">actions</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={publication <- loaded_publications(@publication_state)}>
              <th scope="row">:{Port.to_string(publication.port)}</th>
              <td>
                <a href={publication.url} target="_blank" rel="noreferrer">
                  <span class="breakable">{publication.url}</span>
                  <span class="new-tab-indicator">(new tab)</span>
                </a>
              </td>
              <td :if={@owner} class="row-action">
                <button
                  :if={@armed_unpublish != Port.to_string(publication.port)}
                  class="button button-danger"
                  type="button"
                  phx-click="arm-unpublish"
                  phx-target={@target}
                  phx-value-port={Port.to_string(publication.port)}
                >unpublish</button>
                <span
                  :if={@armed_unpublish == Port.to_string(publication.port)}
                  class="confirm-action"
                >
                  <span>remove :{Port.to_string(publication.port)}?</span>
                  <button
                    class="button button-danger"
                    type="button"
                    phx-click="unpublish"
                    phx-target={@target}
                    phx-value-port={Port.to_string(publication.port)}
                    disabled={@pending}
                    phx-disable-with="unpublishing…"
                  >confirm</button>
                  <button
                    class="text-button"
                    type="button"
                    phx-click="cancel-unpublish"
                    phx-target={@target}
                  >cancel</button>
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <form
        :if={@owner}
        id="publication-form"
        class="inline-form publication-form"
        phx-submit="publish"
        phx-target={@target}
        phx-hook="FormBehavior"
      >
        <div class="form-field">
          <label for="publish-port">publish port</label>
          <input
            id="publish-port"
            name="port"
            type="number"
            min="1"
            max="65535"
            inputmode="numeric"
            value={@publish_port}
            autocomplete="off"
            required
            placeholder="3000…"
          />
          <p
            :for={error <- UserMessage.field_errors(@publish_error, :port)}
            class="field-error"
            role="alert"
          >
            {UserMessage.field_error(:port, error)}
          </p>
        </div>
        <button
          class="button button-secondary"
          type="submit"
          disabled={@pending}
          phx-disable-with="publishing…"
        >
          publish
        </button>
      </form>
      <p :if={@publish_error} class="form-error" role="alert">{UserMessage.error(@publish_error)}</p>
    </section>
    """
  end

  defp loaded_publications({:loaded, publications}), do: publications
end
