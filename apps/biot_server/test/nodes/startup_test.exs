defmodule Biot.Server.Nodes.StartupTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Server.Nodes.Startup
  alias Biot.Server.TestFixtures

  setup do
    registrations = Application.fetch_env(:biot_server, :node_registrations)
    registrations_file = Application.fetch_env(:biot_server, :node_registrations_file)

    on_exit(fn ->
      restore_env(:node_registrations, registrations)
      restore_env(:node_registrations_file, registrations_file)
    end)

    :ok
  end

  @tag :tmp_dir
  test "the real startup child returns a readable error for a bad file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "invalid.json")
    File.write!(path, "[")
    on_exit(fn -> File.rm(path) end)
    Application.delete_env(:biot_server, :node_registrations)
    Application.put_env(:biot_server, :node_registrations_file, path)

    assert {:error, {message, _child}} = start_supervised(Startup)
    assert is_binary(message)
    assert message =~ "node enrollment failed"
    assert message =~ "invalid JSON"
  end

  test "the real startup child ignores a valid configuration" do
    Application.put_env(:biot_server, :node_registrations, [TestFixtures.registration(1)])
    assert Startup.start_link([]) == :ignore
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:biot_server, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:biot_server, key)
end
