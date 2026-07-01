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

  test "redacts multiple leading environment assignments in fallback fingerprints" do
    summary =
      TokenTelemetry.command_summary("FIRST_VALUE=alpha SECOND_VALUE=beta python script.py")

    assert summary.command_fingerprint == "python"
    refute summary.command_fingerprint =~ "alpha"
    refute summary.command_fingerprint =~ "SECOND_VALUE"
    refute summary.command_fingerprint =~ "beta"
  end

  test "redacts shell-wrapped environment assignments in fallback fingerprints" do
    summary =
      TokenTelemetry.command_summary(~s(bash -lc 'FIRST_VALUE=alpha SECOND_VALUE=beta python script.py'))

    assert summary.command_fingerprint == "python"
    refute summary.command_fingerprint =~ "alpha"
    refute summary.command_fingerprint =~ "SECOND_VALUE"
    refute summary.command_fingerprint =~ "beta"
  end

  test "classifies shell-wrapped commands by their inner command" do
    read_summary =
      TokenTelemetry.command_summary(~s(/bin/zsh -lc "sed -n '1,40p' lib/app.ex"))

    validation_summary =
      TokenTelemetry.command_summary(~s(bash -lc "pnpm test"))

    assert read_summary.phase == "code_read"
    assert read_summary.command_fingerprint == "sed-read-lib-app.ex"
    assert validation_summary.phase == "validation"
    assert validation_summary.command_fingerprint == "pnpm"
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

  test "seeds continuation turns from prior thread usage" do
    workspace = temp_workspace("continuation-baseline")

    try do
      first_turn = start_test_turn(workspace, turn_id: "turn-1", turn_number: 1)
      observe_token_total(first_turn, 1_000)
      TokenTelemetry.stop(first_turn)

      second_turn = start_test_turn(workspace, turn_id: "turn-2", turn_number: 2)
      observe_token_total(second_turn, 1_200)
      TokenTelemetry.stop(second_turn)

      summary = read_worker_summary!(workspace)
      token_spans = workspace |> read_spans!() |> Enum.filter(&(&1["kind"] == "token_update"))
      continuation_spans = Enum.filter(token_spans, &(&1["turn"] == 2))

      assert summary["total_tokens"] == 200
      assert summary["input_tokens"] == 200
      assert summary["cached_input_tokens"] == 100
      assert [%{"phase" => "startup", "total_tokens" => 200}] = summary["top_phases"]
      assert Enum.map(continuation_spans, & &1["total_tokens_delta"]) == [200]
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

  test "does not count preexisting dirty files as turn progress" do
    workspace = temp_workspace("dirty-baseline")

    try do
      init_git_repo!(workspace)
      File.write!(Path.join(workspace, "preexisting.txt"), "preexisting dirty work\n")
      telemetry = start_test_turn(workspace)
      observe_token_total(telemetry, 2_000)
      TokenTelemetry.stop(telemetry)

      summary = read_worker_summary!(workspace)

      assert summary["status"] == "blocked_no_durable_progress"
      assert summary["dirty_files"] == []
    after
      File.rm_rf(workspace)
    end
  end

  test "counts edits to preexisting dirty files as turn progress" do
    workspace = temp_workspace("dirty-baseline-edit")

    try do
      init_git_repo!(workspace)
      File.write!(Path.join(workspace, "preexisting.txt"), "preexisting dirty work\n")
      telemetry = start_test_turn(workspace)
      File.write!(Path.join(workspace, "preexisting.txt"), "edited during turn\n")
      observe_token_total(telemetry, 2_000)
      TokenTelemetry.stop(telemetry)

      summary = read_worker_summary!(workspace)

      assert summary["status"] == "productive"
      assert summary["dirty_files"] == ["preexisting.txt"]
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

  test "counts commits pushed during the turn as handoff progress" do
    workspace = temp_workspace("pushed-commit-summary")
    remote = temp_workspace("pushed-commit-remote")

    try do
      File.rm_rf!(remote)
      git!(System.tmp_dir!(), ["init", "--bare", remote])

      init_git_repo!(workspace)
      git!(workspace, ["remote", "add", "origin", remote])
      git!(workspace, ["push", "-u", "origin", "main"])
      git!(workspace, ["switch", "-c", "orocsy/mt-pushed"])
      git!(workspace, ["push", "-u", "origin", "orocsy/mt-pushed"])

      telemetry = start_test_turn(workspace)
      File.write!(Path.join(workspace, "feature.txt"), "pushed progress\n")
      git!(workspace, ["add", "feature.txt"])
      git!(workspace, ["commit", "-m", "Add pushed progress"])
      git!(workspace, ["push"])
      observe_token_total(telemetry, 3_000)
      TokenTelemetry.stop(telemetry)

      summary = read_worker_summary!(workspace)

      assert summary["status"] == "handoff_recovery"
      assert summary["dirty_files"] == []
      assert length(summary["new_commits"]) == 1
    after
      File.rm_rf(workspace)
      File.rm_rf(remote)
    end
  end

  test "does not count preexisting local commits as turn progress" do
    workspace = temp_workspace("commit-baseline")

    try do
      init_git_repo!(workspace)
      git!(workspace, ["switch", "-c", "orocsy/mt-preexisting"])
      File.write!(Path.join(workspace, "preexisting.txt"), "preexisting commit\n")
      git!(workspace, ["add", "preexisting.txt"])
      git!(workspace, ["commit", "-m", "Add preexisting progress"])

      telemetry = start_test_turn(workspace)
      observe_token_total(telemetry, 2_500)
      TokenTelemetry.stop(telemetry)

      summary = read_worker_summary!(workspace)

      assert summary["status"] == "blocked_no_durable_progress"
      assert summary["new_commits"] == []
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

  test "redacts Orocsy progress tool metadata" do
    workspace = temp_workspace("progress-event-redaction")

    try do
      telemetry = start_test_turn(workspace)
      events_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(events_dir)

      File.write!(
        Path.join(events_dir, "events.jsonl"),
        Jason.encode!(%{
          "event" => "tool.finished",
          "status" => "passed",
          "tool" => "FIRST_VALUE=alpha pnpm test --flag hidden",
          "ts" => DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601()
        }) <> "\n"
      )

      observe_token_total(telemetry, 1_500)
      TokenTelemetry.stop(telemetry)

      summary = read_worker_summary!(workspace)
      [event] = summary["durable_progress_events"]

      assert summary["status"] == "productive"
      refute Map.has_key?(event, "tool")
      assert event["tool_fingerprint"] == "pnpm"
      refute Jason.encode!(event) =~ "alpha"
      refute Jason.encode!(event) =~ "--flag"
    after
      File.rm_rf(workspace)
    end
  end

  test "ignores lifecycle-only Orocsy checkpoints as durable progress" do
    for tool <- ["first-turn-miu-handoff", "technical-miu-trace"] do
      workspace = temp_workspace("lifecycle-event-summary")

      try do
        telemetry = start_test_turn(workspace)
        events_dir = Path.join(workspace, ".orocsy/delivery/events")
        File.mkdir_p!(events_dir)

        File.write!(
          Path.join(events_dir, "events.jsonl"),
          Jason.encode!(%{
            "event" => "tool.finished",
            "status" => "passed",
            "tool" => tool,
            "ts" => DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601()
          }) <> "\n"
        )

        observe_token_total(telemetry, 1_500)
        TokenTelemetry.stop(telemetry)

        summary = read_worker_summary!(workspace)

        assert summary["status"] == "blocked_no_durable_progress"
        assert summary["durable_progress_events"] == []
      after
        File.rm_rf(workspace)
      end
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

  test "does not mark repeated commands as loops when the turn is productive" do
    workspace = temp_workspace("productive-repeat")

    try do
      init_git_repo!(workspace)
      telemetry = start_test_turn(workspace)
      observe_command(telemetry, "pnpm test")
      observe_token_total(telemetry, 1_000)
      File.write!(Path.join(workspace, "progress.txt"), "productive edit\n")
      observe_command(telemetry, "pnpm test")
      observe_token_total(telemetry, 2_000)
      TokenTelemetry.stop(telemetry)

      summary = read_worker_summary!(workspace)

      assert summary["status"] == "productive"
      refute "validation_loop" in summary["loop_signatures"]
      refute "no_durable_progress" in summary["loop_signatures"]
    after
      File.rm_rf(workspace)
    end
  end

  test "clears stale command context when reasoning resumes" do
    workspace = temp_workspace("reasoning-context")

    try do
      telemetry = start_test_turn(workspace)
      observe_command(telemetry, "sed -n '1,40p' src/app/page.tsx")
      observe_token_total(telemetry, 1_000)
      observe_reasoning(telemetry)
      observe_token_total(telemetry, 2_000)
      TokenTelemetry.stop(telemetry)

      token_spans = workspace |> read_spans!() |> Enum.filter(&(&1["kind"] == "token_update"))
      [command_span, reasoning_span] = token_spans

      assert command_span["command_fingerprint"] == "sed-read-src-app-page.tsx"
      assert command_span["files"] == ["src/app/page.tsx"]
      assert reasoning_span["phase"] == "reasoning"
      assert reasoning_span["command_fingerprint"] == nil
      assert reasoning_span["files"] == []
    after
      File.rm_rf(workspace)
    end
  end

  defp start_test_turn(workspace, opts \\ []) do
    {turn_id, opts} = Keyword.pop(opts, :turn_id, "turn-93")

    TokenTelemetry.start_turn(
      workspace,
      %{id: "issue-token-telemetry", identifier: "MT-93"},
      "thread-93",
      turn_id,
      opts
    )
  end

  defp observe_command(telemetry, command) do
    TokenTelemetry.observe(telemetry, %{
      "method" => "codex/event/exec_command_begin",
      "params" => %{"msg" => %{"command" => command}}
    })
  end

  defp observe_reasoning(telemetry) do
    TokenTelemetry.observe(telemetry, %{
      "method" => "item/reasoning/summaryPartAdded",
      "params" => %{"itemId" => "reasoning-1"}
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

  defp read_spans!(workspace) do
    workspace
    |> Path.join(".orocsy/delivery/token-telemetry/spans.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
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
