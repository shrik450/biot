defmodule Biot.Node.HostConfigTest do
  use ExUnit.Case, async: false

  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Paths
  alias Biot.Node.ReconcileFixtures

  @deep_data_root "/" <> String.duplicate("d", 199)

  test "the agent socket path is measured against the runtime root, not the data root" do
    # Only the two roots take part in deriving a socket path, so the rest of the settings stay out
    # of a test about which root it comes from.
    config = struct(Config, data_root: @deep_data_root, runtime_root: "/run/biot")

    socket = Paths.agent_socket(config, ReconcileFixtures.biot_id())

    assert String.starts_with?(socket, "/run/biot/")
    refute String.contains?(socket, @deep_data_root)

    assert byte_size(socket) <= Paths.agent_socket_path_limit(),
           "a data root #{byte_size(@deep_data_root)} bytes deep still has to leave the socket " <>
             "path inside the limit, because it no longer contributes to it"
  end

  test "refuses a runtime root whose agent socket path exceeds the Unix limit" do
    runtime_root = "/" <> String.duplicate("r", 199)
    expected_length = Paths.agent_socket_path_length(runtime_root)
    expected_limit = Paths.agent_socket_path_limit()
    expected_root_limit = Paths.max_agent_socket_runtime_root_length()

    assert byte_size(runtime_root) == 200
    assert expected_length == 248
    assert expected_limit == 107
    assert expected_root_limit == 59

    previous_data_root = Application.get_env(:biot_node, :data_root)
    previous_runtime_root = Application.get_env(:biot_node, :runtime_root)
    Application.put_env(:biot_node, :data_root, @deep_data_root)
    Application.put_env(:biot_node, :runtime_root, runtime_root)

    try do
      assert {:error, {:invalid_config, message}} = Config.load()
      assert message =~ inspect(runtime_root)
      assert message =~ "#{expected_length}-byte"
      assert message =~ "#{expected_limit} bytes"
      assert message =~ "#{expected_root_limit} bytes"

      assert message =~ "BIOT_NODE_RUNTIME_ROOT",
             "the message has to name the setting an operator can shorten"
    after
      :persistent_term.erase(Config)
      restore(:data_root, previous_data_root)
      restore(:runtime_root, previous_runtime_root)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:biot_node, key)
  defp restore(key, value), do: Application.put_env(:biot_node, key, value)
end
