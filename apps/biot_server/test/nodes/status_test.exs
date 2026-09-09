defmodule Biot.Server.Nodes.StatusTest do
  use ExUnit.Case, async: true

  alias Biot.Server.Nodes.Status
  alias Biot.Server.Schema.Node

  test "every status function defines the complete status table" do
    table = %{
      enabled: %{
        terminal?: false,
        serves_access?: true,
        written_off?: false,
        connection: :ok,
        new_biots: :ok,
        lifecycle: :ok
      },
      disabled: %{
        terminal?: false,
        serves_access?: false,
        written_off?: false,
        connection: :ok,
        new_biots: {:error, :node_disabled},
        lifecycle: :ok
      },
      retired: %{
        terminal?: true,
        serves_access?: false,
        written_off?: false,
        connection: {:error, :registration_retired},
        new_biots: {:error, :node_disabled},
        lifecycle: :ok
      },
      abandoned: %{
        terminal?: true,
        serves_access?: false,
        written_off?: true,
        connection: {:error, :registration_abandoned},
        new_biots: {:error, :node_abandoned},
        lifecycle: {:error, :node_abandoned}
      }
    }

    assert MapSet.new(Map.keys(table)) == MapSet.new(Ecto.Enum.values(Node, :status))

    for {status, expected} <- table do
      assert Status.terminal?(status) == expected.terminal?
      assert Status.serves_access?(status) == expected.serves_access?
      assert Status.written_off?(status) == expected.written_off?
      assert Status.accepts_connection(status) == expected.connection
      assert Status.accepts_new_biots(status) == expected.new_biots
      assert Status.accepts_lifecycle_change(status) == expected.lifecycle
    end
  end
end
