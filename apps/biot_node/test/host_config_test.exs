defmodule Biot.Node.HostConfigTest do
  use ExUnit.Case, async: false

  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Paths

  test "refuses a data root whose agent socket path exceeds the Unix limit" do
    previous = Application.get_env(:biot_node, :data_root)
    data_root = "/" <> String.duplicate("d", 199)
    expected_length = Paths.agent_socket_path_length(data_root)
    expected_limit = Paths.agent_socket_path_limit()
    expected_root_limit = Paths.max_agent_socket_data_root_length()

    assert byte_size(data_root) == 200
    assert expected_length == 258
    assert expected_limit == 107
    assert expected_root_limit == 49

    Application.put_env(:biot_node, :data_root, data_root)

    try do
      assert {:error, {:invalid_config, message}} = Config.load()
      assert message =~ inspect(data_root)
      assert message =~ "#{expected_length}-byte"
      assert message =~ "#{expected_limit} bytes"
      assert message =~ "#{expected_root_limit} bytes"
    after
      :persistent_term.erase(Config)

      if previous do
        Application.put_env(:biot_node, :data_root, previous)
      else
        Application.delete_env(:biot_node, :data_root)
      end
    end
  end
end
