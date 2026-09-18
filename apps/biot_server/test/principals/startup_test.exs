defmodule Biot.Server.Principals.StartupTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Server.Principals
  alias Biot.Server.Principals.Startup
  alias Biot.Server.Schema.Principal
  alias Biot.Server.TestFixtures

  setup do
    Application.delete_env(:biot_server, :disabled_principals_file)

    on_exit(fn ->
      Application.delete_env(:biot_server, :disabled_principals_file)
    end)

    :ok
  end

  test "an empty configuration succeeds and starts nothing" do
    TestFixtures.put_disabled_principals([])
    assert Startup.start_link([]) == :ignore
  end

  test "a non-list configuration fails boot with a readable message" do
    TestFixtures.put_disabled_principals(%{"issuer" => "a"})

    assert {:error, message} = Startup.start_link([])
    assert message == "principal configuration failed: disabled principals must be a list"
  end

  test "an invalid JSON file fails boot with a readable message" do
    path = BiotTest.Temp.directory("biot-startup") <> ".json"
    File.write!(path, "{not json")
    Application.put_env(:biot_server, :disabled_principals_file, path)

    assert {:error, "principal configuration failed: " <> _rest} = Startup.start_link([])
  end

  test "a valid configuration disables before the listener starts" do
    principal = TestFixtures.principal(1)

    TestFixtures.put_disabled_principals([
      %{"issuer" => principal.issuer, "subject" => principal.subject}
    ])

    assert Startup.start_link([]) == :ignore
    assert Repo.get!(Principal, principal.id).status == :disabled
    assert Principals.reload() == :ok
  end
end
