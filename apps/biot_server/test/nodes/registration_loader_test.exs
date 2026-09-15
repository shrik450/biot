defmodule Biot.Server.Nodes.RegistrationLoaderTest do
  use ExUnit.Case, async: false

  alias Biot.Server.Nodes.RegistrationLoader
  alias Biot.Server.TestFixtures

  @node_id "00000000-0000-4000-8000-000000000001"
  @registration_id "00000000-0000-4000-8000-000000000002"
  @peer_identity String.duplicate("a", 64)

  setup do
    previous = Application.fetch_env(:biot_server, :node_registrations_file)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:biot_server, :node_registrations_file, value)
        :error -> Application.delete_env(:biot_server, :node_registrations_file)
      end
    end)

    Application.delete_env(:biot_server, :node_registrations_file)
    :ok
  end

  test "an unset file enrolls nobody" do
    assert RegistrationLoader.load() == {:ok, []}
  end

  test "loads valid JSON registrations" do
    TestFixtures.put_registrations([registration()])

    assert {:ok, [registration]} = RegistrationLoader.load()
    assert registration.status == :enabled
    assert registration.max_biots == 4
  end

  test "an entry with atom-style values is not JSON and is rejected" do
    TestFixtures.put_registrations([%{registration() | "status" => "Enabled"}])
    assert RegistrationLoader.load() == {:error, {:entry, 0, {:status, :invalid_value}}}
  end

  @tag :tmp_dir
  test "returns distinct readable errors for file, JSON, list, and registration failures", %{
    tmp_dir: tmp_dir
  } do
    missing_path = Path.join(tmp_dir, "missing.json")
    Application.put_env(:biot_server, :node_registrations_file, missing_path)
    assert {:error, missing_error} = RegistrationLoader.load()

    invalid_json_path = Path.join(tmp_dir, "invalid-json.json")
    File.write!(invalid_json_path, "[")
    Application.put_env(:biot_server, :node_registrations_file, invalid_json_path)
    assert {:error, json_error} = RegistrationLoader.load()

    TestFixtures.put_registrations(%{"not" => "a list"})
    assert {:error, list_error} = RegistrationLoader.load()

    TestFixtures.put_registrations([%{"status" => "enabled"}])
    assert {:error, entry_error} = RegistrationLoader.load()

    errors = [missing_error, json_error, list_error, entry_error]
    messages = Enum.map(errors, &RegistrationLoader.message/1)

    assert length(Enum.uniq(messages)) == 4
    assert Enum.at(messages, 0) =~ missing_path
    assert Enum.at(messages, 1) =~ "invalid JSON"
    assert Enum.at(messages, 2) == "node registrations must be a list"
    assert Enum.at(messages, 3) =~ "entry 0 of node registrations"
  end

  defp registration do
    %{
      "node_id" => @node_id,
      "registration_id" => @registration_id,
      "peer_identity" => @peer_identity,
      "max_biots" => 4,
      "status" => "enabled"
    }
  end
end
