defmodule Biot.Server.Nodes.StartupTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Server.Nodes.Startup
  alias Biot.Server.TestFixtures

  setup do
    previous = Application.fetch_env(:biot_server, :node_registrations_file)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:biot_server, :node_registrations_file, value)
        :error -> Application.delete_env(:biot_server, :node_registrations_file)
      end
    end)

    :ok
  end

  @tag :tmp_dir
  test "the real startup child returns a readable error for a bad file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "invalid.json")
    File.write!(path, "[")
    Application.put_env(:biot_server, :node_registrations_file, path)

    assert {:error, {message, _child}} = start_supervised(Startup)
    assert is_binary(message)
    assert message =~ "node enrollment failed"
    assert message =~ "invalid JSON"
  end

  test "the real startup child ignores a valid configuration" do
    TestFixtures.put_registrations([TestFixtures.registration(1)])
    assert Startup.start_link([]) == :ignore
  end
end
