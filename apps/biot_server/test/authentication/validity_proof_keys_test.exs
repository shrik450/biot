defmodule Biot.Server.Authentication.ValidityProofKeysTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Biot.Protocol.{BiotId, CredentialId, PrincipalId, SshKeyId, StreamId}
  alias Biot.Server.Actor
  alias Biot.Server.Authentication
  alias Biot.Server.Authentication.Validity
  alias Biot.Server.AuthenticationProof
  alias Biot.Server.Id
  alias Biot.Server.TestFixtures
  alias Biot.Server.Tokens

  defp authentication(proof),
    do: %Authentication{actor: %Actor{principal_id: Id.generate(PrincipalId)}, proof: proof}

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
    credential_id = Id.generate(CredentialId)
    proof = AuthenticationProof.credential(credential_id, later())

    assert Validity.proof_keys(authentication(proof)) == [{:credential, credential_id}]
  end

  test "an SSH key proof is closed by its key" do
    key_id = Id.generate(SshKeyId)

    assert Validity.proof_keys(authentication(AuthenticationProof.ssh_key(key_id))) ==
             [{:ssh_key, key_id}]
  end

  test "every key a proof yields is a proof key, and the Biot, principal, and admitted keys are not" do
    proofs = [
      AuthenticationProof.control(digest(), later()),
      AuthenticationProof.preview(digest(), digest(), TestFixtures.hostname(1), later()),
      AuthenticationProof.credential(Id.generate(CredentialId), later()),
      AuthenticationProof.ssh_key(Id.generate(SshKeyId))
    ]

    for proof <- proofs, key <- Validity.proof_keys(authentication(proof)) do
      assert Validity.proof_key?(key), inspect(key)
    end

    refute Validity.proof_key?({:biot, Id.generate(BiotId)})
    refute Validity.proof_key?({:principal, Id.generate(PrincipalId)})
    refute Validity.proof_key?({:admitted, Id.generate(StreamId)})
  end

  test "a proof key tag with a value of the wrong type is not a proof key" do
    refute Validity.proof_key?({:control_session, "raw-token"})
    refute Validity.proof_key?({:preview_session, Id.generate(CredentialId)})
    refute Validity.proof_key?({:credential, digest()})
    refute Validity.proof_key?({:ssh_key, Id.generate(CredentialId)})
  end
end
