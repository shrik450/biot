defmodule BiotWeb.NewBiotLiveTest do
  use BiotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Biot.Server.Sessions
  alias BiotWeb.TestFixtures

  test "creation form preserves user input and exposes the unsaved-change hook" do
    principal = TestFixtures.principal(1)
    {:ok, token} = Sessions.start_control(principal.id)
    {:ok, view, _html} = live(authenticated_conn(token), "/biots/new")

    html = render(view)
    assert html =~ ~s(data-unsaved-changes="true")
    assert html =~ ~s(phx-hook="FormBehavior")

    html =
      view
      |> form("#new-biot-form", %{
        repository: "not a URL",
        name: "bad name!",
        base_source: "nixpkgs",
        base_ref: "",
        initial_state: "running"
      })
      |> render_submit()

    assert html =~ "repository has an invalid format"
    assert html =~ "name has an invalid format"
    assert html =~ ~s(value="not a URL")
    assert html =~ ~s(value="bad name!")
  end

  test "dynamic creation rows can be added and removed through LiveView events" do
    principal = TestFixtures.principal(1)
    {:ok, token} = Sessions.start_control(principal.id)
    {:ok, view, _html} = live(authenticated_conn(token), "/biots/new")

    html = render_click(view, "add-layer")
    assert html =~ "layer-source-1"

    html = render_click(view, "remove-layer", %{"id" => "1"})
    refute html =~ "layer-source-1"

    html = render_click(view, "add-runtime-secret")
    assert html =~ "secret-name-1"
    html = render_click(view, "add-source-credential")
    assert html =~ "credential-source-1"
  end

  defp authenticated_conn(token),
    do: Plug.Test.init_test_session(build_conn(), %{"token" => token})
end
