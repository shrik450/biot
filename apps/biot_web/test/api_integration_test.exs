defmodule BiotWeb.ApiIntegrationTest do
  use BiotWeb.ConnCase, async: false

  import Ecto.Query

  alias Biot.Protocol.BiotId
  alias Biot.Server.Credentials
  alias Biot.Server.Credentials.Created
  alias Biot.Server.Repo
  alias Biot.Server.Schema.{Credential, Principal}
  alias Biot.Server.Sessions
  alias BiotWeb.Cookies
  alias BiotWeb.TestFixtures

  @ed25519 "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINzyzz1M9L5KLhn5k5Lh3Peq0ipDgKB4DPAJ0A7UqS06"

  @api_routes [
    {"GET", "/api/me"},
    {"GET", "/api/deployment"},
    {"GET", "/api/nodes"},
    {"GET", "/api/principals?email=person-1%40example.test"},
    {"GET", "/api/biots"},
    {"PUT", "/api/biots/:id"},
    {"GET", "/api/biots/:id"},
    {"DELETE", "/api/biots/:id"},
    {"POST", "/api/biots/:id/start"},
    {"POST", "/api/biots/:id/stop"},
    {"POST", "/api/biots/:id/environment"},
    {"GET", "/api/biots/:id/publications"},
    {"PUT", "/api/biots/:id/publications/:port"},
    {"DELETE", "/api/biots/:id/publications/:port"},
    {"GET", "/api/biots/:id/grants"},
    {"PUT", "/api/biots/:id/grants/shell/:principal_id"},
    {"DELETE", "/api/biots/:id/grants/shell/:principal_id"},
    {"PUT", "/api/biots/:id/grants/view/:port/:principal_id"},
    {"DELETE", "/api/biots/:id/grants/view/:port/:principal_id"},
    {"GET", "/api/biots/:id/secrets"},
    {"PUT", "/api/biots/:id/secrets/:name"},
    {"DELETE", "/api/biots/:id/secrets/:name"},
    {"PUT", "/api/biots/:id/fetch-credentials"},
    {"DELETE", "/api/biots/:id/fetch-credentials"},
    {"GET", "/api/operations/:id"},
    {"GET", "/api/diagnostics/:ref"},
    {"GET", "/api/biots/:id/logs"},
    {"GET", "/api/credentials"},
    {"DELETE", "/api/credentials/:id"},
    {"GET", "/api/ssh-keys"},
    {"POST", "/api/ssh-keys"},
    {"DELETE", "/api/ssh-keys/:id"}
  ]

  setup do
    previous_default = Application.get_env(:biot_server, :default_node_id)
    owner = TestFixtures.principal(1)
    collaborator = TestFixtures.principal(2)
    node = TestFixtures.node(1)
    {biot, _environment} = TestFixtures.biot(owner, node, 1)
    Application.put_env(:biot_server, :default_node_id, node.id)

    {:ok, control_token} = Sessions.start_control(owner.id)
    {:ok, control_authentication} = Sessions.control(control_token)

    {:ok, %Created{token: bearer_token}} =
      Credentials.create(
        control_authentication,
        "api-test",
        DateTime.add(DateTime.utc_now(), 86_400, :second)
      )

    on_exit(fn -> Application.put_env(:biot_server, :default_node_id, previous_default) end)

    %{
      owner: owner,
      collaborator: collaborator,
      node: node,
      biot: biot,
      control_token: control_token,
      bearer_token: bearer_token
    }
  end

  test "every model API route requires a bearer credential", context do
    for {method, route} <- @api_routes do
      path = String.replace(route, ":id", to_string(context.biot.id))
      path = String.replace(path, ":port", "3000")
      path = String.replace(path, ":principal_id", to_string(context.collaborator.id))
      path = String.replace(path, ":name", "TOKEN")
      path = String.replace(path, ":ref", String.duplicate("a", 36))

      conn = request(api_conn(nil), method, path)
      assert conn.status == 401, "#{method} #{path}: #{conn.resp_body}"
      assert json_body(conn) == %{"error" => "unauthenticated"}
    end

    browser_response =
      Plug.Test.init_test_session(build_conn(), %{"token" => context.control_token})
      |> get("/login")

    signed_cookie = cookie_value(browser_response, Cookies.session_name())
    assert is_binary(signed_cookie)

    cookie_conn =
      api_conn(nil)
      |> put_req_header("cookie", Cookies.session_name() <> "=" <> signed_cookie)
      |> get("/api/me")

    assert cookie_conn.status == 401
  end

  test "the router's API routes match the model route table", _context do
    actual =
      BiotWeb.Router.__routes__()
      |> Enum.filter(&String.starts_with?(&1.path, "/api"))
      |> Enum.reject(&(&1.plug == BiotWeb.Api.FallbackController))
      |> Enum.map(&{String.upcase(to_string(&1.verb)), &1.path})
      |> MapSet.new()

    expected =
      @api_routes
      |> Enum.map(fn {method, path} -> {method, String.replace(path, ~r/\?.*\z/, "")} end)
      |> MapSet.new()

    assert actual == expected
  end

  test "valid bearer auth reaches me and invalid credentials stay indistinguishable", context do
    response = get(api_conn(context.bearer_token), "/api/me")

    assert json_response(response, 200) == %{
             "id" => to_string(context.owner.id),
             "email" => "person-1@example.test",
             "name" => "Person 1"
           }

    assert json_response(api_conn("biot_unknown") |> get("/api/me"), 401) ==
             %{"error" => "unauthenticated"}

    {:ok, control_authentication} = Sessions.control(context.control_token)

    {:ok, %Created{credential: live, token: live_token}} =
      Credentials.create(
        control_authentication,
        "live-revocation",
        DateTime.add(DateTime.utc_now(), 86_400, :second)
      )

    assert json_response(api_conn(live_token) |> get("/api/me"), 200)["id"] ==
             to_string(context.owner.id)

    revoked =
      delete(api_conn(context.bearer_token), "/api/credentials/#{live.id}")

    assert revoked.status == 204
    assert revoked.resp_body == ""

    assert json_response(api_conn(live_token) |> get("/api/me"), 401) ==
             %{"error" => "unauthenticated"}

    {:ok, %Created{credential: expired, token: expired_token}} =
      Credentials.create(
        control_authentication,
        "expired",
        DateTime.add(DateTime.utc_now(), 86_400, :second)
      )

    Repo.update_all(
      from(credential in Credential, where: credential.id == ^expired.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert json_response(api_conn(expired_token) |> get("/api/me"), 401) ==
             %{"error" => "unauthenticated"}

    assert Credentials.revoke(context.owner |> TestFixtures.actor(), expired.id) == :ok

    assert json_response(api_conn(expired_token) |> get("/api/me"), 401) ==
             %{"error" => "unauthenticated"}

    Repo.update_all(
      from(principal in Principal, where: principal.id == ^context.owner.id),
      set: [status: :disabled]
    )

    assert json_response(api_conn(context.bearer_token) |> get("/api/me"), 401) ==
             %{"error" => "unauthenticated"}
  end

  test "the API fallback returns the model error shape", context do
    unknown = get(api_conn(context.bearer_token), "/api/not-a-route")
    assert unknown.status == 404
    assert json_body(unknown) == %{"error" => "not_found"}
  end

  test "lifecycle routes return accepted operations, unchanged results, and conflicts", context do
    stop =
      api_conn(context.bearer_token)
      |> json_request(:post, "/api/biots/#{context.biot.id}/stop", %{"expected_revision" => 1})

    stop_body = json_response(stop, 202)
    assert stop_body["biot_id"] == to_string(context.biot.id)
    assert stop_body["revision"] == 2
    assert get_resp_header(stop, "location") == ["/api/operations/#{stop_body["operation_id"]}"]

    unchanged =
      api_conn(context.bearer_token)
      |> json_request(:post, "/api/biots/#{context.biot.id}/stop", %{"expected_revision" => 2})

    assert json_response(unchanged, 200) == %{
             "biot_id" => to_string(context.biot.id),
             "revision" => 2
           }

    conflict =
      api_conn(context.bearer_token)
      |> json_request(:post, "/api/biots/#{context.biot.id}/start", %{"expected_revision" => 1})

    assert json_response(conflict, 409) == %{
             "error" => "revision_conflict",
             "current_revision" => 2
           }

    operation_id = stop_body["operation_id"]
    operation = get(api_conn(context.bearer_token), "/api/operations/#{operation_id}")
    assert json_response(operation, 200)["id"] == operation_id

    bad_input =
      api_conn(context.bearer_token)
      |> json_request(:post, "/api/biots/not-a-uuid/start", %{"expected_revision" => 1})

    assert json_response(bad_input, 422) == %{
             "error" => "invalid_input",
             "fields" => %{"id" => ["invalid_format"]}
           }
  end

  test "create, list, get, and destroy use the lifecycle JSON contract", context do
    biot_id = TestFixtures.id(BiotId, 9_001)

    body = %{
      "name" => "created-through-api",
      "repository" => "https://github.com/example/project.git",
      "environment" => %{
        "base_nixpkgs" => "nixpkgs",
        "layers" => [],
        "project_context" => nil
      },
      "node_id" => to_string(context.node.id),
      "initial_state" => "stopped"
    }

    created =
      api_conn(context.bearer_token)
      |> json_request(:put, "/api/biots/#{biot_id}", body)

    created_body = json_response(created, 202)
    assert created_body["biot_id"] == to_string(biot_id)

    assert get_resp_header(created, "location") == [
             "/api/operations/#{created_body["operation_id"]}"
           ]

    listed = get(api_conn(context.bearer_token), "/api/biots")
    assert Enum.any?(json_response(listed, 200), &(&1["id"] == to_string(biot_id)))

    fetched = get(api_conn(context.bearer_token), "/api/biots/#{biot_id}")
    assert json_response(fetched, 200)["id"] == to_string(biot_id)

    destroyed = delete(api_conn(context.bearer_token), "/api/biots/#{biot_id}")
    assert json_response(destroyed, 202)["biot_id"] == to_string(biot_id)
  end

  test "authorized account and lifecycle routes return their HTTP outcomes", context do
    principal =
      get(api_conn(context.bearer_token), "/api/principals?email=person-2%40example.test")

    assert json_response(principal, 200) == %{"id" => to_string(context.collaborator.id)}

    added_key =
      api_conn(context.bearer_token)
      |> json_request(:post, "/api/ssh-keys", %{
        "public_key" => @ed25519,
        "label" => "laptop"
      })

    added_key_body = json_response(added_key, 201)
    assert added_key_body["public_key"] == @ed25519
    assert added_key_body["label"] == "laptop"
    key_id = added_key_body["id"]

    listed_keys = get(api_conn(context.bearer_token), "/api/ssh-keys")
    assert Enum.any?(json_response(listed_keys, 200), &(&1["id"] == key_id))

    removed_key = delete(api_conn(context.bearer_token), "/api/ssh-keys/#{key_id}")
    assert removed_key.status == 204
    assert removed_key.resp_body == ""

    environment = %{
      "base_nixpkgs" => "nixpkgs",
      "layers" => [],
      "project_context" => nil
    }

    updated =
      api_conn(context.bearer_token)
      |> json_request(:post, "/api/biots/#{context.biot.id}/environment", %{
        "environment" => environment,
        "expected_revision" => 1
      })

    updated_body = json_response(updated, 202)
    assert updated_body["biot_id"] == to_string(context.biot.id)
    assert updated_body["revision"] == 2
    assert get_resp_header(updated, "location") != []

    publication_path = "/api/biots/#{context.biot.id}/publications/3000"
    published = json_request(api_conn(context.bearer_token), :put, publication_path, %{})
    assert json_response(published, 200)["result"] == "applied"

    unpublished = delete(api_conn(context.bearer_token), publication_path)
    unpublished_body = json_response(unpublished, 200)
    assert unpublished_body["result"] == "applied"
    assert unpublished_body["access_revision"] == 2

    source = "https://host.test/org/private.git"
    fetch_body = %{"source" => source, "value" => "Bearer abc"}

    delivered =
      api_conn(context.bearer_token)
      |> json_request(:put, "/api/biots/#{context.biot.id}/fetch-credentials", fetch_body)

    assert json_response(delivered, 503) == %{"error" => "temporarily_unavailable"}
    refute delivered.resp_body =~ "Bearer abc"

    removed =
      api_conn(context.bearer_token)
      |> json_request(:delete, "/api/biots/#{context.biot.id}/fetch-credentials", %{
        "source" => source
      })

    assert json_response(removed, 503) == %{"error" => "temporarily_unavailable"}
  end

  test "publication and grant routes expose applied and unchanged policy", context do
    publication_path = "/api/biots/#{context.biot.id}/publications/3000"

    published = json_request(api_conn(context.bearer_token), :put, publication_path, %{})
    published_body = json_response(published, 200)
    assert published_body["result"] == "applied"
    assert published_body["access_revision"] == 1
    assert published_body["enforcement"]["kind"] == "pending"

    assert json_response(
             json_request(api_conn(context.bearer_token), :put, publication_path, %{}),
             200
           )["result"] == "unchanged"

    publications =
      get(api_conn(context.bearer_token), "/api/biots/#{context.biot.id}/publications")

    assert [%{"port" => 3000, "url" => url}] = json_response(publications, 200)
    assert url =~ "https://"

    shell_path = "/api/biots/#{context.biot.id}/grants/shell/#{context.collaborator.id}"
    view_path = "/api/biots/#{context.biot.id}/grants/view/3000/#{context.collaborator.id}"

    for path <- [shell_path, view_path] do
      assert json_response(json_request(api_conn(context.bearer_token), :put, path, %{}), 200)[
               "result"
             ] == "applied"

      assert json_response(json_request(api_conn(context.bearer_token), :put, path, %{}), 200)[
               "result"
             ] == "unchanged"
    end

    grants = get(api_conn(context.bearer_token), "/api/biots/#{context.biot.id}/grants")
    assert json_body(grants)["shell_grants"] == [to_string(context.collaborator.id)]

    assert json_body(grants)["view_grants"] == [
             %{"port" => 3000, "principal_id" => to_string(context.collaborator.id)}
           ]

    assert json_response(delete(api_conn(context.bearer_token), view_path), 200)["result"] ==
             "applied"

    assert json_response(delete(api_conn(context.bearer_token), view_path), 200)["result"] ==
             "unchanged"

    bad =
      json_request(
        api_conn(context.bearer_token),
        :put,
        "/api/biots/#{context.biot.id}/publications/0",
        %{}
      )

    assert json_response(bad, 422)["fields"] == %{"port" => ["out_of_range"]}
  end

  test "deployment, nodes, and unavailable node-backed routes keep their contracts", context do
    deployment = get(api_conn(context.bearer_token), "/api/deployment")

    assert json_response(deployment, 200) == %{
             "publication_domain" => "env.test",
             "ssh" => %{"host" => "localhost", "port" => 22}
           }

    nodes = get(api_conn(context.bearer_token), "/api/nodes")

    assert [%{"id" => node_id, "status" => "enabled", "assigned_biots" => 1}] =
             json_response(nodes, 200)

    assert node_id == to_string(context.node.id)

    secret_value = "secret-value-that-must-not-be-returned"

    secret =
      api_conn(context.bearer_token)
      |> json_request(:put, "/api/biots/#{context.biot.id}/secrets/API_TOKEN", %{
        "value" => secret_value
      })

    assert json_response(secret, 503) == %{"error" => "temporarily_unavailable"}
    refute secret.resp_body =~ secret_value

    secrets = get(api_conn(context.bearer_token), "/api/biots/#{context.biot.id}/secrets")
    assert json_response(secrets, 503) == %{"error" => "temporarily_unavailable"}

    bad_logs =
      get(api_conn(context.bearer_token), "/api/biots/#{context.biot.id}/logs?max_bytes=0")

    assert json_response(bad_logs, 422)["fields"] == %{"max_bytes" => ["out_of_range"]}
  end

  defp request(conn, "GET", path), do: get(conn, path)
  defp request(conn, "DELETE", path), do: delete(conn, path)
  defp request(conn, "POST", path), do: json_request(conn, :post, path, %{})
  defp request(conn, "PUT", path), do: json_request(conn, :put, path, %{})
end
