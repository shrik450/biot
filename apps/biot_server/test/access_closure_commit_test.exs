defmodule Biot.Server.AccessClosureCommitTest do
  @moduledoc false
  # These tests leave the sandbox, so every change commits for real and each probe reads on its
  # own connection. Under the shared sandbox all processes use one connection, so a close sent
  # inside the transaction would still find the change and the probe could not tell.
  use ExUnit.Case, async: false

  alias Biot.Protocol.SshPublicKey
  alias Biot.Server.Access
  alias Biot.Server.Access.Owners
  alias Biot.Server.AccessHarness
  alias Biot.Server.AccessHarness.Registered
  alias Biot.Server.Actor
  alias Biot.Server.Authentication.Validity
  alias Biot.Server.Biots
  alias Biot.Server.Credentials
  alias Biot.Server.Nodes
  alias Biot.Server.Nodes.Registration
  alias Biot.Server.Principals
  alias Biot.Server.Principals.DisabledIdentities.Identity
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Credential, SshKey}
  alias Biot.Server.Sessions
  alias Biot.Server.SshKeys
  alias Biot.Server.TestFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    previous_principals = Application.fetch_env(:biot_server, :disabled_principals_file)
    previous_registrations = Application.fetch_env(:biot_server, :node_registrations_file)
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      clean_database()
      Sandbox.mode(Repo, :manual)
      restore_env(:disabled_principals_file, previous_principals)
      restore_env(:node_registrations_file, previous_registrations)
    end)

    owner = TestFixtures.principal(1)
    collaborator = TestFixtures.principal(2)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    AccessHarness.shell_grant(biot, collaborator)
    {token, control} = AccessHarness.control(collaborator)

    %{
      owner: owner,
      collaborator: collaborator,
      node: node,
      biot: biot,
      token: token,
      control: control
    }
  end

  test "a policy withdrawal closes owners only after its transaction commits", context do
    assert_closes_after_commit(context, fn ->
      assert {:ok, _result} =
               Access.revoke_shell(
                 TestFixtures.actor(context.owner),
                 context.biot.id,
                 context.collaborator.id
               )
    end)
  end

  test "destroy closes owners only after its transaction commits", context do
    assert_closes_after_commit(context, fn ->
      assert {:ok, _result} = Biots.destroy(TestFixtures.actor(context.owner), context.biot.id)
    end)
  end

  test "a principal disable closes owners only after its transaction commits", context do
    TestFixtures.put_disabled_principals([
      %Identity{issuer: context.collaborator.issuer, subject: context.collaborator.subject}
    ])

    assert_closes_after_commit(context, fn -> assert :ok = Principals.reload() end)
  end

  test "a node disable closes owners only after its transaction commits", context do
    TestFixtures.put_registrations([
      %Registration{
        node_id: context.node.id,
        registration_id: context.node.registration,
        peer_identity: context.node.peer_identity,
        max_biots: context.node.max_biots,
        status: :disabled
      }
    ])

    assert_closes_after_commit(context, fn -> assert {:ok, _nodes} = Nodes.reload() end)
  end

  test "logout closes owners only after its delete commits", context do
    assert_closes_after_commit(context, fn -> assert :ok = Sessions.logout(context.token) end)
  end

  test "credential revocation closes owners only after its delete commits", context do
    {:ok, created} =
      Credentials.create(context.control, "commit", DateTime.add(DateTime.utc_now(), 3_600))

    {:ok, authentication} = Credentials.authenticate(created.token)
    {:credential, credential_id, _expires_at} = authentication.proof

    owner =
      Registered.start(context.biot.id, authentication, fn ->
        is_nil(Repo.get(Credential, credential_id))
      end)

    assert :ok = Credentials.revoke(collaborator_actor(context), credential_id)
    assert_receive {:closed, ^owner, true}
  end

  test "SSH key removal closes owners only after its delete commits", context do
    {public, _private} = :crypto.generate_key(:eddsa, :ed25519)
    blob = <<11::32, "ssh-ed25519", byte_size(public)::32, public::binary>>
    line = "ssh-ed25519 " <> Base.encode64(blob)
    {:ok, _view} = SshKeys.add(collaborator_actor(context), line, "commit")
    {:ok, public_key} = SshPublicKey.parse(line)
    {:ok, authentication} = SshKeys.authenticate(public_key)
    {:ssh_key, key_id} = authentication.proof

    owner =
      Registered.start(context.biot.id, authentication, fn -> is_nil(Repo.get(SshKey, key_id)) end)

    assert :ok = SshKeys.remove(collaborator_actor(context), key_id)
    assert_receive {:closed, ^owner, true}
  end

  @doc false
  def report_commit(_event, _measurements, %{query: query}, %{test: test, owner: owner}) do
    if self() == test and String.downcase(query) == "commit",
      do: send(test, {:committed, Process.info(owner, :messages)})
  end

  # An owner that reads the database after the close arrives cannot see the order. A commit that
  # follows the close by microseconds usually lands first. So this owner never reads its mailbox,
  # and a telemetry handler in the committing process records that mailbox at the commit.
  defp assert_closes_after_commit(context, change) do
    parent = self()

    owner =
      spawn_link(fn ->
        :ok =
          Owners.register(
            context.biot.id,
            context.collaborator.id,
            Validity.proof_keys(context.control)
          )

        send(parent, {:registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, ^owner}

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:biot, :server, :repo, :query],
        &__MODULE__.report_commit/4,
        %{test: parent, owner: owner}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    change.()
    assert_receive {:committed, {:messages, []}}
    assert {:messages, [{:biot_access, :close}]} = Process.info(owner, :messages)
  end

  defp collaborator_actor(context), do: %Actor{principal_id: context.collaborator.id}

  # The biots and environments tables reference each other, so foreign keys are off while the
  # tables empty. The pragma applies to one connection, so every statement runs on it.
  defp clean_database do
    Repo.checkout(fn ->
      %{rows: tables} =
        Repo.query!(
          "SELECT name FROM sqlite_master WHERE type = 'table' " <>
            "AND name NOT LIKE 'sqlite_%' AND name != 'schema_migrations'"
        )

      Repo.query!("PRAGMA foreign_keys = OFF")
      Enum.each(tables, fn [table] -> Repo.query!(~s(DELETE FROM "#{table}")) end)
      Repo.query!("PRAGMA foreign_keys = ON")
    end)
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:biot_server, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:biot_server, key)
end
