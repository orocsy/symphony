defmodule SymphonyElixir.TokenTelemetryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TokenTelemetry

  test "calculates positive deltas from cumulative token usage" do
    previous = %{input_tokens: 100, cached_input_tokens: 60, output_tokens: 10, total_tokens: 110}
    current = %{input_tokens: 180, cached_input_tokens: 90, output_tokens: 25, total_tokens: 205}

    assert TokenTelemetry.delta_from_cumulative(previous, current) == %{
             input_tokens: 80,
             cached_input_tokens: 30,
             output_tokens: 15,
             total_tokens: 95
           }
  end

  test "redacts command details while keeping useful file fingerprints" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-token-telemetry-redaction-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join([workspace, "src", "app", "api"]))
      file = Path.join([workspace, "src", "app", "api", "secret.ts"])
      File.write!(file, "export const value = 1\n")

      summary =
        TokenTelemetry.command_summary(
          "sed -n '1,40p' #{file} --token sk_live_secret",
          workspace
        )

      assert summary.phase == "code_read"
      assert summary.files == ["src/app/api/secret.ts"]
      assert summary.command_fingerprint == "sed-read-src-app-api-secret.ts"
      refute summary.command_fingerprint =~ "sk_live"
      refute summary.command_fingerprint =~ "--token"
    after
      File.rm_rf(workspace)
    end
  end

  test "writes blocked summary when tokens have no durable progress" do
    workspace = temp_workspace("blocked-summary")

    try do
      telemetry = start_test_turn(workspace)
      observe_token_total(telemetry, 1_000)
      TokenTelemetry.stop(telemetry)

      summary = read_worker_summary!(workspace)

      assert summary["status"] == "blocked_no_durable_progress"
      assert summary["loop_signatures"] == ["no_durable_progress"]
      assert summary["total_tokens"] == 1_000
      assert summary["dirty_files"] == []
      assert summary["new_commits"] == []
      assert summary["durable_progress_events"] == []
      assert [%{"phase" => "startup", "total_tokens" => 1_000}] = summary["top_phases"]
    after
      File.rm_rf(workspace)
    end
  end

  test "classifies dirty workspace progress as productive" do
    workspace = temp_workspace("dirty-summary")

    try do
      init_git_repo!(workspace)
      telemetry = start_test_turn(workspace)
      File.write!(Path.join(workspace, "progress.txt"), "dirty progress\n")
      observe_token_total(telemetry, 2_000)
      TokenTelemetry.stop(telemetry)

      summary = read_worker_summary!(workspace)

      assert summary["status"] == "productive"
      assert summary["dirty_files"] == ["progress.txt"]
      assert summary["new_commits"] == []
    after
      File.rm_rf(workspace)
    end
  end

  test "classifies local commits before push as handoff recovery" do
    workspace = temp_workspace("commit-summary")

    try do
      init_git_repo!(workspace)
      git!(workspace, ["switch", "-c", "orocsy/mt-telemetry"])
      telemetry = start_test_turn(workspace)
      File.write!(Path.join(workspace, "feature.txt"), "committed progress\n")
      git!(workspace, ["add", "feature.txt"])
      git!(workspace, ["commit", "-m", "Add feature progress"])
      observe_token_total(telemetry, 3_000)
      TokenTelemetry.stop(telemetry)

      summary = read_worker_summary!(workspace)

      assert summary["status"] == "handoff_recovery"
      assert summary["dirty_files"] == []
      assert length(summary["new_commits"]) == 1
    after
      File.rm_rf(workspace)
    end
  end

  test "ignores stale previous-run Orocsy events" do
    workspace = temp_workspace("stale-event-summary")

    try do
      telemetry = start_test_turn(workspace)
      events_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(events_dir)

      File.write!(
        Path.join(events_dir, "events.jsonl"),
        Jason.encode!(%{
          "event" => "tool.finished",
          "status" => "passed",
          "tool" => "technical-miu-trace",
          "ts" => "2000-01-01T00:00:00Z"
        }) <> "\n"
      )

      observe_token_total(telemetry, 4_000)
      TokenTelemetry.stop(telemetry)

      summary = read_worker_summary!(workspace)

      assert summary["status"] == "blocked_no_durable_progress"
      assert summary["durable_progress_events"] == []
    after
      File.rm_rf(workspace)
    end
  end

  test "records loop signatures for repeated non-progress command phases" do
    cases = [
      {"sed -n '1,40p' src/app/page.tsx", "read_loop"},
      {"gh pr view 12 --json comments", "review_loop"},
      {"pnpm test", "validation_loop"},
      {"git status --short --branch", "handoff_loop"}
    ]

    for {command, expected_signature} <- cases do
      workspace = temp_workspace("loop-summary")

      try do
        telemetry = start_test_turn(workspace)
        observe_command(telemetry, command)
        observe_token_total(telemetry, 1_000)
        observe_command(telemetry, command)
        observe_token_total(telemetry, 2_000)
        TokenTelemetry.stop(telemetry)

        summary = read_worker_summary!(workspace)

        assert summary["status"] == "blocked_no_durable_progress"
        assert "no_durable_progress" in summary["loop_signatures"]
        assert expected_signature in summary["loop_signatures"]
      after
        File.rm_rf(workspace)
      end
    end
  end

  defp start_test_turn(workspace) do
    TokenTelemetry.start_turn(
      workspace,
      %{id: "issue-token-telemetry", identifier: "MT-93"},
      "thread-93",
      "turn-93"
    )
  end

  defp observe_command(telemetry, command) do
    TokenTelemetry.observe(telemetry, %{
      "method" => "codex/event/exec_command_begin",
      "params" => %{"msg" => %{"command" => command}}
    })
  end

  defp observe_token_total(telemetry, total_tokens) do
    TokenTelemetry.observe(telemetry, %{
      "method" => "thread/tokenUsage/updated",
      "params" => %{
        "tokenUsage" => %{
          "total" => %{
            "input_tokens" => total_tokens,
            "cached_input_tokens" => div(total_tokens, 2),
            "output_tokens" => 0,
            "total_tokens" => total_tokens
          }
        }
      }
    })
  end

  defp read_worker_summary!(workspace) do
    workspace
    |> Path.join(".orocsy/delivery/token-telemetry/workers.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> List.last()
    |> Jason.decode!()
  end

  defp temp_workspace(name) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-token-telemetry-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    workspace
  end

  defp init_git_repo!(workspace) do
    git!(workspace, ["init", "-b", "main"])
    git!(workspace, ["config", "user.name", "Test User"])
    git!(workspace, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(workspace, "README.md"), "baseline\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "Initial commit"])
  end

  defp git!(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
