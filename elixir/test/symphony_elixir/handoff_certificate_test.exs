defmodule SymphonyElixir.HandoffCertificateTest do
  use ExUnit.Case

  alias SymphonyElixir.{HandoffCertificate, Linear.Issue, ReviewMonitor}

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
    remote = Path.join(workspace, ".git/test-origin.git")
    git!(workspace, ["init", "--bare", remote])
    git!(workspace, ["remote", "add", "origin", remote])
    git!(workspace, ["push", "origin", "main"])
    git!(workspace, ["switch", "-c", "orocsy/cod-266"])
    File.write!(Path.join(workspace, "README.md"), "# Test\n\nImplementation.\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "Implement MIU"])
    git!(workspace, ["push", "--set-upstream", "origin", "orocsy/cod-266"])
    File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])
    install_remote_head_runner!(remote)

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
    assert certificate["remote_repo"] == "test/symphony"
    assert certificate["remote_branch"] == "orocsy/cod-266"
    assert certificate["remote_head_sha"] == certificate["head_sha"]
    assert {:ok, ^certificate} = HandoffCertificate.current(issue, workspace)
  end

  test "trusted GitHub branch lookup uses the configured repository path" do
    previous_runner = Application.get_env(:symphony_elixir, :github_api_runner)

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      send(self(), {:github_branch_endpoint, endpoint})
      {:ok, %{"commit" => %{"sha" => "remote-head"}}}
    end)

    on_exit(fn -> restore_env(:github_api_runner, previous_runner) end)

    assert {:ok, "remote-head"} =
             ReviewMonitor.remote_branch_head("orocsy/symphony", "codex/runtime-branch")

    assert_receive {:github_branch_endpoint, "repos/orocsy/symphony/branches/codex%2Fruntime-branch"}
  end

  test "runtime evidence files do not dirty an otherwise clean handoff certificate", %{
    workspace: workspace,
    issue: issue
  } do
    File.write!(Path.join(workspace, ".git/info/exclude"), "")

    assert {:ok, certificate} =
             HandoffCertificate.issue(issue, workspace,
               completed_mius: ["COD-266-MIU-1"],
               validation_event_ids: ["validation-1"]
             )

    assert File.regular?(Path.join(workspace, ".orocsy/delivery/events/events.jsonl"))
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

  test "rejects a forged local tracking ref when the remote branch is behind", %{
    workspace: workspace,
    issue: issue
  } do
    File.write!(Path.join(workspace, "README.md"), "# Test\n\nNot pushed.\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "Unpushed handoff"])
    git!(workspace, ["update-ref", "refs/remotes/origin/orocsy/cod-266", "HEAD"])

    assert {:error, :unpushed_head} =
             HandoffCertificate.issue(issue, workspace,
               completed_mius: ["COD-266-MIU-1"],
               validation_event_ids: ["validation-1"]
             )
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

  defp install_remote_head_runner!(remote) do
    previous_runner = Application.get_env(:symphony_elixir, :handoff_remote_head_runner)

    Application.put_env(:symphony_elixir, :handoff_remote_head_runner, fn branch ->
      case System.cmd("git", ["--git-dir", remote, "rev-parse", "refs/heads/#{branch}"], stderr_to_stdout: true) do
        {head_sha, 0} -> {:ok, %{"repo" => "test/symphony", "head_sha" => String.trim(head_sha)}}
        {output, status} -> {:error, {:remote_ref_failed, status, String.trim(output)}}
      end
    end)

    on_exit(fn -> restore_env(:handoff_remote_head_runner, previous_runner) end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
