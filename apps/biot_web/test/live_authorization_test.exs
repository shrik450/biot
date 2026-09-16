defmodule BiotWeb.LiveAuthorizationTest do
  use BiotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Ecto.Query

  alias Biot.Server.Repo
  alias Biot.Server.Schema.Session
  alias Biot.Server.Sessions
  alias BiotWeb.TestFixtures

  test "unauthenticated deep links redirect to login with the return path" do
    assert {:error, {:redirect, %{to: "/login?return=%2Fbiots%2Fnew"}}} =
             live(build_conn(), "/biots/new")
  end

  test "an expired control session cannot connect a LiveView" do
    assert {:error, {:redirect, %{to: "/login?return=%2Fbiots"}}} =
             live(Plug.Test.init_test_session(build_conn(), %{"token" => "expired"}), "/biots")

    assert Sessions.control("expired") == :error
  end

  test "a valid periodic auth check keeps the LiveView alive" do
    previous = Application.get_env(:biot_server, :auth_check_interval_ms)
    Application.put_env(:biot_server, :auth_check_interval_ms, 20)
    on_exit(fn -> Application.put_env(:biot_server, :auth_check_interval_ms, previous) end)

    principal = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(principal, node, 1)
    {:ok, token} = Sessions.start_control(principal.id)

    {:ok, view, _html} =
      live(
        Plug.Test.init_test_session(build_conn(), %{"token" => token}),
        "/biots/#{biot.id}"
      )

    Process.sleep(80)
    assert is_pid(view.pid)
    assert render(view) =~ to_string(biot.name)
  end

  test "an expired proof is redirected by the periodic auth check" do
    previous = Application.get_env(:biot_server, :auth_check_interval_ms)
    Application.put_env(:biot_server, :auth_check_interval_ms, 20)
    on_exit(fn -> Application.put_env(:biot_server, :auth_check_interval_ms, previous) end)

    principal = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(principal, node, 1)
    {:ok, token} = Sessions.start_control(principal.id)

    {:ok, view, _html} =
      live(
        Plug.Test.init_test_session(build_conn(), %{"token" => token}),
        "/biots/#{biot.id}"
      )

    {:ok, authentication} = Sessions.control(token)
    {:control, digest, _expires_at} = authentication.proof

    Repo.update_all(
      from(session in Session, where: session.id_digest == ^digest),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert_redirect(view, "/login?return=%2Fbiots%2F#{biot.id}")
  end
end
