defmodule Biot.Server.BiotControllerLinuxIntegrationTest do
  @moduledoc false
  use ExUnit.Case, async: false

  @moduletag :linux
  @moduletag :nix
  @moduletag timeout: 2_400_000

  test "the controller survives crashes, cancellation, retries, reconnects, and orphaning" do
    project_root = Path.expand("../../..", __DIR__)
    runner = Path.join(__DIR__, "support/step9_controller_runner.exs")

    database =
      Path.join(System.tmp_dir!(), "step9-server-#{System.unique_integer([:positive])}.sqlite3")

    on_exit(fn -> File.rm(database) end)

    {output, status} =
      System.cmd("mix", ["run", "--no-start", runner],
        cd: project_root,
        env: [{"BIOT_STEP9_TEST_DATABASE", database}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "step 9 controller proof passed"
    assert output =~ "those processes gone after the controller was killed: true"
    assert output =~ "nix build processes after the cancellation: 0"
    assert output =~ "processes after the caller was killed: 0"
    assert output =~ "allocation kept, not adopted or deleted: true"

    assert [first_delay, second_delay | _rest] =
             Regex.scan(~r/running again (\d+) ms later/, output, capture: :all_but_first)
             |> Enum.map(fn [delay] -> String.to_integer(delay) end)

    assert first_delay >= 1_500
    assert second_delay >= 3_500

    assert [cancel_ms] =
             Regex.run(~r/destroyed after \(ms\): (\d+)/, output, capture: :all_but_first)

    assert String.to_integer(cancel_ms) < 5_000
  end
end
