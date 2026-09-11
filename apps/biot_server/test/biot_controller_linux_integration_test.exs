defmodule Biot.Server.BiotControllerLinuxIntegrationTest do
  @moduledoc false
  use ExUnit.Case, async: false

  # This single unlabelled result for dozens of assertions will be replaced by bounded per-contract tests.
  @moduletag :skip
  @moduletag :linux
  @moduletag :nix
  @moduletag timeout: 1_200_000

  test "the controller survives crashes, cancellation, retries, reconnects, and orphaning" do
    project_root = Path.expand("../../..", __DIR__)
    runner = Path.join(__DIR__, "support/step9_controller_runner.exs")

    database =
      Path.join(System.tmp_dir!(), "step9-server-#{System.unique_integer([:positive])}.sqlite3")

    proof_root =
      Path.join(System.tmp_dir!(), "step9-proof-#{System.unique_integer([:positive])}")

    proof_output = Path.join([project_root, ".work", "step15-controller-proof.log"])

    on_exit(fn ->
      File.rm(database)
      System.cmd("podman", ["unshare", "chown", "-R", "0:0", proof_root])
      File.rm_rf(proof_root)
    end)

    {_output, status} =
      System.cmd(
        "sh",
        [
          "-c",
          ~S(exec mix run --no-start "$1" >"$2" 2>&1),
          "step9-controller",
          runner,
          proof_output
        ],
        cd: project_root,
        env: [
          {"MIX_ENV", "test"},
          {"BIOT_STEP9_TEST_DATABASE", database},
          {"BIOT_STEP9_TEST_ROOT", proof_root}
        ],
        stderr_to_stdout: true
      )

    output = File.read!(proof_output)

    assert status == 0, output
    assert output =~ "step 9 controller proof passed"
    assert output =~ "step 14 controller proof passed"
    assert output =~ "those processes gone after the controller was killed: true"
    assert output =~ "nix build processes after the cancellation: 0"
    assert output =~ "processes after the caller was killed: 0"
    assert output =~ "allocation kept, not adopted or deleted: true"
    assert output =~ "attempt recorded before the action started: true"
    assert output =~ "attempt count unchanged while the controller restarted: true"
    assert output =~ "action_environments_exported: false"
    assert output =~ "action_requires_control_exported: false"

    assert output =~
             "actions_run: [:allocate, :initialize, :resolve, :prepare, :install, :start]"

    assert output =~ "first_reaches_itself: true"
    assert output =~ "second_reaches_itself: true"
    assert output =~ "first_reaches_second: false"
    assert output =~ "second_reaches_first: false"
    assert output =~ "reader_kept_its_pid_across_failed_opens: true"
    assert output =~ "reader_stream_after_podman_restored: true"
    assert output =~ "reader_survived_failed_opens: true"
    assert output =~ ~r/ended_streams_left_no_files_or_reaper_records:\s+true/
    assert output =~ "prepared: [desired: :present, sibling: :unknown]"
    assert output =~ "data_state_with_foreign_marker: :lost"
    assert output =~ "allocation_initialization: :complete"
    assert output =~ "same_attempts: true"
    assert output =~ "same_next_attempt_at: true"
    assert output =~ "distant_wait_within_maximum: true"
    assert output =~ "past_wake_skipped_backoff: true"
    assert output =~ "journal_row_after_superseded_result: nil"
    assert output =~ "result_reached_the_controller_before_the_notice: true"
    assert output =~ "actions_started_after_the_wake: []"
    assert output =~ ~r/diagnostic_entries_after: \[\s*%Biot\.Node\.Journal\.Schema\.Diagnostic\{/
    assert output =~ "outbox_report_matches: true"
    assert output =~ "child_restart: :transient"
    assert output =~ "replay_when_ready: {true, true}"
    assert output =~ "replay_after_desired: {true, true}"
    assert output =~ "controller_started_for_stored_report: 0"
    assert output =~ "intent_after_omission: nil"
    assert output =~ "step 15 runtime logs"
    assert output =~ "before_restart_exact: true"
    assert output =~ "restart_kept_incarnation: true"
    assert output =~ "restart_marked_gap: true"
    assert output =~ "capture_stayed_bounded: true"
    assert output =~ "failed_start_failed: true"
    assert output =~ "failed_start_kept_log: true"
    assert output =~ "failed_start_kept_metadata: true"
    assert output =~ "new_incarnation: true"
    assert output =~ "new_log_replaced_old: true"

    assert [first_delay | _rest] =
             Regex.scan(~r/running again (\d+) ms later/, output, capture: :all_but_first)
             |> Enum.map(fn [delay] -> String.to_integer(delay) end)

    assert first_delay >= 1_500

    assert [cancel_ms] =
             Regex.run(~r/destroyed after \(ms\): (\d+)/, output, capture: :all_but_first)

    assert String.to_integer(cancel_ms) < 5_000
  end
end
