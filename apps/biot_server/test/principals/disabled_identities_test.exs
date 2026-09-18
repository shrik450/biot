defmodule Biot.Server.Principals.DisabledIdentitiesTest do
  use ExUnit.Case, async: false

  alias Biot.Server.Principals.DisabledIdentities
  alias Biot.Server.Principals.DisabledIdentities.Identity
  alias Biot.Server.TestFixtures

  setup do
    Application.delete_env(:biot_server, :disabled_principals_file)
    on_exit(fn -> Application.delete_env(:biot_server, :disabled_principals_file) end)
    :ok
  end

  test "an unset file disables nobody" do
    assert DisabledIdentities.load() == {:ok, []}
  end

  test "an empty list disables nobody" do
    TestFixtures.put_disabled_principals([])
    assert DisabledIdentities.load() == {:ok, []}
  end

  test "identities parse in order, repeats included" do
    TestFixtures.put_disabled_principals([
      %{"issuer" => "a", "subject" => "1"},
      %{"issuer" => "b", "subject" => "2"},
      %{"issuer" => "a", "subject" => "1"}
    ])

    assert DisabledIdentities.load() ==
             {:ok,
              [
                %Identity{issuer: "a", subject: "1"},
                %Identity{issuer: "b", subject: "2"},
                %Identity{issuer: "a", subject: "1"}
              ]}
  end

  test "a malformed element reports its index and field" do
    cases = [
      {%{}, {:entry, 0, {:issuer, :missing}}},
      {%{"issuer" => "a"}, {:entry, 0, {:subject, :missing}}},
      {%{"issuer" => "", "subject" => "1"}, {:entry, 0, {:issuer, :invalid_format}}},
      {%{"issuer" => "a", "subject" => nil}, {:entry, 0, {:subject, :invalid_format}}},
      {%{"issuer" => 1, "subject" => "1"}, {:entry, 0, {:issuer, :invalid_format}}},
      {"not a map", {:entry, 0, :invalid_format}},
      {[], {:entry, 0, :invalid_format}},
      {nil, {:entry, 0, :invalid_format}}
    ]

    for {element, expected} <- cases do
      TestFixtures.put_disabled_principals([element])
      assert DisabledIdentities.load() == {:error, expected}
    end
  end

  test "an unknown key is ignored" do
    TestFixtures.put_disabled_principals([%{"issuer" => "a", "subject" => "1", "extra" => true}])
    assert DisabledIdentities.load() == {:ok, [%Identity{issuer: "a", subject: "1"}]}
  end

  test "the second malformed element reports index one" do
    TestFixtures.put_disabled_principals([
      %{"issuer" => "a", "subject" => "1"},
      %{"issuer" => "b"}
    ])

    assert DisabledIdentities.load() == {:error, {:entry, 1, {:subject, :missing}}}
  end

  test "a document that is not a list is rejected" do
    for value <- [%{"issuer" => "a"}, "text", 1, nil, true] do
      TestFixtures.put_disabled_principals(value)
      assert DisabledIdentities.load() == {:error, :not_a_list}
    end
  end

  test "a missing file and invalid JSON report typed errors" do
    path = BiotTest.Temp.directory("biot-missing")
    Application.put_env(:biot_server, :disabled_principals_file, path)
    assert {:error, {:file, ^path, :enoent}} = DisabledIdentities.load()

    File.write!(path, "{not json")
    assert {:error, {:invalid_json, message}} = DisabledIdentities.load()
    assert is_binary(message)
  end

  test "every rejection has a readable message" do
    errors = [
      :not_a_list,
      {:file, "/tmp/x", :enoent},
      {:invalid_json, "boom"},
      {:entry, 3, :invalid_format},
      {:entry, 3, {:issuer, :missing}}
    ]

    messages = Enum.map(errors, &DisabledIdentities.message/1)
    assert Enum.all?(messages, &(&1 =~ "disabled principals"))
    assert length(Enum.uniq(messages)) == length(errors)
  end
end
