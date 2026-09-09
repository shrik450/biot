defmodule Biot.Server.Queries.DeploymentTest do
  use ExUnit.Case, async: false

  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Actor
  alias Biot.Server.Queries.Deployment
  alias Biot.Server.Queries.DeploymentView
  alias Biot.Server.TestFixtures

  @settings [:publication_domain, :ssh_advertised_host, :ssh_port]

  setup do
    previous = Map.new(@settings, &{&1, Application.get_env(:biot_server, &1)})

    on_exit(fn ->
      for {key, value} <- previous, do: Application.put_env(:biot_server, key, value)
    end)

    %{actor: %Actor{principal_id: TestFixtures.id(PrincipalId, 1)}}
  end

  test "any authenticated actor reads the advertised settings", context do
    Application.put_env(:biot_server, :publication_domain, "preview.example.test")
    Application.put_env(:biot_server, :ssh_advertised_host, "ssh.example.test")
    Application.put_env(:biot_server, :ssh_port, 2_222)

    assert Deployment.get(context.actor) ==
             {:ok,
              %DeploymentView{
                publication_domain: "preview.example.test",
                ssh: %{host: "ssh.example.test", port: 2_222}
              }}
  end

  test "the settings are read on every call", context do
    Application.put_env(:biot_server, :ssh_port, 22)
    assert {:ok, %DeploymentView{ssh: %{port: 22}}} = Deployment.get(context.actor)

    Application.put_env(:biot_server, :ssh_port, 2_022)
    assert {:ok, %DeploymentView{ssh: %{port: 2_022}}} = Deployment.get(context.actor)
  end

  test "an unauthenticated caller reads nothing" do
    assert Deployment.get(nil) == {:error, :unauthenticated}
  end
end
