defmodule BiotWeb.LandingLive do
  @moduledoc "The public landing point for the control host."

  use BiotWeb, :live_view

  alias Biot.Server.Sessions

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    case session["token"] do
      token when is_binary(token) ->
        case Sessions.control(token) do
          {:ok, _authentication} -> {:ok, redirect(socket, to: "/biots")}
          :error -> {:ok, socket}
        end

      _missing ->
        {:ok, socket}
    end
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <main class="landing-page">
      <section class="landing-tile" aria-labelledby="landing-heading">
        <span class="login-mark"><img src={~p"/favicon.svg"} alt="" width="68" height="68" /></span>
        <p class="eyebrow">control plane</p>
        <h1 id="landing-heading">biot</h1>
        <p>Secure development environments, close to the terminal.</p>
        <a class="button button-primary" href={~p"/login?return=/biots"}>sign in</a>
      </section>
    </main>
    """
  end
end
