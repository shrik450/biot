defmodule BiotWeb.LongNameIntegrationTest do
  use BiotWeb.ConnCase, async: false

  alias Biot.Protocol.{BiotId, EnvironmentSelection, RepositorySource}
  alias Biot.Server.Credentials
  alias Biot.Server.Credentials.Created
  alias Biot.Server.Sessions
  alias BiotWeb.Live.NewBiotForm
  alias BiotWeb.TestFixtures
  alias BiotWeb.UserMessage

  setup do
    owner = TestFixtures.principal(1)
    {:ok, control_token} = Sessions.start_control(owner.id)
    {:ok, control} = Sessions.control(control_token)

    {:ok, %Created{token: bearer_token}} =
      Credentials.create(
        control,
        "long-name-test",
        DateTime.add(DateTime.utc_now(), 86_400, :second)
      )

    %{bearer_token: bearer_token}
  end

  test "the creation form command reports a too-long name in its field map" do
    assert {:error, {:invalid_input, %{name: [:name_too_long]}}} =
             NewBiotForm.parse(form_body())
  end

  test "the web message identifies the name length problem" do
    message = UserMessage.error({:invalid_input, %{name: [:name_too_long]}})

    assert message == "name is longer than 63 characters; shorten it."
    refute message =~ "invalid format"
  end

  test "the API JSON preserves name_too_long for a rejected create", context do
    response =
      api_conn(context.bearer_token)
      |> json_request(
        :put,
        "/api/biots/#{TestFixtures.id(BiotId, 9_102)}",
        create_body()
      )

    assert json_response(response, 422) == %{
             "error" => "invalid_input",
             "fields" => %{"name" => ["name_too_long"]}
           }
  end

  defp create_body do
    %{
      "name" => String.duplicate("a", 70),
      "repository" => RepositorySource.to_string(TestFixtures.repository()),
      "environment" => EnvironmentSelection.encode(TestFixtures.selection()),
      "initial_state" => "stopped"
    }
  end

  defp form_body do
    %{
      "name" => String.duplicate("a", 70),
      "repository" => RepositorySource.to_string(TestFixtures.repository()),
      "base_source" => "nixpkgs",
      "base_ref" => "",
      "initial_state" => "running"
    }
  end
end
