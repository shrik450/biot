defmodule Mix.Tasks.Biot.CheckCliErrorVocabulary do
  @moduledoc """
  Checks the generated CLI error vocabulary against the server vocabularies.

  `cli/internal/api/error_vocabulary.txt` is generated from `Biot.Protocol.FieldReason` and
  `Biot.Server.CommandError` together with the facts and remedy coverage owned by
  `BiotWeb.UserMessage`. Run this task with `--write` after changing either vocabulary or its
  user-facing wording.
  """

  @shortdoc "Checks the generated CLI error vocabulary against the server"

  use Mix.Task

  alias Biot.Protocol.{BiotName, FieldReason, Limits}

  @repo_root Path.expand("../../../../..", __DIR__)
  @artifact_file Path.join(@repo_root, "cli/internal/api/error_vocabulary.txt")
  @separator "|"
  @template_placeholders %{revision_conflict: ["revision"]}

  @impl Mix.Task
  def run(args) do
    recompile!()
    expected = expected_contents()

    case args do
      [] -> check_contents!(expected)
      ["--write"] -> write_contents!(expected)
      _other -> Mix.raise("expected no arguments or --write")
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

  defp check_contents!(expected) do
    actual = read_contents!()

    if actual != expected do
      Mix.raise(
        "CLI error vocabulary artifact is out of date; run mix biot.check_cli_error_vocabulary --write\n" <>
          unified_diff(expected, actual)
      )
    end

    Mix.shell().info(
      "CLI error vocabulary matches the server (#{length(FieldReason.all())} field reasons, " <>
        "#{length(:erlang.apply(Biot.Server.CommandError, :all, []))} command errors)"
    )
  end

  defp write_contents!(expected) do
    case File.write(@artifact_file, expected) do
      :ok ->
        Mix.shell().info("wrote #{@artifact_file}")

      {:error, reason} ->
        Mix.raise("could not write #{@artifact_file}: #{:file.format_error(reason)}")
    end
  end

  defp read_contents! do
    case File.read(@artifact_file) do
      {:ok, contents} ->
        contents

      {:error, reason} ->
        Mix.raise("could not read #{@artifact_file}: #{:file.format_error(reason)}")
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
