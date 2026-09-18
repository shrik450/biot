defmodule Biot.Server.Nodes.EnrollTaskTest do
  use ExUnit.Case, async: false

  alias Biot.Protocol.Certificates
  alias Biot.Protocol.RegistrationId
  alias Mix.Tasks.Biot.Enroll

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  @tag :tmp_dir
  test "writes a node from a fingerprint and adds a second node", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "registrations.json")
    first = registration_id()
    second = registration_id()

    run(file, first, ["--fingerprint", String.duplicate("a", 64), "--max-biots", "4"])
    run(file, second, ["--fingerprint", String.duplicate("b", 64), "--max-biots", "8"])

    entries = Jason.decode!(File.read!(file))

    assert Enum.map(entries, & &1["registration_id"]) == Enum.sort([first, second])
    assert Enum.all?(entries, &(&1["status"] == "enabled"))
  end

  @tag :tmp_dir
  test "re-running a registration keeps its node id and updates capacity", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "registrations.json")
    registration_id = registration_id()
    fingerprint = String.duplicate("a", 64)

    run(file, registration_id, ["--fingerprint", fingerprint, "--max-biots", "4"])
    assert [%{"node_id" => node_id}] = Jason.decode!(File.read!(file))

    run(file, registration_id, ["--fingerprint", fingerprint, "--max-biots", "16"])

    assert [%{"node_id" => ^node_id, "max_biots" => 16}] = Jason.decode!(File.read!(file))
  end

  @tag :tmp_dir
  test "derives the fingerprint from the node certificate by name", %{tmp_dir: tmp_dir} do
    certs_dir = Path.join(tmp_dir, "certs")
    File.mkdir_p!(certs_dir)
    {:ok, _authority} = Certificates.create_authority(certs_dir)
    {:ok, %{fingerprint: fingerprint}} = Certificates.issue(certs_dir, {:node, "local"})
    file = Path.join(tmp_dir, "registrations.json")

    run(file, registration_id(), ["--name", "local", "--certs-dir", certs_dir, "--max-biots", "2"])

    assert [%{"peer_identity" => ^fingerprint}] = Jason.decode!(File.read!(file))
  end

  @tag :tmp_dir
  test "refuses a malformed fingerprint and writes nothing", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "registrations.json")

    assert_raise Mix.Error, ~r/64 lowercase hex/, fn ->
      run(file, registration_id(), ["--fingerprint", "not-hex", "--max-biots", "4"])
    end

    refute File.exists?(file)
  end

  @tag :tmp_dir
  test "refuses a malformed registration id and a name with no certificate", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "registrations.json")

    assert_raise Mix.Error, ~r/canonical UUID/, fn ->
      run(file, "not-a-uuid", ["--fingerprint", String.duplicate("a", 64), "--max-biots", "4"])
    end

    assert_raise Mix.Error, ~r/no certificate at/, fn ->
      run(file, registration_id(), [
        "--name",
        "missing",
        "--certs-dir",
        tmp_dir,
        "--max-biots",
        "4"
      ])
    end
  end

  defp run(file, registration_id, extra) do
    Enroll.run(["--file", file, "--registration-id", registration_id] ++ extra)
  end

  defp registration_id do
    RegistrationId.generate() |> to_string()
  end
end
