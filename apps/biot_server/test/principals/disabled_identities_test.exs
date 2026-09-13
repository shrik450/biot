defmodule Biot.Server.Principals.DisabledIdentitiesTest do
  use ExUnit.Case, async: false

  alias Biot.Server.Principals.DisabledIdentities
  alias Biot.Server.Principals.DisabledIdentities.Identity

  setup do
    Application.delete_env(:biot_server, :disabled_principals)
    Application.delete_env(:biot_server, :disabled_principals_file)

    on_exit(fn ->
      Application.delete_env(:biot_server, :disabled_principals)
      Application.delete_env(:biot_server, :disabled_principals_file)
    end)

    :ok
  end

  defp put_identities(identities) do
    Application.put_env(:biot_server, :disabled_principals, identities)
  end

  defp tmp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "biot-disabled-#{name}-#{System.unique_integer([:positive])}.json"
    )
  end

  test "an absent configuration disables nobody" do
    assert DisabledIdentities.load() == {:ok, []}
  end

  test "an empty list disables nobody" do
    put_identities([])
    assert DisabledIdentities.load() == {:ok, []}
  end

  test "string keys and atom keys both parse" do
    put_identities([
      %{"issuer" => "a", "subject" => "1"},
      %{issuer: "b", subject: "2"}
    ])

    assert DisabledIdentities.load() ==
             {:ok, [%Identity{issuer: "a", subject: "1"}, %Identity{issuer: "b", subject: "2"}]}
  end

  test "an already parsed identity passes through" do
    identity = %Identity{issuer: "a", subject: "1"}
    put_identities([identity])
    assert DisabledIdentities.load() == {:ok, [identity]}
  end

  test "a repeated identity is returned twice by the parser" do
    identity = %Identity{issuer: "a", subject: "1"}
    put_identities([identity, identity])
    assert DisabledIdentities.load() == {:ok, [identity, identity]}
  end

  test "a malformed map element reports its index" do
    cases = [
      {%{}, {:identity, 0, {:issuer, :missing}}},
      {%{"issuer" => "a"}, {:identity, 0, {:subject, :missing}}},
      {%{"issuer" => "", "subject" => "1"}, {:identity, 0, {:issuer, :invalid_format}}},
      {%{"issuer" => "a", "subject" => nil}, {:identity, 0, {:subject, :invalid_format}}},
      {%{"issuer" => 1, "subject" => "1"}, {:identity, 0, {:issuer, :invalid_format}}}
    ]

    for {element, expected} <- cases do
      put_identities([element])
      assert DisabledIdentities.load() == {:error, expected}
    end
  end

  test "a non-map element is rejected with its index, not raised" do
    for element <- ["not a map", [], nil, 1] do
      put_identities([element])
      assert DisabledIdentities.load() == {:error, {:identity, 0, :invalid_format}}
    end
  end

  test "an unknown key is ignored" do
    put_identities([%{"issuer" => "a", "subject" => "1", "extra" => true}])
    assert DisabledIdentities.load() == {:ok, [%Identity{issuer: "a", subject: "1"}]}
  end

  test "the second malformed element reports index one" do
    put_identities([%{"issuer" => "a", "subject" => "1"}, %{"issuer" => "b"}])
    assert DisabledIdentities.load() == {:error, {:identity, 1, {:subject, :missing}}}
  end

  test "a non-list configuration is rejected" do
    for value <- [%{"issuer" => "a"}, "text", 1, nil, true] do
      put_identities(value)
      assert DisabledIdentities.load() == {:error, :identities_must_be_a_list}
    end
  end

  test "a JSON file with identities loads" do
    path = tmp_path("good")
    File.write!(path, Jason.encode!([%{"issuer" => "a", "subject" => "1"}]))
    Application.put_env(:biot_server, :disabled_principals_file, path)

    assert DisabledIdentities.load() == {:ok, [%Identity{issuer: "a", subject: "1"}]}
  end

  test "a missing file reports a typed file error" do
    path = tmp_path("missing")
    Application.put_env(:biot_server, :disabled_principals_file, path)

    assert {:error, {:file, ^path, :enoent}} = DisabledIdentities.load()
  end

  test "an invalid JSON file reports a typed JSON error" do
    path = tmp_path("bad-json")
    File.write!(path, "{not json")
    Application.put_env(:biot_server, :disabled_principals_file, path)

    assert {:error, {:invalid_json, message}} = DisabledIdentities.load()
    assert is_binary(message)
  end

  test "an empty path is invalid and a non-binary path is rejected" do
    Application.put_env(:biot_server, :disabled_principals_file, "")
    assert DisabledIdentities.load() == {:error, {:invalid_path, ""}}

    Application.put_env(:biot_server, :disabled_principals_file, 42)
    assert DisabledIdentities.load() == {:error, {:invalid_path, 42}}
  end

  test "the in-memory list wins over the file" do
    path = tmp_path("ignored")
    File.write!(path, Jason.encode!([%{"issuer" => "file", "subject" => "1"}]))
    Application.put_env(:biot_server, :disabled_principals_file, path)
    put_identities([%{"issuer" => "memory", "subject" => "1"}])

    assert DisabledIdentities.load() == {:ok, [%Identity{issuer: "memory", subject: "1"}]}
  end

  test "every rejection has a readable message" do
    errors = [
      :identities_must_be_a_list,
      {:invalid_path, 42},
      {:file, "/tmp/x", :enoent},
      {:invalid_json, "boom"},
      {:identity, 3, :invalid_format},
      {:identity, 3, {:issuer, :missing}},
      {:identity, 3, {:subject, :invalid_format}}
    ]

    for error <- errors do
      message = DisabledIdentities.message(error)
      assert is_binary(message)
      assert message != ""
    end
  end
end
