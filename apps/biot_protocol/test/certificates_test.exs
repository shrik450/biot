defmodule Biot.Protocol.CertificatesTest do
  # Not async: the operator-flow test below runs a Mix task, and running one inside an umbrella
  # moves the working directory and pushes Mix's project stack, both of which belong to the whole
  # VM. ExUnit starts an async case as soon as its own file loads, while the parallel compiler is
  # still requiring the rest by relative path, so this case running concurrently left whichever
  # file was loading at that moment to fail with `{:error, :enoent}`.
  use ExUnit.Case, async: false

  alias Biot.Protocol.Certificates
  alias Biot.Protocol.PeerIdentity

  @moduletag :tmp_dir

  test "the authority is created once and never replaced", %{tmp_dir: directory} do
    assert {:ok, authority} = Certificates.create_authority(directory)
    before = {File.read!(authority), File.read!(Path.join(directory, "ca-key.pem"))}

    assert Certificates.create_authority(directory) == {:error, :authority_exists}
    assert {File.read!(authority), File.read!(Path.join(directory, "ca-key.pem"))} == before
  end

  test "every private key is readable by its owner alone", %{tmp_dir: directory} do
    {:ok, _authority} = Certificates.create_authority(directory)
    {:ok, server} = Certificates.issue(directory, :server)
    {:ok, node} = Certificates.issue(directory, {:node, "1"})

    for key <- [Path.join(directory, "ca-key.pem"), server.key, node.key] do
      assert {:ok, stat} = File.stat(key)
      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end
  end

  test "leaves chain to the authority with the usage their role needs", %{tmp_dir: directory} do
    {:ok, authority} = Certificates.create_authority(directory)
    {:ok, server} = Certificates.issue(directory, :server)
    {:ok, node} = Certificates.issue(directory, {:node, "edge-1"})

    assert Path.basename(node.cert) == "node-edge-1-cert.pem"
    assert extension_usage(server.cert) == [:serverAuth, :clientAuth]
    assert extension_usage(node.cert) == [:clientAuth]

    for leaf <- [server, node] do
      assert {:ok, _result} =
               :public_key.pkix_path_validation(der(authority), [der(leaf.cert)], [])

      assert PeerIdentity.from_certificate(der(leaf.cert)) == {:ok, leaf.fingerprint}
    end
  end

  test "a node added later uses the same authority and changes no other file",
       %{tmp_dir: directory} do
    {:ok, authority} = Certificates.create_authority(directory)
    {:ok, server} = Certificates.issue(directory, :server)
    {:ok, first} = Certificates.issue(directory, {:node, "1"})
    before = snapshot([authority, server.cert, server.key, first.cert, first.key])

    {:ok, second} = Certificates.issue(directory, {:node, "2"})

    assert snapshot([authority, server.cert, server.key, first.cert, first.key]) == before

    assert {:ok, _result} =
             :public_key.pkix_path_validation(der(authority), [der(second.cert)], [])

    refute second.fingerprint == first.fingerprint
  end

  test "issuing again renews the certificate and keeps the key and fingerprint",
       %{tmp_dir: directory} do
    {:ok, _authority} = Certificates.create_authority(directory)
    {:ok, first} = Certificates.issue(directory, {:node, "1"})
    {first_certificate, first_key} = {File.read!(first.cert), File.read!(first.key)}

    {:ok, renewed} = Certificates.issue(directory, {:node, "1"})

    assert renewed.fingerprint == first.fingerprint
    assert File.read!(renewed.key) == first_key
    refute File.read!(renewed.cert) == first_certificate
  end

  test "issuing needs an authority and a valid node name", %{tmp_dir: directory} do
    assert Certificates.issue(directory, :server) == {:error, :missing_authority}

    {:ok, _authority} = Certificates.create_authority(directory)

    for name <- ["", "Node", "node/1", "../node", "node 1"] do
      assert Certificates.issue(directory, {:node, name}) == {:error, :invalid_node_name}
    end

    File.write!(Path.join(directory, "server-key.pem"), "not a key")
    assert Certificates.issue(directory, :server) == {:error, :malformed_key}
  end

  test "mix biot.certs runs the operator flow", %{tmp_dir: directory} do
    for args <- [["authority", directory], ["server", directory], ["node", directory, "1"]] do
      Mix.Task.reenable("biot.certs")
      Mix.Task.run("biot.certs", args)
    end

    for file <-
          ~w(ca.pem ca-key.pem server-cert.pem server-key.pem node-1-cert.pem node-1-key.pem) do
      assert File.exists?(Path.join(directory, file))
    end

    Mix.Task.reenable("biot.certs")

    assert_raise Mix.Error, ~r/never replaced/, fn ->
      Mix.Task.run("biot.certs", ["authority", directory])
    end
  end

  defp der(path),
    do: path |> File.read!() |> X509.Certificate.from_pem!() |> X509.Certificate.to_der()

  defp snapshot(paths), do: Enum.map(paths, &File.read!/1)

  defp extension_usage(path) do
    path
    |> File.read!()
    |> X509.Certificate.from_pem!()
    |> X509.Certificate.extension(:ext_key_usage)
    |> elem(3)
    |> Enum.map(fn
      {1, 3, 6, 1, 5, 5, 7, 3, 1} -> :serverAuth
      {1, 3, 6, 1, 5, 5, 7, 3, 2} -> :clientAuth
    end)
  end
end
