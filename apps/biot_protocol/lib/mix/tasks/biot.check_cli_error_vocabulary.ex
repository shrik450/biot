defmodule Mix.Tasks.Biot.CheckCliErrorVocabulary do
  @moduledoc """
  Checks the generated CLI error vocabulary against the server vocabularies.

  `cli/internal/api/error_vocabulary.txt` is generated from `Biot.Protocol.FieldReason` and
  `Biot.Server.CommandError` together with the facts and remedy coverage owned by
  `BiotWeb.UserMessage`. `cli/internal/api/field_labels.txt` is generated from the same module's
  human field labels. Run this task with `--write` after changing either vocabulary or its
  user-facing wording.
  """

  @shortdoc "Checks the generated CLI error vocabulary against the server"

  use Mix.Task

  alias Biot.Protocol.{BiotName, FieldReason, Limits}

  @repo_root Path.expand("../../../../..", __DIR__)
  @artifact_file Path.join(@repo_root, "cli/internal/api/error_vocabulary.txt")
  @labels_file Path.join(@repo_root, "cli/internal/api/field_labels.txt")
  @separator "|"
  @template_placeholders %{revision_conflict: ["revision"]}

  @impl Mix.Task
  def run(args) do
    recompile!()
    expected = expected_contents()
    expected_labels = expected_label_contents()

    case args do
      [] ->
        check_contents!(@artifact_file, expected, "CLI error vocabulary")
        check_contents!(@labels_file, expected_labels, "CLI field labels")
        Mix.shell().info("CLI error vocabulary and field labels match the server")

      ["--write"] ->
        write_contents!(@artifact_file, expected)
        write_contents!(@labels_file, expected_labels)

      _other ->
        Mix.raise("expected no arguments or --write")
    end
  end

  defp recompile! do
    Mix.Task.reenable("compile")
    Mix.Task.run("compile", ["--force"])
  end

  defp expected_contents do
    field_sentences = :erlang.apply(BiotWeb.UserMessage, :field_reason_sentences, [])
    command_reasons = :erlang.apply(Biot.Server.CommandError, :all, [])
    command_sentences = :erlang.apply(BiotWeb.UserMessage, :command_error_sentences, [])
    client_remedies = :erlang.apply(BiotWeb.UserMessage, :client_remedies, [])

    field_lines =
      FieldReason.all()
      |> Enum.map(fn reason ->
        entry(
          reason,
          "field",
          field_limit(reason),
          Map.fetch!(field_sentences, reason),
          Map.has_key?(client_remedies, reason)
        )
      end)

    command_lines =
      command_reasons
      |> Enum.map(fn reason ->
        entry(
          reason,
          "command",
          0,
          Map.fetch!(command_sentences, reason),
          Map.has_key?(client_remedies, reason)
        )
      end)

    (field_lines ++ command_lines)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("\n", &format_entry/1)
    |> Kernel.<>("\n")
  end

  defp expected_label_contents do
    field_labels = :erlang.apply(BiotWeb.UserMessage, :field_labels, [])

    field_labels
    |> Enum.map(fn {field, label} ->
      field = Atom.to_string(field)

      if Enum.any?([field, label], &String.contains?(&1, [@separator, "\n", "\r"])) do
        Mix.raise("CLI field label values cannot contain #{inspect(@separator)}: #{field}")
      end

      {field, label}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("\n", fn {field, label} -> field <> @separator <> label end)
    |> Kernel.<>("\n")
  end

  defp entry(reason, kind, limit, sentence, remedy?) do
    reason_name = Atom.to_string(reason)
    validate_template!(reason, sentence)

    if Enum.any?([reason_name, kind, sentence], &String.contains?(&1, [@separator, "\n", "\r"])) do
      Mix.raise("CLI vocabulary values cannot contain #{inspect(@separator)}: #{reason_name}")
    end

    {reason_name, kind, limit, sentence, if(remedy?, do: "required", else: "none")}
  end

  defp validate_template!(reason, sentence) do
    placeholders =
      Regex.scan(~r/\{([a-z_][a-z0-9_]*)\}/, sentence, capture: :all_but_first)
      |> List.flatten()

    expected = Map.get(@template_placeholders, reason, [])

    if placeholders != expected or String.count(sentence, "{") != Enum.count(placeholders) or
         String.count(sentence, "}") != Enum.count(placeholders) do
      Mix.raise(
        "CLI vocabulary has unexpected placeholders for #{reason}: #{inspect(placeholders)}"
      )
    end
  end

  defp field_limit(:name_too_long), do: BiotName.max_length()
  defp field_limit(:repository_url_too_long), do: Limits.max_repository_url_bytes()
  defp field_limit(:source_ref_too_long), do: Limits.max_source_ref_bytes()
  defp field_limit(:secret_value_too_large), do: Limits.max_secret_value_bytes(1)
  defp field_limit(:too_many_layers), do: Limits.max_layers()
  defp field_limit(_reason), do: 0

  defp format_entry({reason, kind, limit, sentence, remedy}),
    do: Enum.join([reason, kind, Integer.to_string(limit), sentence, remedy], @separator)

  defp check_contents!(path, expected, description) do
    actual = read_contents!(path)

    if actual != expected do
      Mix.raise(
        "#{description} artifact is out of date; run mix biot.check_cli_error_vocabulary --write\n" <>
          unified_diff(expected, actual)
      )
    end
  end

  defp write_contents!(path, expected) do
    case File.write(path, expected) do
      :ok ->
        Mix.shell().info("wrote #{path}")

      {:error, reason} ->
        Mix.raise("could not write #{path}: #{:file.format_error(reason)}")
    end
  end

  defp read_contents!(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, reason} -> Mix.raise("could not read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp unified_diff(expected, actual) do
    expected_lines = String.split(expected, "\n", trim: false)
    actual_lines = String.split(actual, "\n", trim: false)

    expected_lines
    |> List.myers_difference(actual_lines)
    |> Enum.flat_map(fn {kind, lines} -> Enum.map(lines, &diff_line(kind, &1)) end)
    |> Enum.join("\n")
  end

  defp diff_line(:eq, line), do: "  " <> line
  defp diff_line(:del, line), do: "- " <> line
  defp diff_line(:ins, line), do: "+ " <> line
end
