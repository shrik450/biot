defmodule Biot.Server.StreamPredicatesTest do
  @moduledoc false
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Actor
  alias Biot.Server.Authorization
  alias Biot.Server.Schema.Biot, as: BiotRow
  alias Biot.Server.TestFixtures

  # Every actor kind the predicates can receive: the Biot's owner, a principal that holds
  # grants, a principal that holds none, and no actor at all.
  @actor_kinds [:owner, :collaborator, :stranger, :missing]

  defp biot, do: %BiotRow{owner_id: principal_id(1)}
  defp principal_id(number), do: TestFixtures.id(PrincipalId, number)

  defp actor(:owner), do: %Actor{principal_id: principal_id(1)}
  defp actor(:collaborator), do: %Actor{principal_id: principal_id(2)}
  defp actor(:stranger), do: %Actor{principal_id: principal_id(3)}
  defp actor(:missing), do: nil

  defp port(number), do: TestFixtures.port(number)

  defp grant_sets do
    for shell <- [false, true],
        view_ports <- [[], [port(4_000)], [port(4_000), port(5_000)]],
        do: %{shell: shell, view_ports: view_ports}
  end

  describe "may_read?/3" do
    test "the owner reads with any grants" do
      for grants <- grant_sets() do
        assert Authorization.may_read?(actor(:owner), biot(), grants), inspect(grants)
      end
    end

    test "a collaborator reads exactly when it holds a shell grant or a view grant" do
      for %{shell: shell, view_ports: view_ports} = grants <- grant_sets() do
        expected = shell or view_ports != []

        assert Authorization.may_read?(actor(:collaborator), biot(), grants) == expected,
               inspect(grants)
      end
    end

    test "a stranger with no grants does not read" do
      refute Authorization.may_read?(actor(:stranger), biot(), %{shell: false, view_ports: []})
    end

    test "a missing actor never reads, even with grants" do
      for grants <- grant_sets() do
        refute Authorization.may_read?(nil, biot(), grants), inspect(grants)
      end
    end
  end

  describe "may_view?/4" do
    test "every actor kind against every port list, for a granted and an ungranted port" do
      requested = port(4_000)

      for kind <- @actor_kinds,
          view_ports <- [[], [requested], [port(5_000)], [port(5_000), requested]] do
        expected =
          case kind do
            :owner -> true
            :collaborator -> requested in view_ports
            # A stranger holds no grants, so any port list it is given is not its own.
            :stranger -> requested in view_ports
            :missing -> false
          end

        assert Authorization.may_view?(actor(kind), biot(), requested, view_ports) == expected,
               "#{kind} with #{inspect(view_ports)}"
      end
    end

    test "a collaborator's grant on one port does not let it view another port" do
      refute Authorization.may_view?(actor(:collaborator), biot(), port(5_000), [port(4_000)])
    end

    test "the owner of another Biot is only a collaborator here" do
      other_biot = %BiotRow{owner_id: principal_id(2)}
      refute Authorization.may_view?(actor(:owner), other_biot, port(4_000), [])
    end
  end

  describe "may_shell?/3" do
    test "every actor kind with and without a shell grant" do
      for kind <- @actor_kinds, shell_granted <- [false, true] do
        expected =
          case kind do
            :owner -> true
            kind when kind in [:collaborator, :stranger] -> shell_granted
            :missing -> false
          end

        assert Authorization.may_shell?(actor(kind), biot(), shell_granted) == expected,
               "#{kind} with shell_granted: #{shell_granted}"
      end
    end

    test "the owner of another Biot needs a shell grant here" do
      other_biot = %BiotRow{owner_id: principal_id(2)}
      refute Authorization.may_shell?(actor(:owner), other_biot, false)
      assert Authorization.may_shell?(actor(:owner), other_biot, true)
    end
  end

  describe "the three predicates agree" do
    property "anyone who may view a port or open a shell may also read the Biot" do
      check all(
              actor <- actor_generator(),
              owner_number <- integer(1..4),
              shell <- boolean(),
              view_ports <- view_ports_generator(),
              requested <- port_generator()
            ) do
        biot = %BiotRow{owner_id: principal_id(owner_number)}
        grants = %{shell: shell, view_ports: view_ports}

        if Authorization.may_view?(actor, biot, requested, view_ports),
          do: assert(Authorization.may_read?(actor, biot, grants))

        if Authorization.may_shell?(actor, biot, shell),
          do: assert(Authorization.may_read?(actor, biot, grants))
      end
    end

    property "a non-owner's authority is exactly its grants, and the owner's is total" do
      check all(
              actor <- actor_generator(),
              owner_number <- integer(1..4),
              shell <- boolean(),
              view_ports <- view_ports_generator(),
              requested <- port_generator()
            ) do
        biot = %BiotRow{owner_id: principal_id(owner_number)}

        case actor do
          nil ->
            refute Authorization.may_view?(actor, biot, requested, view_ports)
            refute Authorization.may_shell?(actor, biot, shell)

          %Actor{principal_id: principal_id} when principal_id == biot.owner_id ->
            assert Authorization.may_view?(actor, biot, requested, view_ports)
            assert Authorization.may_shell?(actor, biot, shell)

          %Actor{} ->
            assert Authorization.may_view?(actor, biot, requested, view_ports) ==
                     requested in view_ports

            assert Authorization.may_shell?(actor, biot, shell) == shell
        end
      end
    end
  end

  defp actor_generator do
    one_of([
      constant(nil),
      map(integer(1..4), &%Actor{principal_id: principal_id(&1)})
    ])
  end

  defp port_generator, do: map(member_of([4_000, 5_000, 8_080]), &port/1)

  defp view_ports_generator do
    map(list_of(member_of([4_000, 5_000, 8_080]), max_length: 3), fn numbers ->
      numbers |> Enum.uniq() |> Enum.map(&port/1)
    end)
  end
end
