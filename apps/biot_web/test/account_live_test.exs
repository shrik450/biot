defmodule BiotWeb.AccountLiveTest do
  use BiotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Biot.Server.Credentials
  alias Biot.Server.Sessions
  alias BiotWeb.TestFixtures

  test "account renders the principal and supports one-time credential creation" do
    principal = TestFixtures.principal(1)
    {:ok, token} = Sessions.start_control(principal.id)
    {:ok, view, _html} = live(authenticated_conn(token), "/account")

    assert render(view) =~ "person-1@example.test"

    expiry = DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.to_iso8601()

    html =
      view
      |> form("#credential-form", %{label: "ci-token", expires_at: expiry})
      |> render_submit()

    assert html =~ "copy this token now"
    assert html =~ "This is the only time biot will show the clear credential."
    assert {:ok, credentials} = Credentials.list(TestFixtures.actor(principal))
    assert Enum.any?(credentials, &(&1.label == "ci-token"))
  end

  test "account rejects malformed expiry and preserves the field error" do
    principal = TestFixtures.principal(1)
    {:ok, token} = Sessions.start_control(principal.id)
    {:ok, view, _html} = live(authenticated_conn(token), "/account")

    html =
      render_submit(view, "create-credential", %{"label" => "bad", "expires_at" => "not-a-time"})

    assert html =~ "expiry has an invalid format"
    refute html =~ "copy this token now"
  end

  defp authenticated_conn(token),
    do: Plug.Test.init_test_session(build_conn(), %{"token" => token})
end
