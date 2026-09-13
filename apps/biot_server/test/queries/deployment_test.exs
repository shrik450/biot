defmodule Biot.Server.Queries.DeploymentTest do
  use Biot.Server.DataCase, async: false

  import Ecto.Query

  alias Biot.Server.Queries.Deployment
  alias Biot.Server.Queries.DeploymentView
  alias Biot.Server.TestFixtures

  @settings [:publication_domain, :ssh_advertised_host, :ssh_port]

  setup do
    previous = Map.new(@settings, &{&1, Application.get_env(:biot_server, &1)})

    on_exit(fn ->
      for {key, value} <- previous, do: Application.put_env(:biot_server, key, value)
    end)

    principal = TestFixtures.principal(1)

    %{actor: TestFixtures.actor(principal)}
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

  test "a disabled caller reads nothing" do
    principal = TestFixtures.principal(2)
    disable(principal)

    assert Deployment.get(TestFixtures.actor(principal)) == {:error, :unauthenticated}
  end

  defp disable(principal) do
    Repo.update_all(
      from(p in Biot.Server.Schema.Principal, where: p.id == ^principal.id),
      set: [status: :disabled]
    )
  end
end
