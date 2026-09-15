defmodule Biot.Server.Authentication.ValidityProofKeysTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Biot.Protocol.{BiotId, CredentialId, PrincipalId, SshKeyId, StreamId}
  alias Biot.Server.Actor
  alias Biot.Server.Authentication
  alias Biot.Server.Authentication.Validity
  alias Biot.Server.AuthenticationProof
  alias Biot.Server.TestFixtures
  alias Biot.Server.Tokens

  defp authentication(proof),
    do: %Authentication{actor: %Actor{principal_id: PrincipalId.generate()}, proof: proof}

  defp digest, do: elem(Tokens.mint(), 1)
  defp later, do: DateTime.add(DateTime.utc_now(), 3_600)

  test "a control proof is closed by its control session" do
    session = digest()
    proof = AuthenticationProof.control(session, later())

    assert Validity.proof_keys(authentication(proof)) == [{:control_session, session}]
  end

  test "a preview proof is closed by its preview session and by its parent control session" do
    # Logout closes the parent control session key, so a preview owner must hold it too.
    preview = digest()
    parent = digest()
    proof = AuthenticationProof.preview(preview, parent, TestFixtures.hostname(1), later())

    assert Enum.sort(Validity.proof_keys(authentication(proof))) ==
             Enum.sort([{:preview_session, preview}, {:control_session, parent}])
  end

  test "a credential proof is closed by its credential" do
    credential_id = CredentialId.generate()
    proof = AuthenticationProof.credential(credential_id, later())

    assert Validity.proof_keys(authentication(proof)) == [{:credential, credential_id}]
  end

  test "an SSH key proof is closed by its key" do
    key_id = SshKeyId.generate()

    assert Validity.proof_keys(authentication(AuthenticationProof.ssh_key(key_id))) ==
             [{:ssh_key, key_id}]
  end

  test "every key a proof yields is a proof key, and the Biot, principal, and admitted keys are not" do
    proofs = [
      AuthenticationProof.control(digest(), later()),
      AuthenticationProof.preview(digest(), digest(), TestFixtures.hostname(1), later()),
      AuthenticationProof.credential(CredentialId.generate(), later()),
      AuthenticationProof.ssh_key(SshKeyId.generate())
    ]

    for proof <- proofs, key <- Validity.proof_keys(authentication(proof)) do
      assert Validity.proof_key?(key), inspect(key)
    end

    refute Validity.proof_key?({:biot, BiotId.generate()})
    refute Validity.proof_key?({:principal, PrincipalId.generate()})
    refute Validity.proof_key?({:admitted, StreamId.generate()})
  end

  test "a proof key tag with a value of the wrong type is not a proof key" do
    refute Validity.proof_key?({:control_session, "raw-token"})
    refute Validity.proof_key?({:preview_session, CredentialId.generate()})
    refute Validity.proof_key?({:credential, digest()})
    refute Validity.proof_key?({:ssh_key, CredentialId.generate()})
  end
end
