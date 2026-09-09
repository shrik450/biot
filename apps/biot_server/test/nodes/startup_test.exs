defmodule Biot.Server.Nodes.StartupTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Server.Nodes
  alias Biot.Server.Nodes.Startup
  alias Biot.Server.TestFixtures

  setup do
    registrations = Application.fetch_env(:biot_server, :node_registrations)

    on_exit(fn ->
      case registrations do
        {:ok, value} -> Application.put_env(:biot_server, :node_registrations, value)
        :error -> Application.delete_env(:biot_server, :node_registrations)
      end
    end)

    :ok
  end

  test "the real startup child returns a readable error for rejected configuration" do
    retired = TestFixtures.registration(1, status: :retired)
    assert {:ok, _nodes} = Nodes.enroll([retired])

    Application.put_env(:biot_server, :node_registrations, [%{retired | status: :enabled}])

    assert {:error, {message, _child}} = start_supervised(Startup)
    assert is_binary(message)
    assert message =~ "node enrollment failed"
    assert message =~ to_string(retired.node_id)
  end
end
