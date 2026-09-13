defmodule Biot.Protocol.IdentityValuesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.{CredentialId, Digest, SameOriginPath, SshKeyId, SshPublicKey}

  @uuid "0f8fad5b-d9cb-469f-a165-70867728950e"

  @ed25519 "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINzyzz1M9L5KLhn5k5Lh3Peq0ipDgKB4DPAJ0A7UqS06"
  @ed25519_fingerprint "SHA256:o+k9FYe1YagiLvND10oHPaNPV8ihNOOYkDDCUrx2vRo"

  @rsa "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDAH1kw9v8D14mV78lRG0k9ob9IedEQH/wydDgnPFnc5IFV4lQ6l6V8b006z9m1zIVEFUfG0k4kUdKwMIGXCJhkBNMHLFTI9myH8U4iXbKUfBs+KaMWNm9EZaY0CsJUEa6a83HsIOZbyzyGFy1sLUlet7XMtnKTzopAAd27wgyOWleJ+WubCdQAjJ7mAwYv+8IGXAxflPCh/cVb3dpW6Cae5rgx1/wyrZHEsAYTl2fpZmZAOzUE49GY2n6Wd+crw6pnVMXoucip0Z9h6tZsgNZD6w4vjltThEF5lkxKhy/KnKHJ0dMIBsw/tDf3BIM5GdnYoTEUVyUqwI5ta6nYR58D"
  @rsa_fingerprint "SHA256:C8ZKXymEzs85CpyNEVdPenVzGk/8pIAY3O1otofRcXo"

  describe "CredentialId" do
    test "parses a canonical UUID and prints it back" do
      assert {:ok, %CredentialId{value: @uuid} = id} = CredentialId.parse(@uuid)
      assert to_string(id) == @uuid
      assert String.Chars.to_string(id) == @uuid
    end

    test "rejects anything that is not a canonical UUID" do
      for value <- [nil, 1, :atom, %{}, [], "", "not-a-uuid", String.upcase(@uuid)] do
        assert CredentialId.parse(value) == {:error, :invalid_format}
      end
    end

    test "rejects UUIDs without the version and variant nibbles" do
      assert CredentialId.parse("0f8fad5b-d9cb-869f-a165-70867728950e") ==
               {:error, :invalid_format}

      assert CredentialId.parse("0f8fad5b-d9cb-469f-0165-70867728950e") ==
               {:error, :invalid_format}
    end
  end

  describe "SshKeyId" do
    test "parses a canonical UUID and prints it back" do
      assert {:ok, %SshKeyId{value: @uuid} = id} = SshKeyId.parse(@uuid)
      assert to_string(id) == @uuid
    end

    test "rejects anything that is not a canonical UUID" do
      for value <- [nil, 1, :atom, %{}, [], "", "not-a-uuid", String.upcase(@uuid)] do
        assert SshKeyId.parse(value) == {:error, :invalid_format}
      end
    end
  end

  describe "SshPublicKey" do
    test "parses an ed25519 line and computes the OpenSSH fingerprint" do
      assert {:ok, key} = SshPublicKey.parse(@ed25519)
      assert SshPublicKey.to_string(key) == @ed25519
      assert SshPublicKey.fingerprint(key) == @ed25519_fingerprint
      assert to_string(key) == @ed25519
    end

    test "parses an rsa line and computes the OpenSSH fingerprint" do
      assert {:ok, key} = SshPublicKey.parse(@rsa)
      assert SshPublicKey.fingerprint(key) == @rsa_fingerprint
    end

    test "one word of comment is accepted and dropped from the stored line" do
      assert {:ok, key} = SshPublicKey.parse(@ed25519 <> " user@host")
      assert SshPublicKey.to_string(key) == @ed25519
    end

    test "rejects a mismatched algorithm token" do
      [_algorithm, blob | _rest] = String.split(@ed25519, " ")
      assert SshPublicKey.parse("ssh-rsa " <> blob) == {:error, :invalid_format}
    end

    test "rejects non-lines and non-binaries" do
      rejections = [
        nil,
        1,
        :ssh,
        %{},
        [],
        "",
        "not a key",
        @ed25519 <> "\n" <> @rsa,
        @ed25519 <> "\n"
      ]

      for value <- rejections do
        assert SshPublicKey.parse(value) == {:error, :invalid_format}
      end
    end

    test "accepts a comment containing spaces and keeps the ssh-keygen fingerprint" do
      assert {:ok, key} = SshPublicKey.parse(@ed25519 <> " work laptop")
      assert SshPublicKey.to_string(key) == @ed25519
      assert SshPublicKey.fingerprint(key) == @ed25519_fingerprint
    end
  end

  describe "SameOriginPath" do
    test "accepts absolute paths with an optional query" do
      for value <- ["/", "/a", "/a/b", "/a/b?x=1", "/a/b?x=1&y=2", "/__biot/callback?code=x"] do
        assert {:ok, %SameOriginPath{value: ^value} = path} = SameOriginPath.parse(value)
        assert to_string(path) == value
      end
    end

    test "rejects a scheme, a host, a fragment, whitespace, a backslash, and a double slash" do
      rejections = [
        nil,
        1,
        :path,
        %{},
        [],
        "",
        "relative",
        "http://example.test/path",
        "//example.test/path",
        "///path",
        "/path#fragment",
        "/path with space",
        "/path\t",
        "/path\n",
        "/path\\..\\admin",
        "https:///path"
      ]

      for value <- rejections do
        assert SameOriginPath.parse(value) == {:error, :invalid_format}
      end
    end

    test "a Unicode path is accepted" do
      assert {:ok, %SameOriginPath{value: "/héllo/世界"}} = SameOriginPath.parse("/héllo/世界")
    end
  end

  describe "Digest" do
    test "sha256 is the plain SHA-256 of the bytes" do
      assert Digest.to_string(Digest.sha256("abc")) ==
               Base.encode16(:crypto.hash(:sha256, "abc"), case: :lower)
    end

    test "compute namespaces the named encoding away from sha256" do
      refute Digest.sha256("abc") == Digest.compute(:creation_request_v1, "abc")
      assert Digest.to_string(Digest.compute(:creation_request_v1, "abc")) =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "parse rejects anything that is not 64 lowercase hex digits" do
      valid = Base.encode16(:crypto.hash(:sha256, "abc"), case: :lower)
      assert {:ok, %Digest{}} = Digest.parse(valid)

      for value <- [nil, 1, :digest, %{}, [], "", String.upcase(valid), "abc"] do
        assert Digest.parse(value) == {:error, :invalid_format}
      end
    end
  end

  property "a canonical UUID with one character changed still returns a tagged result" do
    check all(
            position <- StreamData.integer(0..(byte_size(@uuid) - 1)),
            replacement <- StreamData.member_of(["0", "f", "g", "-", " "]),
            module <- StreamData.member_of([CredentialId, SshKeyId])
          ) do
      {before, <<_byte, after_::binary>>} = :erlang.split_binary(@uuid, position)
      mutated = before <> replacement <> after_

      assert match?({:ok, _}, module.parse(mutated)) or
               match?({:error, :invalid_format}, module.parse(mutated)),
             "#{inspect(module)} did not return a tagged result for #{inspect(mutated)}"
    end
  end

  property "a valid same-origin path with one character changed still returns a tagged result" do
    path = "/preview/some/path?x=1"

    check all(
            position <- StreamData.integer(0..(byte_size(path) - 1)),
            replacement <- StreamData.member_of(["/", "#", "\\", " ", "?", "h"])
          ) do
      {before, <<_byte, after_::binary>>} = :erlang.split_binary(path, position)
      mutated = before <> replacement <> after_

      assert match?({:ok, _}, SameOriginPath.parse(mutated)) or
               match?({:error, :invalid_format}, SameOriginPath.parse(mutated)),
             "SameOriginPath did not return a tagged result for #{inspect(mutated)}"
    end
  end

  property "every identity parser accepts arbitrary terms without raising" do
    check all(value <- term()) do
      for module <- [CredentialId, SshKeyId, SameOriginPath, SshPublicKey] do
        assert match?({:ok, _}, module.parse(value)) or
                 match?({:error, :invalid_format}, module.parse(value)),
               "#{inspect(module)} raised or returned #{inspect(module.parse(value))} for #{inspect(value)}"
      end
    end
  end

  property "every identity parser accepts arbitrary binaries without raising" do
    check all(value <- StreamData.binary()) do
      for module <- [CredentialId, SshKeyId, SameOriginPath, SshPublicKey] do
        assert match?({:ok, _}, module.parse(value)) or
                 match?({:error, :invalid_format}, module.parse(value)),
               "#{inspect(module)} raised or returned #{inspect(module.parse(value))} for #{inspect(value)}"
      end
    end
  end

  property "SshPublicKey.parse never raises on one-character mutations of a valid line" do
    check all(
            position <- StreamData.integer(0..(byte_size(@ed25519) - 1)),
            replacement <- StreamData.member_of(["x", "A", " ", "\n", "0", "-"])
          ) do
      {before, <<_byte, after_::binary>>} = :erlang.split_binary(@ed25519, position)
      mutated = before <> replacement <> after_

      assert match?({:ok, _}, SshPublicKey.parse(mutated)) or
               match?({:error, :invalid_format}, SshPublicKey.parse(mutated)),
             "SshPublicKey raised or returned an undeclared result for #{inspect(mutated)}"
    end
  end
end
