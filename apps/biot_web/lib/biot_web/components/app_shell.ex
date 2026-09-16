defmodule BiotWeb.Components.AppShell do
  @moduledoc "The shared authenticated application frame."

  use BiotWeb, :html

  attr :current_section, :atom, required: true
  attr :biot_count, :integer, default: nil
  attr :node_count, :integer, default: nil
  slot :inner_block, required: true

  @spec app_shell(map()) :: Phoenix.LiveView.Rendered.t()
  def app_shell(assigns) do
    ~H"""
    <a class="skip-link" href="#main-content">skip to content</a>
    <div class="app-frame">
      <aside class="app-sidebar" aria-label="primary navigation">
        <a class="brand" href={~p"/"} aria-label="biot home">
          <span class="brand-mark"><img src={~p"/favicon.svg"} alt="" width="22" height="22" /></span>
          <span>biot</span>
        </a>

        <nav class="primary-nav" aria-label="primary">
          <.nav_link
            href={~p"/biots"}
            section={:biots}
            current_section={@current_section}
            count={@biot_count}
          >
            biots
          </.nav_link>
          <.nav_link
            href={~p"/nodes"}
            section={:nodes}
            current_section={@current_section}
            count={@node_count}
          >
            nodes
          </.nav_link>
          <.nav_link href={~p"/account"} section={:account} current_section={@current_section}>
            account
          </.nav_link>
        </nav>

        <form class="logout-form" action={~p"/logout"} method="post">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <button class="nav-logout" type="submit">log out</button>
        </form>
      </aside>

      <header class="app-mobile-header">
        <a class="brand" href={~p"/"} aria-label="biot home">
          <span class="brand-mark"><img src={~p"/favicon.svg"} alt="" width="22" height="22" /></span>
          <span>biot</span>
        </a>
        <details class="mobile-navigation">
          <summary>menu</summary>
          <nav aria-label="primary">
            <.nav_link
              href={~p"/biots"}
              section={:biots}
              current_section={@current_section}
              count={@biot_count}
            >
              biots
            </.nav_link>
            <.nav_link
              href={~p"/nodes"}
              section={:nodes}
              current_section={@current_section}
              count={@node_count}
            >
              nodes
            </.nav_link>
            <.nav_link href={~p"/account"} section={:account} current_section={@current_section}>
              account
            </.nav_link>
          </nav>
          <form class="mobile-logout-form" action={~p"/logout"} method="post">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button class="nav-logout" type="submit">log out</button>
          </form>
        </details>
      </header>

      <main id="main-content" class="app-main">
        <div class="app-content">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>
    """
  end

  attr :href, :string, required: true
  attr :section, :atom, required: true
  attr :current_section, :atom, required: true
  attr :count, :integer, default: nil
  slot :inner_block, required: true

  @spec nav_link(map()) :: Phoenix.LiveView.Rendered.t()
  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={if @current_section == @section, do: "nav-link is-active", else: "nav-link"}
      aria-current={if @current_section == @section, do: "page", else: nil}
    >
      <span>{render_slot(@inner_block)}</span>
      <span :if={not is_nil(@count)} class="nav-count">{@count}</span>
    </.link>
    """
  end
end
