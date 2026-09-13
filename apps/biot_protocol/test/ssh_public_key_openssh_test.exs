defmodule Biot.Protocol.SshPublicKeyOpenSshTest do
  @moduledoc """
  Checks `SshPublicKey` against the reference tool, `ssh-keygen -lf`.

  Keys are generated in a temporary directory so the fingerprints are not
  hand-copied and cannot drift from what OpenSSH prints.
  """

  use ExUnit.Case, async: true

  alias Biot.Protocol.SshPublicKey

  if System.find_executable("ssh-keygen") == nil do
    @moduletag :skip
  end

  setup_all do
    keygen = System.find_executable("ssh-keygen")
    dir = Path.join(System.tmp_dir!(), "biot-ssh-keys-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    keys =
      for {name, flags} <- [
            {"ed25519", ["-t", "ed25519"]},
            {"ecdsa", ["-t", "ecdsa", "-b", "256"]},
            {"rsa", ["-t", "rsa", "-b", "2048"]}
          ],
          into: %{} do
        {name, generate(keygen, dir, name, flags)}
      end

    {:ok, keys: keys}
  end

  test "every algorithm and shape matches the ssh-keygen fingerprint", %{keys: keys} do
    for {name, key} <- keys, {label, line} <- variants(key) do
      assert {:ok, parsed} = SshPublicKey.parse(line)
      assert SshPublicKey.fingerprint(parsed) == key.fingerprint, "#{name} #{label} fingerprint"
      assert SshPublicKey.to_string(parsed) == bare(key), "#{name} #{label} canonical line"
    end
  end

  test "the same key in every shape has one fingerprint", %{keys: keys} do
    for {_name, key} <- keys do
      fingerprints =
        for {_label, line} <- variants(key) do
          {:ok, parsed} = SshPublicKey.parse(line)
          SshPublicKey.fingerprint(parsed)
        end

      assert Enum.uniq(fingerprints) == [key.fingerprint]
    end
  end

  defp generate(keygen, dir, name, flags) do
    path = Path.join(dir, name)

    {_out, 0} =
      System.cmd(keygen, flags ++ ["-N", "", "-C", "biot test key", "-f", path],
        stderr_to_stdout: true
      )

    {listing, 0} = System.cmd(keygen, ["-lf", path <> ".pub"], stderr_to_stdout: true)
    [_bits, fingerprint | _rest] = String.split(listing)

    public = (path <> ".pub") |> File.read!() |> String.trim()
    [algorithm, blob | _comment] = String.split(public)

    %{algorithm: algorithm, blob: blob, fingerprint: fingerprint}
  end

  defp bare(key), do: key.algorithm <> " " <> key.blob

  defp variants(key) do
    bare = bare(key)

    [
      {"no comment", bare},
      {"one-word comment", bare <> " user@host"},
      {"comment with spaces", bare <> " work laptop key"},
      {"tab between fields", key.algorithm <> "\t" <> key.blob},
      {"tab-separated comment", key.algorithm <> "\t" <> key.blob <> "\twork laptop"},
      {"trailing spaces", bare <> "   "},
      {"trailing space after comment", bare <> " comment  "}
    ]
  end
end
