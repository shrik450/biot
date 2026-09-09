defmodule Biot.Server.PrincipalsTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Server.Actor
  alias Biot.Server.Principals
  alias Biot.Server.Schema.Principal
  alias Biot.Server.TestFixtures

  test "identify reuses an identity and updates its last-seen claims" do
    assert {:ok, first} =
             Principals.identify("https://issuer.example", "subject", %{
               email: "old@example.test",
               name: "Old Name"
             })

    assert {:ok, second} =
             Principals.identify("https://issuer.example", "subject", %{
               email: "new@example.test",
               name: "New Name"
             })

    assert second.id == first.id
    assert second.last_seen_email == "new@example.test"
    assert second.last_seen_name == "New Name"
  end

  test "identify creates a new principal for a different subject" do
    assert {:ok, first} =
             Principals.identify("https://issuer.example", "first", %{email: nil, name: nil})

    assert {:ok, second} =
             Principals.identify("https://issuer.example", "second", %{email: nil, name: nil})

    refute second.id == first.id
  end

  test "the database rejects a duplicate issuer and subject" do
    first = TestFixtures.principal(1)

    duplicate = %Principal{
      id: TestFixtures.id(Biot.Protocol.PrincipalId, 2),
      issuer: first.issuer,
      subject: first.subject
    }

    assert_raise Ecto.ConstraintError, fn -> Repo.insert!(duplicate) end
  end

  test "resolve_email resolves a known email and rejects an unknown email" do
    principal = TestFixtures.principal(1)
    actor = %Actor{principal_id: principal.id}

    assert Principals.resolve_email(actor, principal.last_seen_email) == {:ok, principal.id}
    assert Principals.resolve_email(actor, "unknown@example.test") == {:error, :not_found}
  end
end
