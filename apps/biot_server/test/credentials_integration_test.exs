defmodule Biot.Server.CredentialsIntegrationTest do
  use Biot.Server.DataCase, async: false

  import Ecto.Query

  alias Biot.Protocol.{CredentialId, Hostname, SshKeyId}
  alias Biot.Server.Actor
  alias Biot.Server.Authentication
  alias Biot.Server.AuthenticationProof
  alias Biot.Server.Credentials
  alias Biot.Server.Credentials.Created
  alias Biot.Server.Queries.CredentialView
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Credential, Principal}
  alias Biot.Server.Sessions
  alias Biot.Server.TestFixtures
  alias Biot.Server.Tokens

  defp max_lifetime_ms, do: Application.fetch_env!(:biot_server, :credential_max_lifetime_ms)

  defp future, do: DateTime.add(DateTime.utc_now(), 24 * 60 * 60, :second)

  defp to_far, do: DateTime.add(DateTime.utc_now(), max_lifetime_ms() + 60_000, :millisecond)

  defp control(principal) do
    {:ok, token} = Sessions.start_control(principal.id)
    {:ok, authentication} = Sessions.control(token)
    {authentication, token}
  end

  defp digest do
    {_token, digest} = Tokens.mint()
    digest
  end

  defp hostname(value) do
    {:ok, hostname} = Hostname.parse(value)
    hostname
  end

  defp disable(principal) do
    Repo.update_all(from(p in Principal, where: p.id == ^principal.id), set: [status: :disabled])
  end

  describe "create/3" do
    test "requires a live control proof" do
      principal = TestFixtures.principal(1)
      other = TestFixtures.principal(2)
      {control, control_token} = control(principal)

      assert Credentials.create(nil, "cli", future()) == {:error, :unauthenticated}

      assert Credentials.create(
               %Authentication{
                 actor: control.actor,
                 proof:
                   AuthenticationProof.credential(
                     TestFixtures.id(CredentialId, 1),
                     future()
                   )
               },
               "cli",
               future()
             ) == {:error, :unauthenticated}

      assert Credentials.create(
               %Authentication{
                 actor: control.actor,
                 proof:
                   AuthenticationProof.preview(
                     digest(),
                     digest(),
                     hostname("preview-host"),
                     future()
                   )
               },
               "cli",
               future()
             ) == {:error, :unauthenticated}

      assert Credentials.create(
               %Authentication{
                 actor: control.actor,
                 proof: AuthenticationProof.ssh_key(TestFixtures.id(SshKeyId, 1))
               },
               "cli",
               future()
             ) == {:error, :unauthenticated}

      assert Credentials.create(
               %Authentication{
                 actor: control.actor,
                 proof: AuthenticationProof.control(digest(), future())
               },
               "cli",
               future()
             ) == {:error, :unauthenticated}

      assert Credentials.create(
               %Authentication{control | actor: %Actor{principal_id: other.id}},
               "cli",
               future()
             ) == {:error, :unauthenticated}

      assert Sessions.logout(control_token) == :ok

      assert Credentials.create(control, "cli", future()) == {:error, :unauthenticated}
    end

    test "a disabled principal cannot create even from a stale control proof" do
      principal = TestFixtures.principal(1)
      {control, _token} = control(principal)
      disable(principal)

      assert Credentials.create(control, "cli", future()) == {:error, :unauthenticated}
      assert Repo.all(Credential) == []
    end

    test "validates the label byte length" do
      principal = TestFixtures.principal(1)
      {control, _token} = control(principal)

      for label <- ["a", String.duplicate("a", 100)] do
        assert {:ok, %Created{}} = Credentials.create(control, label, future())
      end

      for label <- ["", String.duplicate("a", 101), nil, 42, :label] do
        assert Credentials.create(control, label, future()) ==
                 {:error, {:invalid_input, %{label: [:invalid_format]}}}
      end
    end

    test "validates the expiry is in the future and within the cap" do
      principal = TestFixtures.principal(1)
      {control, _token} = control(principal)
      now = DateTime.utc_now()

      for expires_at <- [now, DateTime.add(now, -1, :second)] do
        assert Credentials.create(control, "cli", expires_at) ==
                 {:error, {:invalid_input, %{expires_at: [:not_future]}}}
      end

      assert Credentials.create(control, "cli", to_far()) ==
               {:error, {:invalid_input, %{expires_at: [:too_far]}}}
    end

    test "stores only the digest and returns the clear token once" do
      principal = TestFixtures.principal(1)
      {control, _token} = control(principal)
      expires_at = future()

      assert {:ok, %Created{credential: view, token: token}} =
               Credentials.create(control, "laptop", expires_at)

      assert String.starts_with?(token, "biot_")
      assert view.label == "laptop"
      assert view.expires_at == expires_at
      assert view.last_used_at == nil

      stored = Repo.get!(Credential, view.id)
      assert stored.secret_digest == Tokens.digest(token)
      assert stored.principal_id == principal.id
      assert stored.expires_at == expires_at
      assert CredentialView.project(stored) == view
    end
  end

  describe "authenticate/1" do
    test "returns a credential proof for a live credential" do
      principal = TestFixtures.principal(1)
      {control, _token} = control(principal)

      {:ok, %Created{credential: view, token: token}} =
        Credentials.create(control, "api", future())

      assert {:ok,
              %Authentication{
                actor: %Actor{principal_id: id},
                proof: {:credential, credential_id, expires_at}
              }} =
               Credentials.authenticate(token)

      assert id == principal.id
      assert credential_id == view.id
      assert expires_at == view.expires_at
      assert Repo.get!(Credential, view.id).last_used_at != nil
    end

    test "rejects unknown, malformed, expired, revoked, and disabled-owner credentials" do
      principal = TestFixtures.principal(1)
      {control, _token} = control(principal)

      for token <- ["biot_unknown", ""] do
        assert Credentials.authenticate(token) == :error
      end

      {:ok, %Created{credential: expired, token: expired_token}} =
        Credentials.create(control, "expired", future())

      Repo.get!(Credential, expired.id)
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

      assert Credentials.authenticate(expired_token) == :error

      {:ok, %Created{credential: revoked, token: revoked_token}} =
        Credentials.create(control, "revoked", future())

      assert Credentials.revoke(%Actor{principal_id: principal.id}, revoked.id) == :ok
      assert Credentials.authenticate(revoked_token) == :error

      {:ok, %Created{token: disabled_token}} = Credentials.create(control, "disabled", future())
      disable(principal)
      assert Credentials.authenticate(disabled_token) == :error
    end

    test "records last_used_at coarsely" do
      principal = TestFixtures.principal(1)
      {control, _token} = control(principal)

      {:ok, %Created{credential: view, token: token}} =
        Credentials.create(control, "api", future())

      assert {:ok, _} = Credentials.authenticate(token)
      first = Repo.get!(Credential, view.id).last_used_at
      assert first != nil

      assert {:ok, _} = Credentials.authenticate(token)
      assert Repo.get!(Credential, view.id).last_used_at == first

      stale = DateTime.add(DateTime.utc_now(), -2 * 60 * 60, :second)

      Repo.update_all(from(c in Credential, where: c.id == ^view.id), set: [last_used_at: stale])

      assert {:ok, _} = Credentials.authenticate(token)
      second = Repo.get!(Credential, view.id).last_used_at
      assert DateTime.compare(second, stale) == :gt
    end
  end

  describe "list/1" do
    test "returns only the actor's credentials" do
      owner = TestFixtures.principal(1)
      other = TestFixtures.principal(2)
      {owner_control, _token} = control(owner)

      {:ok, %Created{credential: first}} = Credentials.create(owner_control, "first", future())
      {:ok, %Created{credential: second}} = Credentials.create(owner_control, "second", future())

      assert {:ok, views} = Credentials.list(%Actor{principal_id: owner.id})
      assert Enum.map(views, & &1.id) |> Enum.sort() == Enum.sort([first.id, second.id])

      assert Credentials.list(%Actor{principal_id: other.id}) == {:ok, []}
    end

    test "rejects an absent or disabled actor" do
      principal = TestFixtures.principal(1)

      assert Credentials.list(nil) == {:error, :unauthenticated}

      disable(principal)
      assert Credentials.list(%Actor{principal_id: principal.id}) == {:error, :unauthenticated}
    end
  end

  describe "revoke/2" do
    test "a credential of another principal is not found" do
      owner = TestFixtures.principal(1)
      other = TestFixtures.principal(2)
      {owner_control, _token} = control(owner)
      {:ok, %Created{credential: view}} = Credentials.create(owner_control, "mine", future())

      assert Credentials.revoke(%Actor{principal_id: other.id}, view.id) == {:error, :not_found}
      assert Repo.get(Credential, view.id) != nil
    end

    test "an unknown credential is not found" do
      principal = TestFixtures.principal(1)

      assert Credentials.revoke(%Actor{principal_id: principal.id}, unknown_id()) ==
               {:error, :not_found}
    end

    test "rejects an absent or disabled actor" do
      principal = TestFixtures.principal(1)
      assert Credentials.revoke(nil, unknown_id()) == {:error, :unauthenticated}

      disable(principal)

      assert Credentials.revoke(%Actor{principal_id: principal.id}, unknown_id()) ==
               {:error, :unauthenticated}
    end
  end

  defp unknown_id do
    {:ok, id} = CredentialId.parse(Ecto.UUID.generate())
    id
  end
end
