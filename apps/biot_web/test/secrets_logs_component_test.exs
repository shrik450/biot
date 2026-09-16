defmodule BiotWeb.SecretsLogsComponentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Biot.Protocol.SecretName
  alias Biot.Server.Queries.SecretView
  alias Biot.Server.TestFixtures, as: ServerFixtures
  alias BiotWeb.Components.{BiotLogs, BiotSecrets}

  test "secrets panel lists names without exposing values and renders fetch credentials" do
    {:ok, name} = SecretName.parse("DATABASE_URL")
    source = ServerFixtures.repository()

    html =
      render_component(&BiotSecrets.secrets_panel/1,
        secret_state: {:loaded, [%SecretView{name: name}]},
        secret_name: "",
        fetch_source: source
      )

    assert html =~ "DATABASE_URL"
    assert html =~ "Names are visible; values are never listed."
    assert html =~ ~s(type="password")
    assert html =~ "source-fetch credential"
    assert html =~ "github.com/example/project.git"
    refute html =~ "super-secret-value"
  end

  test "logs panel renders bounded output and its truncation state" do
    incarnation = ServerFixtures.incarnation_id(1)

    html =
      render_component(&BiotLogs.logs_panel/1,
        logs_state: {:loaded, incarnation, "line one\nline two", true}
      )

    assert html =~ "line one"
    assert html =~ "line two"
    assert html =~ "output truncated"
    assert html =~ to_string(incarnation)
  end
end
