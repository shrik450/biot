defmodule BiotWeb.BiotsLiveTest do
  use BiotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Biot.Server.Sessions
  alias BiotWeb.TestFixtures

  test "authenticated biot list renders the actor's biot" do
    principal = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(principal, node, 1)
    {:ok, token} = Sessions.start_control(principal.id)

    conn = Plug.Test.init_test_session(build_conn(), %{"token" => token})
    {:ok, view, _html} = live(conn, "/biots")
    html = render(view)

    assert html =~ to_string(biot.name)
    assert html =~ "owner"
  end
end
