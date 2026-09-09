defmodule Biot.Server.Nodes.RegistrationLoaderTest do
  use ExUnit.Case, async: false

  alias Biot.Server.Nodes.RegistrationLoader

  @node_id "00000000-0000-4000-8000-000000000001"
  @registration_id "00000000-0000-4000-8000-000000000002"
  @peer_identity String.duplicate("a", 64)

  setup do
    registrations = Application.fetch_env(:biot_server, :node_registrations)
    registrations_file = Application.fetch_env(:biot_server, :node_registrations_file)

    on_exit(fn ->
      restore_env(:node_registrations, registrations)
      restore_env(:node_registrations_file, registrations_file)
    end)

    Application.delete_env(:biot_server, :node_registrations)
    :ok
  end

  @tag :tmp_dir
  test "loads valid JSON registrations", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "registrations.json")

    File.write!(
      path,
      Jason.encode!([
        %{
          "node_id" => @node_id,
          "registration_id" => @registration_id,
          "peer_identity" => @peer_identity,
          "max_biots" => 4,
          "status" => "enabled"
        }
      ])
    )

    Application.put_env(:biot_server, :node_registrations_file, path)

    assert {:ok, [registration]} = RegistrationLoader.load()
    assert registration.status == :enabled
    assert registration.max_biots == 4
  end

  @tag :tmp_dir
  test "returns distinct readable errors for file, JSON, and registration failures", %{
    tmp_dir: tmp_dir
  } do
    missing_path = Path.join(tmp_dir, "missing.json")
    Application.put_env(:biot_server, :node_registrations_file, missing_path)
    assert {:error, missing_error} = RegistrationLoader.load()

    invalid_json_path = Path.join(tmp_dir, "invalid-json.json")
    File.write!(invalid_json_path, "[")
    Application.put_env(:biot_server, :node_registrations_file, invalid_json_path)
    assert {:error, json_error} = RegistrationLoader.load()

    invalid_entry_path = Path.join(tmp_dir, "invalid-entry.json")
    File.write!(invalid_entry_path, Jason.encode!([%{"status" => "enabled"}]))
    Application.put_env(:biot_server, :node_registrations_file, invalid_entry_path)
    assert {:error, entry_error} = RegistrationLoader.load()

    errors = [missing_error, json_error, entry_error]
    messages = Enum.map(errors, &RegistrationLoader.message/1)

    assert length(Enum.uniq(errors)) == 3
    assert length(Enum.uniq(messages)) == 3
    assert Enum.all?(messages, &(is_binary(&1) and &1 != ""))
    assert Enum.at(messages, 0) =~ missing_path
    assert Enum.at(messages, 1) =~ "invalid JSON"
    assert Enum.at(messages, 2) =~ "node registration 0"
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:biot_server, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:biot_server, key)
end
