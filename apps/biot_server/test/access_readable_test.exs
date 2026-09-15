defmodule Biot.Server.AccessReadableTest do
  use Biot.Server.DataCase, async: false
  use ExUnitProperties

  alias Biot.Server.Access
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.Schema.Environment
  alias Biot.Server.Schema.Publication
  alias Biot.Server.Schema.ShellGrant
  alias Biot.Server.Schema.ViewGrant
  alias Biot.Server.TestFixtures

  @principal_count 4
  @biot_count 5
  @ports [4_000, 5_000]

  setup do
    principals = Enum.map(1..@principal_count, &TestFixtures.principal/1)
    node = TestFixtures.node(1)

    %{principals: principals, node: node, ports: Enum.map(@ports, &TestFixtures.port/1)}
  end

  property "readable finds exactly the biots an actor owns or holds a grant on", context do
    check all(layout <- layout(), max_runs: 60) do
      biots = seed(context, layout)

      for principal <- context.principals do
        actor = TestFixtures.actor(principal)

        expected =
          biots
          |> Enum.filter(&readable_by_oracle?(&1, principal, layout))
          |> Enum.map(& &1.id)
          |> MapSet.new()

        found =
          BiotRow
          |> Access.readable(actor)
          |> Repo.all()
          |> Enum.map(& &1.id)
          |> MapSet.new()

        assert found == expected,
               """
               principal: #{inspect(principal.id)}
               layout: #{inspect(layout)}
               missing: #{inspect(MapSet.difference(expected, found))}
               extra: #{inspect(MapSet.difference(found, expected))}
               """
      end

      clear()
    end
  end

  defp layout do
    gen all(
          owners <-
            StreamData.list_of(StreamData.integer(1..@principal_count),
              length: @biot_count
            ),
          shell <- StreamData.list_of(grant_pair(), max_length: @biot_count * 2),
          view <- StreamData.list_of(view_triple(), max_length: @biot_count * 2)
        ) do
      %{
        owners: owners,
        shell: Enum.uniq(shell),
        view: Enum.uniq(view)
      }
    end
  end

  defp grant_pair do
    StreamData.tuple(
      {StreamData.integer(1..@biot_count), StreamData.integer(1..@principal_count)}
    )
  end

  defp view_triple do
    StreamData.tuple(
      {StreamData.integer(1..@biot_count), StreamData.integer(1..@principal_count),
       StreamData.member_of(1..length(@ports))}
    )
  end

  defp seed(context, layout) do
    biots =
      layout.owners
      |> Enum.with_index(1)
      |> Enum.map(fn {owner_number, biot_number} ->
        owner = Enum.at(context.principals, owner_number - 1)
        {biot, _environment} = TestFixtures.biot(owner, context.node, biot_number)
        biot
      end)

    for {biot_number, principal_number, port_number} <- layout.view do
      biot = Enum.at(biots, biot_number - 1)
      port = Enum.at(context.ports, port_number - 1)

      Repo.insert!(
        %Publication{biot_id: biot.id, port: port, hostname: hostname(biot_number, port_number)},
        on_conflict: :nothing
      )

      Repo.insert!(%ViewGrant{
        biot_id: biot.id,
        port: port,
        principal_id: principal_id(context, principal_number)
      })
    end

    for {biot_number, principal_number} <- layout.shell do
      Repo.insert!(%ShellGrant{
        biot_id: Enum.at(biots, biot_number - 1).id,
        principal_id: principal_id(context, principal_number)
      })
    end

    biots
  end

  defp readable_by_oracle?(biot, principal, layout) do
    number = biot_number(biot)

    biot.owner_id == principal.id or
      Enum.any?(layout.shell, fn {biot_number, principal_number} ->
        biot_number == number and principal_number == principal_number_of(principal)
      end) or
      Enum.any?(layout.view, fn {biot_number, principal_number, _port} ->
        biot_number == number and principal_number == principal_number_of(principal)
      end)
  end

  defp biot_number(biot) do
    "biot-" <> number = to_string(biot.name)
    String.to_integer(number)
  end

  defp principal_number_of(principal) do
    "subject-" <> number = principal.subject
    String.to_integer(number)
  end

  defp principal_id(context, number), do: Enum.at(context.principals, number - 1).id

  defp hostname(biot_number, port_number),
    do: TestFixtures.hostname(biot_number * 10 + port_number)

  defp clear do
    Repo.delete_all(ViewGrant)
    Repo.delete_all(ShellGrant)
    Repo.delete_all(Publication)
    Repo.delete_all(Environment)
    Repo.delete_all(BiotRow)
  end
end
