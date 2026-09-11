defmodule Biot.Protocol.SecretValuesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Biot.Protocol.AuthorizationValue
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.Limits
  alias Biot.Protocol.Message
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SecretName
  alias Biot.Protocol.SecretOutcome
  alias Biot.Protocol.SecretValue
  alias Biot.Protocol.Wire

  @version 1
  @max Limits.max_secret_value_bytes(1)
  @secret "correct-horse-battery-staple"

  describe "SecretName.parse/1" do
    test "accepts the names an environment can hold" do
      for value <- ~w(A A1 DATABASE_URL X_ A_1_B) do
        assert {:ok, %SecretName{value: ^value}} = SecretName.parse(value)
      end
    end

    test "refuses lowercase, a leading digit, a leading underscore, and an empty name" do
      invalid = ["database_url", "Database", "1ABC", "_ABC", "", " A", "A B", "A-B", "Å"]

      for value <- invalid do
        assert SecretName.parse(value) == {:error, :invalid_format},
               "expected #{inspect(value)} to be refused"
      end
    end

    test "refuses exactly the four names the launcher and the agent reserve" do
      assert SecretName.reserved() == ~w(BIOT_CONFIG_ROOT HOME PATH TERM)

      for name <- SecretName.reserved() do
        assert SecretName.parse(name) == {:error, :reserved_name}
      end
    end

    property "an uppercase name round-trips and every reserved name is refused" do
      check all(
              head <- StreamData.string(?A..?Z, length: 1),
              tail <-
                StreamData.list_of(
                  StreamData.member_of(Enum.to_list(?A..?Z) ++ Enum.to_list(?0..?9) ++ [?_]),
                  max_length: 20
                )
            ) do
        value = head <> List.to_string(tail)

        case SecretName.parse(value) do
          {:ok, name} -> assert SecretName.to_string(name) == value
          {:error, :reserved_name} -> assert value in SecretName.reserved()
        end
      end
    end

    property "a name with any byte outside the alphabet is refused" do
      check all(
              value <- StreamData.string(:printable, min_length: 1, max_length: 24),
              not Regex.match?(~r/\A[A-Z][A-Z0-9_]*\z/, value)
            ) do
        assert SecretName.parse(value) == {:error, :invalid_format}
      end
    end

    property "a name that is not a binary is refused rather than raising" do
      check all(value <- non_binary_term()) do
        assert SecretName.parse(value) == {:error, :invalid_format}
      end
    end
  end

  describe "SecretValue.parse/2" do
    test "accepts the bytes an environment variable can hold" do
      accepted = [
        "",
        "plain",
        "two\nlines",
        "trailing\n",
        "trailing\n\n\n",
        <<0xFF, 0xFE, 0xFD>>,
        String.duplicate("a", @max)
      ]

      for value <- accepted do
        assert {:ok, parsed} = SecretValue.parse(value, @version)
        assert SecretValue.reveal(parsed) == value
      end
    end

    test "refuses a NUL byte wherever it sits" do
      for value <- [<<0>>, <<0, ?a>>, <<?a, 0>>, <<?a, 0, ?b>>] do
        assert SecretValue.parse(value, @version) == {:error, :nul_byte}
      end
    end

    test "accepts exactly the bound and refuses one byte over it" do
      assert {:ok, _value} = SecretValue.parse(:binary.copy(<<?a>>, @max), @version)

      assert SecretValue.parse(:binary.copy(<<?a>>, @max + 1), @version) ==
               {:error, :secret_value_too_large}
    end

    test "refuses a term that is not a binary" do
      assert SecretValue.parse(nil, @version) == {:error, :invalid_format}
      assert SecretValue.parse(42, @version) == {:error, :invalid_format}
    end

    property "any binary without a NUL under the bound round-trips" do
      check all(value <- StreamData.binary(max_length: 256)) do
        case SecretValue.parse(value, @version) do
          {:ok, parsed} ->
            refute String.contains?(value, <<0>>)
            assert SecretValue.reveal(parsed) == value

          {:error, :nul_byte} ->
            assert String.contains?(value, <<0>>)
        end
      end
    end
  end

  describe "AuthorizationValue.parse/2" do
    test "accepts one HTTP field value" do
      accepted = ["Bearer abc", "token", "Basic dXNlcjpwYXNz", "a b\tc", "x" <> "!" <> "~"]

      for value <- accepted do
        assert {:ok, parsed} = AuthorizationValue.parse(value, @version)
        assert AuthorizationValue.reveal(parsed) == value
      end
    end

    test "refuses control characters, an empty value, and padding whitespace" do
      invalid = [
        "",
        " ",
        "\t",
        " Bearer abc",
        "Bearer abc ",
        "Bearer\nabc",
        "Bearer\rabc",
        "Bearer abc\n",
        "Bearer" <> <<0>> <> "abc",
        "Bearer" <> <<0x7F>> <> "abc"
      ]

      for value <- invalid do
        assert AuthorizationValue.parse(value, @version) == {:error, :invalid_format},
               "expected #{inspect(value)} to be refused"
      end
    end

    test "refuses a value over the bound and a term that is not a binary" do
      assert AuthorizationValue.parse(:binary.copy(<<?a>>, @max + 1), @version) ==
               {:error, :secret_value_too_large}

      assert AuthorizationValue.parse(nil, @version) == {:error, :invalid_format}
    end

    # Tab is the one character below 0x20 an HTTP field value may hold, so it is the one the
    # generator leaves out; every other control character has to be refused.
    property "a value containing any control character but tab is refused" do
      check all(
              prefix <- StreamData.string(?a..?z, min_length: 1, max_length: 8),
              control <- StreamData.member_of(Enum.to_list(0..8) ++ Enum.to_list(10..31) ++ [127]),
              suffix <- StreamData.string(?a..?z, min_length: 1, max_length: 8)
            ) do
        value = prefix <> <<control>> <> suffix
        assert AuthorizationValue.parse(value, @version) == {:error, :invalid_format}
      end
    end
  end

  describe "redaction" do
    test "inspecting either value prints no byte of it" do
      {:ok, secret} = SecretValue.parse(@secret, @version)
      {:ok, authorization} = AuthorizationValue.parse("Bearer " <> @secret, @version)

      refute inspect(secret) =~ @secret
      refute inspect(authorization) =~ @secret
      refute inspect(secret, limit: :infinity, printable_limit: :infinity) =~ @secret
      refute inspect(%{held: [secret, authorization]}) =~ @secret
    end

    test "inspecting any message carrying a value prints no byte of it" do
      for message <- value_carrying_messages() do
        refute inspect(message, limit: :infinity, printable_limit: :infinity) =~ @secret
      end
    end

    test "a decode error names the field and never the value" do
      {:ok, encoded} = Wire.encode(deliver_secret(), @version)
      damaged = encoded |> Jason.decode!() |> Map.put("name", "lowercase") |> Jason.encode!()

      assert {:error, reason} = Wire.decode(damaged, @version)
      refute inspect(reason) =~ @secret
    end
  end

  describe "SecretOutcome codecs" do
    test "every outcome round-trips" do
      {:ok, name} = SecretName.parse("ONE")
      outcomes = [:ok, :no_allocation, {:failure, :write_failed}, {:failure, :unavailable}]

      # A listing that succeeded carries names; the two codecs agree on every other outcome.
      listings = [
        {:ok, [name]},
        :no_allocation,
        {:failure, :write_failed},
        {:failure, :unavailable}
      ]

      assert SecretOutcome.codes() == [:write_failed, :unavailable]

      for outcome <- outcomes do
        assert outcome |> SecretOutcome.encode() |> SecretOutcome.parse() == {:ok, outcome}
      end

      for listing <- listings do
        assert listing |> SecretOutcome.encode_listing() |> SecretOutcome.parse_listing() ==
                 {:ok, listing}
      end
    end

    test "a listing round-trips its names and rejects an unparsable one" do
      {:ok, one} = SecretName.parse("ONE")
      {:ok, two} = SecretName.parse("TWO")

      listing = {:ok, [one, two]}

      assert listing |> SecretOutcome.encode_listing() |> SecretOutcome.parse_listing() ==
               {:ok, listing}

      assert SecretOutcome.parse_listing(%{"status" => "ok", "names" => ["lowercase"]}) ==
               {:error, :invalid_format}

      assert SecretOutcome.parse_listing(%{"status" => "ok", "names" => ["HOME"]}) ==
               {:error, :invalid_format}

      assert SecretOutcome.parse_listing(%{"status" => "ok", "names" => "ONE"}) ==
               {:error, :invalid_format}
    end

    test "unknown statuses, unknown codes, and extra keys are refused" do
      invalid = [
        %{"status" => "unknown"},
        %{"status" => "failure"},
        %{"status" => "failure", "code" => "exploded"},
        %{"status" => "failure", "code" => 1},
        %{"status" => "ok", "extra" => true},
        %{"status" => "no_allocation", "code" => "write_failed"},
        %{"status" => "failure", "code" => "write_failed", "extra" => true},
        %{},
        "ok",
        nil
      ]

      for value <- invalid do
        assert SecretOutcome.parse(value) == {:error, :invalid_format},
               "expected #{inspect(value)} to be refused by parse/1"

        assert SecretOutcome.parse_listing(value) == {:error, :invalid_format},
               "expected #{inspect(value)} to be refused by parse_listing/1"
      end
    end

    test "a plain outcome carries no names and a listing needs them" do
      assert SecretOutcome.parse(%{"status" => "ok", "names" => []}) == {:error, :invalid_format}
      assert SecretOutcome.parse_listing(%{"status" => "ok"}) == {:error, :invalid_format}
    end
  end

  describe "the five request and three result messages" do
    test "each round-trips through version 1 and is unknown at handshake" do
      for message <- step_18_messages() do
        assert {:ok, encoded} = Wire.encode(message, @version)
        assert Wire.decode(encoded, @version) == {:ok, message}
        assert Wire.decode(encoded, :handshake) == {:error, :unknown_message_type}
      end
    end

    test "a result decoded with the wrong result kind is refused" do
      {:ok, encoded} = Wire.encode(%Message.SecretResult{request_id: "r", result: :ok}, @version)

      assert {:error, {:invalid_message, :result}} =
               encoded
               |> Jason.decode!()
               |> Map.put("result", %{"status" => "ok", "names" => ["ONE"]})
               |> Jason.encode!()
               |> Wire.decode(@version)

      {:ok, list_encoded} =
        Wire.encode(%Message.SecretListResult{request_id: "r", result: {:ok, []}}, @version)

      assert {:error, {:invalid_message, :result}} =
               list_encoded
               |> Jason.decode!()
               |> Map.put("type", "secret_result")
               |> Jason.encode!()
               |> Wire.decode(@version)
    end

    test "a delivered value that is not base64, too large, or holds a NUL is refused" do
      {:ok, encoded} = Wire.encode(deliver_secret(), @version)
      decoded = Jason.decode!(encoded)

      assert {:error, {:invalid_message, :value}} =
               decoded |> Map.put("value", "not base64!") |> Jason.encode!() |> Wire.decode(1)

      assert {:error, {:invalid_message, :value}} =
               decoded
               |> Map.put("value", Base.encode64(<<?a, 0, ?b>>))
               |> Jason.encode!()
               |> Wire.decode(1)

      assert {:error, :secret_value_too_large} =
               decoded
               |> Map.put("value", Base.encode64(:binary.copy(<<?a>>, @max + 1)))
               |> Jason.encode!()
               |> Wire.decode(1)
    end

    test "a delivered authorization value that is not a field value is refused" do
      {:ok, encoded} = Wire.encode(deliver_credential(), @version)
      decoded = Jason.decode!(encoded)

      assert {:error, {:invalid_message, :value}} =
               decoded
               |> Map.put("value", Base.encode64("Bearer\nabc"))
               |> Jason.encode!()
               |> Wire.decode(1)
    end

    test "a reserved secret name and a non-HTTPS source are refused at the boundary" do
      {:ok, encoded} = Wire.encode(deliver_secret(), @version)

      assert {:error, {:invalid_message, :name}} =
               encoded
               |> Jason.decode!()
               |> Map.put("name", "PATH")
               |> Jason.encode!()
               |> Wire.decode(1)

      {:ok, credential} = Wire.encode(deliver_credential(), @version)

      assert {:error, {:invalid_message, :source}} =
               credential
               |> Jason.decode!()
               |> Map.put("source", "ssh://host/repo.git")
               |> Jason.encode!()
               |> Wire.decode(1)
    end

    # `value` is left out here and tested on its own below, because the codec raises on it rather
    # than returning an error and a raise would end this loop before the other fields are checked.
    test "each refuses an unknown, a missing, and a wrongly typed field" do
      for message <- step_18_messages() do
        {:ok, encoded} = Wire.encode(message, @version)
        decoded = Jason.decode!(encoded)

        assert {:error, _unknown} =
                 decoded |> Map.put("unknown", true) |> Jason.encode!() |> Wire.decode(@version)

        for field <- Map.keys(decoded) -- ["type", "value"] do
          assert {:error, _missing} =
                   decoded |> Map.delete(field) |> Jason.encode!() |> Wire.decode(@version)

          assert {:error, _wrong} =
                   decoded
                   |> Map.put(field, wrong_value(decoded[field]))
                   |> Jason.encode!()
                   |> Wire.decode(@version)
        end
      end
    end

    test "a delivered value that is not a JSON string is refused rather than raising" do
      for message <- value_carrying_messages() do
        {:ok, encoded} = Wire.encode(message, @version)
        decoded = Jason.decode!(encoded)

        for wrong <- [42, true, nil, [], %{}] do
          assert {:error, {:invalid_message, :value}} =
                   decoded |> Map.put("value", wrong) |> Jason.encode!() |> Wire.decode(@version)
        end
      end
    end

    test "a timeout that is not a positive integer is refused" do
      {:ok, encoded} = Wire.encode(deliver_secret(), @version)
      decoded = Jason.decode!(encoded)

      for value <- [0, -1, "200", 1.5, nil] do
        assert {:error, {:invalid_message, :timeout_ms}} =
                 decoded |> Map.put("timeout_ms", value) |> Jason.encode!() |> Wire.decode(1)
      end
    end
  end

  describe "Wire.min_frame_bytes/1" do
    test "covers the base64 of a maximum value plus its envelope" do
      {:ok, encoded} =
        Wire.encode(
          %Message.DeliverSecret{
            request_id: String.duplicate("r", 64),
            biot_id: biot_id(),
            name: name("A_VERY_LONG_SECRET_NAME_INDEED"),
            value: secret_value(:binary.copy(<<?a>>, @max)),
            timeout_ms: 60_000
          },
          @version
        )

      assert Wire.min_frame_bytes(@version) >= byte_size(encoded)
      assert Wire.check_frame_limit!(Wire.min_frame_bytes(@version)) == :ok

      assert_raise RuntimeError, fn ->
        Wire.check_frame_limit!(Wire.min_frame_bytes(@version) - 1)
      end
    end
  end

  defp value_carrying_messages do
    [deliver_secret(), deliver_credential()]
  end

  defp step_18_messages do
    {:ok, one} = SecretName.parse("ONE")
    {:ok, two} = SecretName.parse("TWO")

    [
      deliver_secret(),
      %Message.RemoveSecret{
        request_id: "r2",
        biot_id: biot_id(),
        name: name("DATABASE_URL"),
        timeout_ms: 1_000
      },
      %Message.ListSecrets{request_id: "r3", biot_id: biot_id(), timeout_ms: 1_000},
      deliver_credential(),
      %Message.RemoveFetchCredential{
        request_id: "r5",
        biot_id: biot_id(),
        source: source(),
        timeout_ms: 1_000
      },
      %Message.SecretResult{request_id: "r6", result: :ok},
      %Message.SecretResult{request_id: "r6", result: :no_allocation},
      %Message.SecretResult{request_id: "r6", result: {:failure, :write_failed}},
      %Message.SecretListResult{request_id: "r7", result: {:ok, [one, two]}},
      %Message.SecretListResult{request_id: "r7", result: {:ok, []}},
      %Message.SecretListResult{request_id: "r7", result: :no_allocation},
      %Message.FetchCredentialResult{request_id: "r8", result: {:failure, :unavailable}}
    ]
  end

  defp deliver_secret do
    %Message.DeliverSecret{
      request_id: "r1",
      biot_id: biot_id(),
      name: name("DATABASE_URL"),
      value: secret_value(@secret),
      timeout_ms: 1_000
    }
  end

  defp deliver_credential do
    %Message.DeliverFetchCredential{
      request_id: "r4",
      biot_id: biot_id(),
      source: source(),
      value: authorization_value("Bearer " <> @secret),
      timeout_ms: 1_000
    }
  end

  defp name(value) do
    {:ok, name} = SecretName.parse(value)
    name
  end

  defp secret_value(value) do
    {:ok, parsed} = SecretValue.parse(value, @version)
    parsed
  end

  defp authorization_value(value) do
    {:ok, parsed} = AuthorizationValue.parse(value, @version)
    parsed
  end

  defp source do
    {:ok, source} = RepositorySource.parse("https://example.test/private.git")
    source
  end

  defp biot_id do
    {:ok, biot_id} = BiotId.parse("00000000-0000-4000-8000-000000000003")
    biot_id
  end

  defp wrong_value(value) when is_binary(value), do: 42
  defp wrong_value(value) when is_integer(value), do: "wrong"
  defp wrong_value(value) when is_list(value), do: %{}
  defp wrong_value(value) when is_map(value), do: []
  defp wrong_value(value) when is_boolean(value), do: "wrong"
  defp wrong_value(nil), do: "wrong"

  defp non_binary_term do
    StreamData.one_of([
      StreamData.integer(),
      StreamData.float(),
      StreamData.list_of(StreamData.integer()),
      StreamData.member_of([nil, true, false, :value, [], {}, %{}])
    ])
  end
end
