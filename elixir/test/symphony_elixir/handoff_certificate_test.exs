defmodule SymphonyElixir.HandoffCertificateTest do
  use ExUnit.Case

  alias SymphonyElixir.{HandoffCertificate, Linear.Issue}

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-handoff-certificate-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    git!(workspace, ["init", "-b", "main"])
    git!(workspace, ["config", "user.email", "symphony@example.test"])
    git!(workspace, ["config", "user.name", "Symphony Test"])
    File.write!(Path.join(workspace, "README.md"), "# Test\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "Initial"])
    git!(workspace, ["remote", "add", "origin", "https://example.test/orocsy/symphony.git"])
    git!(workspace, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    git!(workspace, ["switch", "-c", "orocsy/cod-266"])
    File.write!(Path.join(workspace, "README.md"), "# Test\n\nImplementation.\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "Implement MIU"])
    git!(workspace, ["update-ref", "refs/remotes/origin/orocsy/cod-266", "HEAD"])
    git!(workspace, ["branch", "--set-upstream-to", "origin/orocsy/cod-266"])
    File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

    issue = issue()

    on_exit(fn -> File.rm_rf(workspace) end)
    {:ok, workspace: workspace, issue: issue}
  end

  test "generic passed gates never substitute for a handoff certificate", %{workspace: workspace, issue: issue} do
    event_dir = Path.join(workspace, ".orocsy/delivery/events")
    File.mkdir_p!(event_dir)

    File.write!(
      Path.join(event_dir, "events.jsonl"),
      ~s({"event":"gate.post-miu","status":"passed","tool":"pnpm test"}\n)
    )

    assert :not_ready = HandoffCertificate.current(issue, workspace)
  end

  test "issues and verifies a certificate bound to the current contract branch and head", %{
    workspace: workspace,
    issue: issue
  } do
    assert {:ok, certificate} =
             HandoffCertificate.issue(issue, workspace,
               completed_mius: ["COD-266-MIU-1"],
               validation_event_ids: ["validation-1"]
             )

    assert certificate["event"] == "handoff.ready"
    assert certificate["authority"] == "symphony.runtime.handoff-controller"
    assert certificate["branch"] == "orocsy/cod-266"
    assert {:ok, ^certificate} = HandoffCertificate.current(issue, workspace)
  end

  test "contract or head changes invalidate an existing certificate", %{workspace: workspace, issue: issue} do
    assert {:ok, _certificate} =
             HandoffCertificate.issue(issue, workspace,
               completed_mius: ["COD-266-MIU-1"],
               validation_event_ids: ["validation-1"]
             )

    changed_issue = %{issue | description: issue.description <> "\nAdditional requirement.\n"}
    assert {:stale, :issue_revision_mismatch} = HandoffCertificate.current(changed_issue, workspace)

    File.write!(Path.join(workspace, "README.md"), "# Test\n\nNew head.\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "Change head"])

    assert {:stale, :head_mismatch} = HandoffCertificate.current(issue, workspace)
  end

  test "rejects a worker-tampered runtime certificate", %{workspace: workspace, issue: issue} do
    assert {:ok, certificate} =
             HandoffCertificate.issue(issue, workspace,
               completed_mius: ["COD-266-MIU-1"],
               validation_event_ids: ["validation-1"]
             )

    path = Path.join(workspace, HandoffCertificate.path())
    File.write!(path, Jason.encode!(Map.put(certificate, "validation_event_ids", ["forged-validation"])))

    assert {:stale, :invalid_controller_signature} = HandoffCertificate.current(issue, workspace)
  end

  defp issue do
    %Issue{
      id: "issue-cod-266",
      identifier: "COD-266",
      title: "Handoff certificate",
      state: "Rework",
      branch_name: "orocsy/generated-child",
      description: """
      ## Runtime Contract

      ```yaml
      schema_version: 1
      ticket_type: implementation
      base_branch: main
      integration_branch: orocsy/cod-266
      dependencies: []
      mius:
        - id: COD-266-MIU-1
          write_scope:
            - README.md
          validations:
            - mix test test/symphony_elixir/handoff_certificate_test.exs
      final_validations:
        - mix test test/symphony_elixir/handoff_certificate_test.exs
      review:
        authority: github_codex
        require_current_head: true
      ```
      """
    }
  end

  defp git!(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end
