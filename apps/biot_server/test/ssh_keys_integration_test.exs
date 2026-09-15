defmodule Biot.Server.SshKeysIntegrationTest do
  use Biot.Server.DataCase, async: false

  import Ecto.Query

  alias Biot.Protocol.{SshKeyId, SshPublicKey}
  alias Biot.Server.Actor
  alias Biot.Server.Authentication
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Principal, SshKey}
  alias Biot.Server.SshKeys
  alias Biot.Server.TestFixtures

  @ed25519 "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINzyzz1M9L5KLhn5k5Lh3Peq0ipDgKB4DPAJ0A7UqS06"
  @ed25519_fingerprint "SHA256:o+k9FYe1YagiLvND10oHPaNPV8ihNOOYkDDCUrx2vRo"

  @rsa "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDAH1kw9v8D14mV78lRG0k9ob9IedEQH/wydDgnPFnc5IFV4lQ6l6V8b006z9m1zIVEFUfG0k4kUdKwMIGXCJhkBNMHLFTI9myH8U4iXbKUfBs+KaMWNm9EZaY0CsJUEa6a83HsIOZbyzyGFy1sLUlet7XMtnKTzopAAd27wgyOWleJ+WubCdQAjJ7mAwYv+8IGXAxflPCh/cVb3dpW6Cae5rgx1/wyrZHEsAYTl2fpZmZAOzUE49GY2n6Wd+crw6pnVMXoucip0Z9h6tZsgNZD6w4vjltThEF5lkxKhy/KnKHJ0dMIBsw/tDf3BIM5GdnYoTEUVyUqwI5ta6nYR58D"
  @rsa_fingerprint "SHA256:C8ZKXymEzs85CpyNEVdPenVzGk/8pIAY3O1otofRcXo"

  defp parse!(line) do
    {:ok, key} = SshPublicKey.parse(line)
    key
  end

  defp actor(principal), do: TestFixtures.actor(principal)

  defp disable(principal) do
    Repo.update_all(from(p in Principal, where: p.id == ^principal.id), set: [status: :disabled])
  end

  defp unknown_id do
    {:ok, id} = SshKeyId.parse(Ecto.UUID.generate())
    id
  end

  describe "add/3" do
    test "stores the canonical line and the OpenSSH fingerprint" do
      principal = TestFixtures.principal(1)

      assert {:ok, view} = SshKeys.add(actor(principal), @ed25519 <> " user@host", "laptop")

      assert view.label == "laptop"
      assert view.fingerprint == @ed25519_fingerprint
      assert SshPublicKey.to_string(view.public_key) == @ed25519

      stored = Repo.get!(SshKey, view.id)
      assert stored.principal_id == principal.id
      assert stored.fingerprint == @ed25519_fingerprint
      assert SshPublicKey.to_string(stored.public_key) == @ed25519
    end

    test "stores an rsa line with its fingerprint" do
      principal = TestFixtures.principal(1)

      assert {:ok, view} = SshKeys.add(actor(principal), @rsa, "rsa")
      assert view.fingerprint == @rsa_fingerprint
    end

    test "rejects an invalid key line" do
      principal = TestFixtures.principal(1)

      for line <- ["", "not a key", @ed25519 <> "\n" <> @rsa, 42, nil] do
        assert SshKeys.add(actor(principal), line, "bad") ==
                 {:error, {:invalid_input, %{public_key: [:invalid_format]}}}
      end

      assert Repo.all(SshKey) == []
    end

    test "rejects a fingerprint already registered to anyone" do
      first = TestFixtures.principal(1)
      second = TestFixtures.principal(2)

      assert {:ok, _view} = SshKeys.add(actor(first), @ed25519, "first")

      assert SshKeys.add(actor(first), @ed25519, "again") ==
               {:error, {:invalid_input, %{public_key: [:already_registered]}}}

      assert SshKeys.add(actor(second), @ed25519 <> " other@host", "other") ==
               {:error, {:invalid_input, %{public_key: [:already_registered]}}}

      assert Repo.aggregate(SshKey, :count) == 1
    end

    test "validates the label byte length" do
      principal = TestFixtures.principal(1)

      assert {:ok, _view} = SshKeys.add(actor(principal), @ed25519, "a")
      assert {:ok, _view} = SshKeys.add(actor(principal), @rsa, String.duplicate("a", 100))

      for label <- ["", String.duplicate("a", 101), nil, 42] do
        assert SshKeys.add(actor(principal), @ed25519, label) ==
                 {:error, {:invalid_input, %{label: [:invalid_format]}}}
      end
    end

    test "rejects an absent or disabled actor" do
      principal = TestFixtures.principal(1)

      assert SshKeys.add(nil, @ed25519, "key") == {:error, :unauthenticated}

      disable(principal)
      assert SshKeys.add(actor(principal), @ed25519, "key") == {:error, :unauthenticated}
      assert Repo.all(SshKey) == []
    end
  end

  describe "authenticate/1" do
    test "returns an ssh_key proof for a registered key" do
      principal = TestFixtures.principal(1)
      {:ok, view} = SshKeys.add(actor(principal), @ed25519, "laptop")

      assert {:ok, %Authentication{actor: %Actor{principal_id: id}, proof: {:ssh_key, key_id}}} =
               SshKeys.authenticate(parse!(@ed25519))

      assert id == principal.id
      assert key_id == view.id
    end

    test "rejects an unregistered key" do
      TestFixtures.principal(1)
      assert SshKeys.authenticate(parse!(@ed25519)) == :error
    end

    test "rejects a key whose principal is disabled" do
      principal = TestFixtures.principal(1)
      {:ok, _view} = SshKeys.add(actor(principal), @ed25519, "laptop")
      disable(principal)

      assert SshKeys.authenticate(parse!(@ed25519)) == :error
    end
  end

  describe "list/1" do
    test "returns only the actor's keys" do
      owner = TestFixtures.principal(1)
      other = TestFixtures.principal(2)
      {:ok, view} = SshKeys.add(actor(owner), @ed25519, "mine")

      assert {:ok, [listed]} = SshKeys.list(actor(owner))
      assert listed.id == view.id
      assert SshKeys.list(actor(other)) == {:ok, []}
    end

    test "rejects an absent or disabled actor" do
      principal = TestFixtures.principal(1)

      assert SshKeys.list(nil) == {:error, :unauthenticated}

      disable(principal)
      assert SshKeys.list(actor(principal)) == {:error, :unauthenticated}
    end
  end

  describe "remove/2" do
    test "removes an owned key and stops its authentication" do
      principal = TestFixtures.principal(1)
      {:ok, view} = SshKeys.add(actor(principal), @ed25519, "laptop")

      assert SshKeys.remove(actor(principal), view.id) == :ok
      assert Repo.get(SshKey, view.id) == nil
      assert SshKeys.authenticate(parse!(@ed25519)) == :error
    end

    test "another principal's key is not found and unknown keys are not found" do
      owner = TestFixtures.principal(1)
      other = TestFixtures.principal(2)
      {:ok, view} = SshKeys.add(actor(owner), @ed25519, "mine")

      assert SshKeys.remove(actor(other), view.id) == {:error, :not_found}
      assert SshKeys.remove(actor(owner), unknown_id()) == {:error, :not_found}
      assert Repo.get(SshKey, view.id) != nil
    end

    test "rejects an absent or disabled actor" do
      principal = TestFixtures.principal(1)
      assert SshKeys.remove(nil, unknown_id()) == {:error, :unauthenticated}

      disable(principal)
      assert SshKeys.remove(actor(principal), unknown_id()) == {:error, :unauthenticated}
    end
  end
end
