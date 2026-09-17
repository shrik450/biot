defmodule BiotWeb.FieldReasonReachabilityTest do
  use BiotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Biot.Protocol.{BiotId, FieldReason, Limits, RegistrationId, Version}
  alias Biot.Server.Biots
  alias Biot.Server.Biots.Create
  alias Biot.Server.Credentials
  alias Biot.Server.Label
  alias Biot.Server.Nodes.Registration
  alias Biot.Server.Principals
  alias Biot.Server.Sessions
  alias Biot.Server.SshKeys
  alias BiotWeb.Live.NewBiotForm
  alias BiotWeb.Live.NewBiotWorkflow
  alias BiotWeb.Params
  alias BiotWeb.TestFixtures
  alias BiotWeb.UserMessage

  @ed25519 "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINzyzz1M9L5KLhn5k5Lh3Peq0ipDgKB4DPAJ0A7UqS06"

  test "every field reason is reachable from a real emitter" do
    owner = TestFixtures.principal(1)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    {:ok, control_token} = Sessions.start_control(owner.id)
    {:ok, control} = Sessions.control(control_token)

    previous_default = Application.get_env(:biot_server, :default_node_id)
    on_exit(fn -> Application.put_env(:biot_server, :default_node_id, previous_default) end)
    Application.put_env(:biot_server, :default_node_id, nil)

    valid_form = %{
      "repository" => "https://github.com/example/project.git",
      "name" => "demo",
      "base_source" => "nixpkgs",
      "base_ref" => "",
      "initial_state" => "running"
    }

    emissions = [
      NewBiotForm.parse(%{}),
      NewBiotForm.parse(
        Map.put(valid_form, "runtime_secrets", %{"0" => %{"name" => "PATH", "value" => "x"}})
      ),
      NewBiotForm.parse(
        Map.put(valid_form, "runtime_secrets", %{"0" => %{"name" => "TOKEN", "value" => <<0>>}})
      ),
      NewBiotForm.parse(
        Map.put(valid_form, "runtime_secrets", %{
          "0" => %{
            "name" => "TOKEN",
            "value" =>
              String.duplicate(
                "x",
                Limits.max_secret_value_bytes(Enum.max(Version.supported())) + 1
              )
          }
        })
      ),
      NewBiotForm.parse(
        Map.put(
          valid_form,
          "layers",
          Map.new(
            0..Limits.max_layers(),
            &{Integer.to_string(&1),
             %{"source" => "https://github.com/example/layer.git", "ref" => "main"}}
          )
        )
      ),
      NewBiotForm.parse(
        Map.put(
          valid_form,
          "repository",
          "https://" <> String.duplicate("a", Limits.max_repository_url_bytes())
        )
      ),
      NewBiotForm.parse(Map.put(valid_form, "name", String.duplicate("a", 64))),
      NewBiotForm.parse(
        Map.put(valid_form, "layers", %{
          "0" => %{
            "source" => "https://github.com/example/layer.git",
            "ref" => String.duplicate("a", Limits.max_source_ref_bytes() + 1)
          }
        })
      ),
      NewBiotForm.parse(
        Map.put(valid_form, "repository", "https://user@example.com/project.git")
      ),
      Params.page(%{"limit" => "201"}),
      Principals.identify(nil, nil, nil),
      Label.validate(""),
      invalid_registration(),
      Biots.create(
        TestFixtures.actor(owner),
        TestFixtures.id(BiotId, 9_001),
        %Create{
          name: TestFixtures.biot_name("another"),
          repository: TestFixtures.repository(),
          environment: TestFixtures.selection(),
          node_id: :default,
          initial_state: :running
        }
      ),
      Credentials.create(control, "expired", DateTime.utc_now()),
      Credentials.create(
        control,
        "too-far",
        DateTime.add(
          DateTime.utc_now(),
          Application.fetch_env!(:biot_server, :credential_max_lifetime_ms) + 60_000,
          :millisecond
        )
      ),
      SshKeys.add(TestFixtures.actor(owner), @ed25519, "first"),
      SshKeys.add(TestFixtures.actor(owner), @ed25519, "again"),
      NewBiotWorkflow.failed(
        NewBiotWorkflow.new(TestFixtures.id(BiotId, 9_002), :running, [], []),
        :starting,
        :not_ready
      )
    ]

    {:ok, view, _html} = live(authenticated_conn(control_token), "/biots/#{biot.id}/access")

    unknown_principal_html =
      view
      |> element("#share-form")
      |> render_submit(%{"email" => "nobody@example.test", "kind" => "shell"})

    assert unknown_principal_html =~ UserMessage.field_error(:email, :unknown_principal)

    inactive_publication_html =
      view
      |> element("#share-form")
      |> render_submit(%{"email" => "person-1@example.test", "kind" => "view:3000"})

    assert inactive_publication_html =~ UserMessage.field_error(:kind, :publication_not_active)

    reached =
      emissions
      |> Enum.flat_map(&emitted_reasons/1)
      |> Kernel.++([:unknown_principal, :publication_not_active])
      |> MapSet.new()

    for reason <- reached do
      assert FieldReason.member?(reason), "emitter produced undeclared reason #{inspect(reason)}"
    end

    declared = MapSet.new(FieldReason.all())
    assert MapSet.size(MapSet.difference(reached, declared)) == 0

    unreachable = Enum.reject(FieldReason.all(), &MapSet.member?(reached, &1))

    assert unreachable == [],
           "no real emitter produces these field reasons: #{inspect(unreachable)}"
  end

  defp invalid_registration do
    Registration.parse(%{
      "node_id" => to_string(TestFixtures.id(Biot.Protocol.NodeId, 1)),
      "registration_id" => to_string(TestFixtures.id(RegistrationId, 1_001)),
      "peer_identity" => String.duplicate("0", 64),
      "max_biots" => 1,
      "status" => "unknown"
    })
  end

  defp emitted_reasons({:error, {:invalid_input, fields}}),
    do: Enum.flat_map(fields, fn {_field, reasons} -> List.wrap(reasons) end)

  defp emitted_reasons({:error, {_field, reason}}) when is_atom(reason), do: [reason]
  defp emitted_reasons(%{reason: reason}) when is_atom(reason), do: [reason]
  defp emitted_reasons(_result), do: []

  defp authenticated_conn(token),
    do: Plug.Test.init_test_session(build_conn(), %{"token" => token})
end
