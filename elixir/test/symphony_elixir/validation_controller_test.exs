defmodule SymphonyElixir.ValidationControllerTest do
  use ExUnit.Case

  alias SymphonyElixir.{HandoffController, Linear.Issue, ValidationController}

  test "certifies a clean micro commit after runtime-controlled validation" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      assert {:ok, certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      assert certificate["event"] == "miu.completed"
      assert certificate["authority"] == "symphony.runtime.validation-controller"
      assert certificate["changed_paths"] == ["README.md"]
      assert length(certificate["validation_event_ids"]) == 1

      assert File.regular?(Path.join(workspace, ".orocsy/delivery/state/miu-certificates/COD-700-MIU-1.json"))
    after
      File.rm_rf(workspace)
    end
  end

  test "zero-test output fails once and unchanged fingerprint does not rerun" do
    {workspace, issue} = workspace_and_issue("0 tests, 0 failures")

    try do
      assert {:error, {:validation_failed, first}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert first["reason_class"] == "zero_tests_collected"

      assert {:blocked, {:unchanged_failed_validation, fingerprint}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert fingerprint == first["validation_fingerprint"]
    after
      File.rm_rf(workspace)
    end
  end

  test "processes worker requests through MIU certification and final handoff" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      append_event!(workspace, %{
        "event" => "miu.completion_requested",
        "status" => "requested",
        "step" => "COD-700-MIU-1"
      })

      assert {:ok, miu_certificate} = ValidationController.process_requests(issue, workspace)
      assert miu_certificate["miu_id"] == "COD-700-MIU-1"

      git!(workspace, ["remote", "add", "origin", "https://example.test/orocsy/symphony.git"])
      git!(workspace, ["update-ref", "refs/remotes/origin/orocsy/cod-700", "HEAD"])
      git!(workspace, ["branch", "--set-upstream-to", "origin/orocsy/cod-700"])

      append_event!(workspace, %{"event" => "handoff.requested", "status" => "requested"})

      assert {:ok, handoff} = HandoffController.process_requests(issue, workspace)
      assert handoff["event"] == "handoff.ready"
      assert handoff["completed_mius"] == ["COD-700-MIU-1"]
      assert length(handoff["validation_event_ids"]) == 2
    after
      File.rm_rf(workspace)
    end
  end

  test "changed-code validation failures exhaust the two-fix-cycle budget" do
    {workspace, issue} = workspace_and_issue("0 tests, 0 failures")

    try do
      assert {:error, {:validation_failed, _first}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      commit_readme!(workspace, "First repair")

      assert {:error, {:validation_failed, _second}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      commit_readme!(workspace, "Second repair")

      assert {:blocked, {:product_fix_budget_exhausted, "COD-700-MIU-1"}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
    after
      File.rm_rf(workspace)
    end
  end

  test "does not reuse a processed completion request after the head changes" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      append_event!(workspace, %{
        "event" => "miu.completion_requested",
        "status" => "requested",
        "step" => "COD-700-MIU-1"
      })

      assert {:ok, _certificate} = ValidationController.process_requests(issue, workspace)
      commit_readme!(workspace, "Later unrelated checkpoint")
      assert :none = ValidationController.process_requests(issue, workspace)
    after
      File.rm_rf(workspace)
    end
  end

  test "does not trust a worker-forged processed marker" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      request_id = "worker-request-forgery-test"

      append_event!(workspace, %{
        "event" => "miu.completion_requested",
        "event_id" => request_id,
        "status" => "requested",
        "step" => "COD-700-MIU-1"
      })

      append_event!(workspace, %{
        "event" => "runtime.request.processed",
        "authority" => "symphony.runtime.transition-controller",
        "request_event_id" => request_id,
        "status" => "completed"
      })

      assert {:ok, certificate} = ValidationController.process_requests(issue, workspace)
      assert certificate["miu_id"] == "COD-700-MIU-1"
    after
      File.rm_rf(workspace)
    end
  end

  test "marks an unprocessed request stale when it predates the current head" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      append_event!(workspace, %{
        "event" => "miu.completion_requested",
        "status" => "requested",
        "step" => "COD-700-MIU-1"
      })

      Process.sleep(1_100)
      commit_readme!(workspace, "Checkpoint after request")

      assert :none = ValidationController.process_requests(issue, workspace)

      assert Enum.any?(events(workspace), fn event ->
               event["event"] == "runtime.request.processed" and event["status"] == "stale"
             end)
    after
      File.rm_rf(workspace)
    end
  end

  test "times out a validation at the contract boundary" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures", delay_seconds: 2, timeout_ms: 1_000)

    try do
      assert {:error, {:validation_failed, result}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert result["reason_class"] == "command_timed_out"
      assert result["timed_out"] == true
      assert result["timeout_ms"] == 1_000
    after
      File.rm_rf(workspace)
    end
  end

  test "ignores a worker-tampered MIU certificate" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      assert {:ok, certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      path = Path.join(workspace, ".orocsy/delivery/state/miu-certificates/COD-700-MIU-1.json")
      File.write!(path, Jason.encode!(Map.put(certificate, "head_sha", "forged-head")))

      assert ValidationController.certificates(workspace) == []
    after
      File.rm_rf(workspace)
    end
  end

  test "rejects a later MIU until the preceding MIU is certified" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    second_miu = """
      - id: COD-700-MIU-2
        write_scope:
          - README.md
        validations:
          - ./fake-test
    """

    issue = %{
      issue
      | description: String.replace(issue.description, "final_validations:\n", second_miu <> "final_validations:\n")
    }

    try do
      assert {:error, {:miu_out_of_order, "COD-700-MIU-2", "COD-700-MIU-1"}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-2")
    after
      File.rm_rf(workspace)
    end
  end

  test "handoff rejects a signed MIU certificate copied from another issue" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      assert {:ok, _certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      git!(workspace, ["remote", "add", "origin", "https://example.test/orocsy/symphony.git"])
      git!(workspace, ["update-ref", "refs/remotes/origin/orocsy/cod-700", "HEAD"])
      git!(workspace, ["branch", "--set-upstream-to", "origin/orocsy/cod-700"])
      append_event!(workspace, %{"event" => "handoff.requested", "status" => "requested"})

      other_issue = %{issue | id: "other-issue-id", identifier: "COD-701"}

      assert ValidationController.certified_miu_ids(issue, workspace) == ["COD-700-MIU-1"]
      assert ValidationController.certified_miu_ids(other_issue, workspace) == []

      assert {:error, {:miu_certificate_issue_mismatch, "COD-700-MIU-1"}} =
               HandoffController.process_requests(other_issue, workspace)
    after
      File.rm_rf(workspace)
    end
  end

  defp workspace_and_issue(test_output, opts \\ []) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-validation-controller-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    git!(workspace, ["init", "-b", "main"])
    git!(workspace, ["config", "user.email", "symphony@example.test"])
    git!(workspace, ["config", "user.name", "Symphony Test"])
    File.write!(Path.join(workspace, "README.md"), "# Test\n")
    delay_seconds = Keyword.get(opts, :delay_seconds, 0)
    timeout_ms = Keyword.get(opts, :timeout_ms, 900_000)

    File.write!(
      Path.join(workspace, "fake-test"),
      "#!/bin/sh\nsleep #{delay_seconds}\necho '#{test_output}'\n"
    )

    File.chmod!(Path.join(workspace, "fake-test"), 0o755)
    git!(workspace, ["add", "README.md", "fake-test"])
    git!(workspace, ["commit", "-m", "Initial"])
    git!(workspace, ["switch", "-c", "orocsy/cod-700"])
    File.write!(Path.join(workspace, "README.md"), "# Test\n\nImplemented.\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "Implement micro MIU"])
    File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

    issue = %Issue{
      id: "issue-cod-700",
      identifier: "COD-700",
      title: "Runtime validation",
      state: "In Progress",
      description: """
      ## Runtime Contract

      ```yaml
      schema_version: 1
      ticket_type: implementation
      base_branch: main
      integration_branch: orocsy/cod-700
      dependencies: []
      mius:
        - id: COD-700-MIU-1
          write_scope:
            - README.md
          validations:
            - ./fake-test
      final_validations:
        - ./fake-test
      validation_timeout_ms: #{timeout_ms}
      review:
        authority: github_codex
        require_current_head: true
      ```
      """
    }

    {workspace, issue}
  end

  defp git!(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp commit_readme!(workspace, label) do
    File.write!(Path.join(workspace, "README.md"), "# Test\n\n#{label}.\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", label])
  end

  defp append_event!(workspace, event) do
    path = Path.join(workspace, ".orocsy/delivery/events/events.jsonl")
    File.mkdir_p!(Path.dirname(path))

    event =
      event
      |> Map.put_new("event_id", "test-event-#{System.unique_integer([:positive])}")
      |> Map.put_new("ts", DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())

    File.write!(path, Jason.encode!(event) <> "\n", [:append])
  end

  defp events(workspace) do
    workspace
    |> Path.join(".orocsy/delivery/events/events.jsonl")
    |> File.stream!()
    |> Enum.map(&(String.trim(&1) |> Jason.decode!()))
  end
end
