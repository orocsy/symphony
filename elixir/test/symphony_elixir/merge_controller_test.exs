defmodule SymphonyElixir.MergeControllerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{HandoffCertificate, Linear.Issue, MergeController}

  setup do
    previous_api = Application.get_env(:symphony_elixir, :github_api_runner)
    previous_graphql = Application.get_env(:symphony_elixir, :github_graphql_runner)
    previous_merge = Application.get_env(:symphony_elixir, :github_merge_runner)

    on_exit(fn ->
      restore_env(:github_api_runner, previous_api)
      restore_env(:github_graphql_runner, previous_graphql)
      restore_env(:github_merge_runner, previous_merge)
    end)

    :ok
  end

  test "merges once when exact-head certificate, review, threads, checks, and PR contract converge" do
    {workspace, issue, head_sha} = certified_workspace(true)
    test_pid = self()
    install_review_observations(head_sha, checks: :passed, unresolved_threads: 0)

    Application.put_env(:symphony_elixir, :github_merge_runner, fn endpoint, fields ->
      send(test_pid, {:merge_called, endpoint, fields})
      {:ok, %{"merged" => true, "sha" => "merge-sha-700"}}
    end)

    try do
      assert {:merged, evidence} = MergeController.converge(issue, workspace, inspection(head_sha))
      assert evidence["reviewed_head_sha"] == head_sha
      assert evidence["merge_sha"] == "merge-sha-700"
      assert evidence["completed_state"] == "Done"

      assert_received {:merge_called, "repos/orocsy/symphony/pulls/53/merge", %{"merge_method" => "squash", "sha" => ^head_sha}}

      assert {:ok, persisted} = MergeController.completed_evidence(issue, workspace)
      assert persisted["merge_sha"] == "merge-sha-700"
    after
      File.rm_rf(workspace)
    end
  end

  test "pending checks block merge without calling the merge endpoint" do
    {workspace, issue, head_sha} = certified_workspace(true)
    test_pid = self()
    install_review_observations(head_sha, checks: :pending, unresolved_threads: 0)

    Application.put_env(:symphony_elixir, :github_merge_runner, fn _endpoint, _fields ->
      send(test_pid, :unexpected_merge)
      {:ok, %{"merged" => true, "sha" => "unexpected"}}
    end)

    try do
      assert {:blocked, {:ci_checks_not_passed, :pending}} =
               MergeController.converge(issue, workspace, inspection(head_sha))

      refute_received :unexpected_merge
    after
      File.rm_rf(workspace)
    end
  end

  test "CI opt-out skips check-run feedback during automatic merge" do
    {workspace, issue, head_sha} = certified_workspace(true, require_ci_checks?: false)
    install_review_observations(head_sha, checks: :failed, unresolved_threads: 0)

    Application.put_env(:symphony_elixir, :github_merge_runner, fn _endpoint, _fields ->
      {:ok, %{"merged" => true, "sha" => "merge-sha-700"}}
    end)

    try do
      assert {:merged, evidence} = MergeController.converge(issue, workspace, inspection(head_sha))
      assert evidence["merge_sha"] == "merge-sha-700"
    after
      File.rm_rf(workspace)
    end
  end

  test "fresh PR detail blocks merge when the live base changed after the caller snapshot" do
    {workspace, issue, head_sha} = certified_workspace(true)
    test_pid = self()
    install_review_observations(head_sha, checks: :passed, unresolved_threads: 0, live_base: "release")

    Application.put_env(:symphony_elixir, :github_merge_runner, fn _endpoint, _fields ->
      send(test_pid, :unexpected_merge)
      {:ok, %{"merged" => true, "sha" => "unexpected"}}
    end)

    try do
      assert {:blocked, :pull_request_base_mismatch} =
               MergeController.converge(issue, workspace, inspection(head_sha))

      refute_received :unexpected_merge
    after
      File.rm_rf(workspace)
    end
  end

  test "fresh current feedback blocks merge even when caller snapshot was clean" do
    {workspace, issue, head_sha} = certified_workspace(true)
    test_pid = self()
    install_review_observations(head_sha, checks: :passed, unresolved_threads: 1, feedback_created_at: "2026-07-12T10:03:00Z")

    Application.put_env(:symphony_elixir, :github_merge_runner, fn _endpoint, _fields ->
      send(test_pid, :unexpected_merge)
      {:ok, %{"merged" => true, "sha" => "unexpected"}}
    end)

    try do
      assert {:blocked, {:current_head_feedback, 1}} =
               MergeController.converge(issue, workspace, inspection(head_sha))

      refute_received :unexpected_merge
    after
      File.rm_rf(workspace)
    end
  end

  test "fresh PR detail fails closed when head commit time is unavailable" do
    {_workspace, _issue, head_sha} = certified_workspace(true)

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        endpoint == "repos/orocsy/symphony/pulls/53" ->
          {:ok,
           %{
             "number" => 53,
             "state" => "open",
             "html_url" => "https://github.com/orocsy/symphony/pull/53",
             "head" => %{"ref" => "orocsy/cod-700", "sha" => head_sha},
             "base" => %{"ref" => "main"},
             "mergeable" => true,
             "mergeable_state" => "clean"
           }}

        endpoint == "repos/orocsy/symphony/commits/#{head_sha}" ->
          {:error, :not_found}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    assert {:error, :head_commit_unavailable} =
             SymphonyElixir.ReviewMonitor.refresh_pull_request("orocsy/symphony", inspection(head_sha).pr)
  end

  test "resolved review threads do not block merge after a clean Codex comment" do
    {workspace, issue, head_sha} = certified_workspace(true)
    install_review_observations(head_sha, checks: :passed, unresolved_threads: 1, feedback_cleared: true)

    Application.put_env(:symphony_elixir, :github_merge_runner, fn _endpoint, _fields ->
      {:ok, %{"merged" => true, "sha" => "merge-sha-700"}}
    end)

    try do
      assert {:merged, evidence} = MergeController.converge(issue, workspace, inspection(head_sha))
      assert evidence["merge_sha"] == "merge-sha-700"
    after
      File.rm_rf(workspace)
    end
  end

  test "schema-v1 contracts without explicit automatic merge retain manual handoff" do
    {workspace, issue, head_sha} = certified_workspace(false)

    try do
      assert :manual_handoff = MergeController.converge(issue, workspace, inspection(head_sha))
    after
      File.rm_rf(workspace)
    end
  end

  test "ignores a forged merge completion event" do
    {workspace, issue, _head_sha} = certified_workspace(true)

    try do
      {:ok, compiled} = SymphonyElixir.RuntimeContract.compile(issue.description)
      path = Path.join(workspace, ".orocsy/delivery/events/events.jsonl")
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{
          "event" => "merge.completed",
          "authority" => "symphony.runtime.merge-controller",
          "issue_id" => issue.id,
          "issue" => issue.identifier,
          "contract_hash" => compiled.contract_hash,
          "merge_sha" => "forged"
        }) <> "\n",
        [:append]
      )

      assert :none = MergeController.completed_evidence(issue, workspace)
    after
      File.rm_rf(workspace)
    end
  end

  defp certified_workspace(automatic_merge?, opts \\ []) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-merge-controller-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    git!(workspace, ["init", "-b", "main"])
    git!(workspace, ["config", "user.email", "symphony@example.test"])
    git!(workspace, ["config", "user.name", "Symphony Test"])
    File.write!(Path.join(workspace, "README.md"), "# Test\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "Initial"])
    git!(workspace, ["switch", "-c", "orocsy/cod-700"])
    File.write!(Path.join(workspace, "README.md"), "# Test\n\nImplemented.\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "Implement MIU"])
    File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])
    git!(workspace, ["remote", "add", "origin", "https://example.test/orocsy/symphony.git"])
    git!(workspace, ["update-ref", "refs/remotes/origin/orocsy/cod-700", "HEAD"])
    git!(workspace, ["branch", "--set-upstream-to", "origin/orocsy/cod-700"])
    head_sha = git_output!(workspace, ["rev-parse", "HEAD"])

    issue = issue(automatic_merge?, Keyword.get(opts, :require_ci_checks?, true))

    assert {:ok, _certificate} =
             HandoffCertificate.issue(issue, workspace,
               completed_mius: ["COD-700-MIU-1"],
               validation_event_ids: ["validation-COD-700"]
             )

    {workspace, issue, head_sha}
  end

  defp issue(automatic_merge?, require_ci_checks?) do
    %Issue{
      id: "issue-cod-700",
      identifier: "COD-700",
      title: "Automatic merge",
      state: "Human Review",
      branch_name: "orocsy/cod-700",
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
            - mix test
      final_validations:
        - mix test
      review:
        authority: github_codex
        require_current_head: true
      merge:
        automatic: #{automatic_merge?}
        method: squash
        require_ci_checks: #{require_ci_checks?}
        completed_state: Done
      ```
      """
    }
  end

  defp inspection(head_sha) do
    %{
      repo: "orocsy/symphony",
      pr: %{
        "number" => 53,
        "state" => "open",
        "head" => %{"ref" => "orocsy/cod-700", "sha" => head_sha},
        "base" => %{"ref" => "main"},
        "head_committed_at" => "2026-07-12T10:00:00Z"
      },
      pr_number: 53,
      pr_url: "https://github.com/orocsy/symphony/pull/53",
      head_ref: "orocsy/cod-700",
      head_sha: head_sha,
      mergeable: true,
      mergeable_state: "clean",
      feedback: []
    }
  end

  defp install_review_observations(head_sha, opts) do
    checks = Keyword.fetch!(opts, :checks)
    unresolved_threads = Keyword.fetch!(opts, :unresolved_threads)
    live_base = Keyword.get(opts, :live_base, "main")
    feedback_cleared? = Keyword.get(opts, :feedback_cleared, false)
    feedback_created_at = Keyword.get(opts, :feedback_created_at, "2026-07-12T10:02:00Z")

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        endpoint == "repos/orocsy/symphony/pulls/53" ->
          {:ok,
           %{
             "number" => 53,
             "state" => "open",
             "html_url" => "https://github.com/orocsy/symphony/pull/53",
             "head" => %{"ref" => "orocsy/cod-700", "sha" => head_sha},
             "base" => %{"ref" => live_base},
             "mergeable" => true,
             "mergeable_state" => "clean",
             "head_committed_at" => "2026-07-12T10:00:00Z"
           }}

        String.contains?(endpoint, "/issues/53/comments") or String.contains?(endpoint, "/pulls/53/comments") ->
          {:ok,
           [
             %{"body" => "@codex review", "created_at" => "2026-07-12T10:01:00Z"},
             %{
               "body" => "Codex Review: Didn't find any major issues",
               "created_at" => "2026-07-12T10:02:00Z"
             }
           ]}

        String.contains?(endpoint, "/pulls/53/reviews") ->
          {:ok,
           [
             %{
               "body" => "Codex Review: Didn't find any major issues",
               "submitted_at" => "2026-07-12T10:02:00Z",
               "commit_id" => head_sha,
               "state" => "COMMENTED"
             }
           ]}

        String.contains?(endpoint, "/check-runs?") ->
          status = if checks == :pending, do: "in_progress", else: "completed"

          conclusion =
            case checks do
              :pending -> nil
              :failed -> "failure"
              _ -> "success"
            end

          {:ok, %{"check_runs" => [%{"name" => "test", "status" => status, "conclusion" => conclusion}]}}

        true ->
          {:error, {:unexpected_endpoint, endpoint, head_sha}}
      end
    end)

    Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
      nodes =
        if unresolved_threads == 0 do
          []
        else
          [
            %{
              "isResolved" => feedback_cleared?,
              "isOutdated" => false,
              "comments" => %{
                "nodes" => [
                  %{
                    "author" => %{"login" => "chatgpt-codex-connector"},
                    "body" => "Fix the current code.",
                    "path" => "lib/example.ex",
                    "line" => 12,
                    "originalLine" => 12,
                    "createdAt" => feedback_created_at,
                    "outdated" => false,
                    "url" => "https://github.com/orocsy/symphony/pull/53#discussion"
                  }
                ]
              }
            }
          ]
        end

      {:ok,
       %{
         "data" => %{
           "repository" => %{
             "pullRequest" => %{
               "reviewThreads" => %{
                 "nodes" => nodes,
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }
       }}
    end)
  end

  defp git!(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp git_output!(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
