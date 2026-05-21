defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Codex, StringOrMap}
  alias SymphonyElixir.Linear.{Client, Issue}

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      assert File.read!(Path.join([second_workspace, "tmp", "scratch.txt"])) == "remove me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = SymphonyElixir.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(actual_root, "MT-LINK"))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_states_page, query, %{ids: ^first_batch_ids, first: 50, relationFirst: 50}}
    assert query =~ "SymphonyLinearIssuesById"

    assert_receive {:fetch_issue_states_page, ^query, %{ids: ^second_batch_ids, first: 5, relationFirst: 50}}
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "review monitor moves human-review issues with current-head PR feedback to rework" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy",
      review_monitor_states: ["Human Review"],
      review_monitor_rework_state: "Rework"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "issue-review-1",
        identifier: "COD-151",
        title: "Guest session and limit engine",
        state: "Human Review",
        branch_name: "orocsy/cod-151-guest-session"
      }
    ])

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
          {:ok,
           [
             %{
               "number" => 3,
               "html_url" => "https://github.com/acme/nutribuddy/pull/3",
               "head" => %{"sha" => "abc123current", "ref" => "orocsy/cod-151-guest-session"}
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/3/comments" ->
          {:ok,
           [
             %{
               "body" => "**P2** Honor existing guest gates before accepting swipes",
               "commit_id" => "abc123current",
               "path" => "src/lib/domain/guest-limit.ts",
               "line" => 45,
               "html_url" => "https://github.com/acme/nutribuddy/pull/3#discussion"
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/3/reviews" ->
          {:ok, []}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

    assert :ok = SymphonyElixir.ReviewMonitor.run_once()

    assert_receive {:memory_tracker_state_update, "issue-review-1", "Rework"}
    assert_receive {:memory_tracker_comment, "issue-review-1", body}
    assert body =~ "current PR feedback"
    assert body =~ "src/lib/domain/guest-limit.ts:45"
    assert body =~ "Rework lane"
  end

  test "review monitor ignores stale PR feedback from older commits" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy",
      review_monitor_states: ["Human Review"],
      review_monitor_rework_state: "Rework"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "issue-review-2",
        identifier: "COD-151",
        title: "Guest session and limit engine",
        state: "Human Review",
        branch_name: "orocsy/cod-151-guest-session"
      }
    ])

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
          {:ok,
           [
             %{
               "number" => 3,
               "html_url" => "https://github.com/acme/nutribuddy/pull/3",
               "head" => %{"sha" => "abc123current", "ref" => "orocsy/cod-151-guest-session"}
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/3/comments" ->
          {:ok, [%{"body" => "**P2** Old feedback", "commit_id" => "oldsha"}]}

        endpoint == "repos/acme/nutribuddy/pulls/3/reviews" ->
          {:ok, []}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

    assert :ok = SymphonyElixir.ReviewMonitor.run_once()

    refute_receive {:memory_tracker_state_update, "issue-review-2", "Rework"}, 50
  end

  test "review monitor scans active issues with open PR feedback and moves them to rework" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy",
      review_monitor_states: ["Human Review"],
      review_monitor_rework_state: "Rework"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "issue-review-active",
        identifier: "COD-152",
        title: "Swipe feed UI",
        state: "In Progress",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
      }
    ])

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
          {:ok,
           [
             %{
               "number" => 4,
               "html_url" => "https://github.com/acme/nutribuddy/pull/4",
               "head" => %{
                 "sha" => "efb64f412ce2f3a5f25b2a3766632e864951464a",
                 "ref" => "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
               }
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/4/comments" ->
          {:ok,
           [
             %{
               "body" => "Handle pointer cancel without committing a swipe.",
               "commit_id" => "efb64f412ce2f3a5f25b2a3766632e864951464a",
               "path" => "src/features/swipe/SwipeDeck.tsx",
               "line" => 120,
               "html_url" => "https://github.com/acme/nutribuddy/pull/4#discussion"
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/4/reviews" ->
          {:ok, []}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

    assert :ok = SymphonyElixir.ReviewMonitor.run_once()

    assert_receive {:memory_tracker_state_update, "issue-review-active", "Rework"}
    assert_receive {:memory_tracker_comment, "issue-review-active", body}
    assert body =~ "COD-152"
    assert body =~ "pull/4"
    assert body =~ "src/features/swipe/SwipeDeck.tsx:120"
  end

  test "review monitor respects the tracker issue allowlist before inspecting PRs" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_issue_allowlist: ["COD-170"],
      tracker_active_states: ["Todo", "In Progress"],
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy",
      review_monitor_states: ["Human Review"],
      review_monitor_rework_state: "Rework"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "issue-review-outside-allowlist",
        identifier: "COD-152",
        title: "Outside allowlist",
        state: "Human Review",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
      }
    ])

    test_pid = self()

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      send(test_pid, {:github_called_for_non_allowlisted_issue, endpoint})
      {:error, {:unexpected_endpoint, endpoint}}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

    assert :ok = SymphonyElixir.ReviewMonitor.run_once()

    refute_receive {:github_called_for_non_allowlisted_issue, _endpoint}, 50
    refute_receive {:memory_tracker_state_update, "issue-review-outside-allowlist", "Rework"}, 50
    refute_receive {:memory_tracker_comment, "issue-review-outside-allowlist", _body}, 50
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue with open Orocsy correction is not dispatch-eligible" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dispatch-correction-block-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-1008")

      inbox = Path.join(workspace, ".orocsy/delivery/inbox")
      File.mkdir_p!(inbox)

      correction_path = Path.join(inbox, "correction_20260511085751_143ab7b0.json")

      File.write!(
        correction_path,
        Jason.encode!(%{
          "correction_id" => "correction_20260511085751_143ab7b0",
          "issue" => "MT-1008",
          "next_action" => "block",
          "resolved_at" => nil,
          "status" => "open"
        })
      )

      state = %Orchestrator.State{
        max_concurrent_agents: 3,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: "blocked-by-orocsy-correction",
        identifier: "MT-1008",
        title: "Needs human correction",
        state: "In Progress",
        blocked_by: []
      }

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)

      File.write!(
        correction_path,
        Jason.encode!(%{
          "correction_id" => "correction_20260511085751_143ab7b0",
          "issue" => "MT-1008",
          "next_action" => "block",
          "resolved_at" => "2026-05-11T09:10:00Z",
          "status" => "resolved"
        })
      )

      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace hydration writes issue requirements and declared scope from parseable issue brief" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-requirements-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-cod-152",
        identifier: "COD-152",
        title: "Swipe feed UI and mutation flow",
        state: "In Progress",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow",
        description: """
        ## Feature Group
        recipe-chat

        ## Ticket Type
        test-spec

        ## Integration Branch
        `orocsy/feature-recipe-chat-integration`

        ## Expected Test State
        pending/skip-gated

        ## Test Activation
        COD-203 activates this test.

        ## Write Scope
        - src/features/swipe/**
        - tests/unit/swipe-deck.test.ts

        ## Shared Files
        - package.json

        ## Dependencies
        - COD-151

        ### MIU 1 - Swipe Deck
        Implement the swipe deck against the existing route contract.

        ## Validation
        ```bash
        pnpm test -- tests/unit/swipe-deck.test.ts
        ```

        ## Out Of Scope
        - AI chat generation
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      issue_file = Path.join(workspace, ".orocsy/delivery/issue-requirements.json")
      policy_file = Path.join(workspace, ".orocsy/delivery/policy.yml")
      state_file = Path.join(workspace, ".orocsy/delivery/state/current.json")

      assert File.regular?(issue_file)
      requirements = issue_file |> File.read!() |> Jason.decode!()
      assert requirements["identifier"] == "COD-152"
      assert requirements["branch"] == "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
      assert requirements["feature_group"] == "recipe-chat"
      assert requirements["ticket_type"] == "test-spec"
      assert requirements["integration_branch"] == "orocsy/feature-recipe-chat-integration"
      assert requirements["expected_test_state"] == "pending/skip-gated"
      assert requirements["test_activation"] == "COD-203 activates this test."
      assert "src/features/swipe/**" in requirements["write_scope"]
      assert ["MIU 1 - Swipe Deck"] == requirements["mius"]

      state = state_file |> File.read!() |> Jason.decode!()
      assert state["issue_requirements"]["identifier"] == "COD-152"

      policy = File.read!(policy_file)
      assert policy =~ "src/features/swipe/**"
      assert policy =~ "pnpm test -- tests/unit/swipe-deck.test.ts"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace hydration parses scope and validation commands template headings" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-template-issue-requirements-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-template-scope",
        identifier: "COD-900",
        title: "Template shaped workstream",
        state: "In Progress",
        branch_name: "orocsy/cod-900-template-shaped-workstream",
        description: """
        ## Scope

        In:

        - src/app/page.tsx
        - tests/unit/page.test.ts

        Out:

        - docs/**

        ## MIUs

        ### MIU 1 - Page state

        - Runtime path: `/`
        - Validation command: `pnpm typecheck`

        ## Validation Commands

        ```bash
        pnpm typecheck
        ```
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      requirements =
        workspace
        |> Path.join(".orocsy/delivery/issue-requirements.json")
        |> File.read!()
        |> Jason.decode!()

      assert requirements["write_scope"] == ["src/app/page.tsx", "tests/unit/page.test.ts"]
      assert requirements["out_of_scope"] == ["docs/**"]
      assert requirements["validation"]["commands"] == ["pnpm typecheck"]

      policy =
        workspace
        |> Path.join(".orocsy/delivery/policy.yml")
        |> File.read!()

      assert policy =~ "src/app/page.tsx"
      assert policy =~ "tests/unit/page.test.ts"
      assert policy =~ "pnpm typecheck"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "issue requirements skip empty primary issue brief and read fallback brief" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-requirements-empty-brief-fallback-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery"))
      File.mkdir_p!(Path.join(workspace, ".codex/agentic/issue-briefs"))
      File.write!(Path.join(workspace, ".orocsy/delivery/issue-brief.md"), "\n")

      File.write!(Path.join(workspace, ".codex/agentic/issue-briefs/COD-902.md"), """
      ## Write Scope
      - src/features/fallback.ts

      ### MIU 1 - Fallback Brief Hydration
      Hydrate requirements from the copied issue brief.

      ## Validation
      ```bash
      pnpm test -- fallback
      ```
      """)

      issue = %Issue{
        id: "issue-empty-brief-fallback",
        identifier: "COD-902",
        title: "Fallback issue brief",
        state: "In Progress",
        description: "Placeholder without structured requirements"
      }

      assert {:ok, requirements} = SymphonyElixir.IssueRequirements.from_issue(issue, workspace)
      assert requirements["write_scope"] == ["src/features/fallback.ts"]
      assert requirements["mius"] == ["MIU 1 - Fallback Brief Hydration"]
      assert requirements["validation"]["commands"] == ["pnpm test -- fallback"]
    after
      File.rm_rf(workspace)
    end
  end

  test "issue requirements fall back for MIU-only descriptions" do
    issue = %Issue{
      id: "issue-miu-only",
      identifier: "COD-901",
      title: "MIU-only placeholder",
      state: "In Progress",
      description: """
      ### MIU 1 - Placeholder

      - Runtime path:
      - Exact tests:
      """
    }

    assert {:error, :no_issue_requirements} =
             SymphonyElixir.IssueRequirements.from_issue(issue)
  end

  test "workspace hydration converts descriptive write scope to declared-scope path patterns" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-requirements-descriptive-scope-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-descriptive-scope",
        identifier: "COD-157",
        title: "Bridge Contract",
        state: "In Progress",
        branch_name: "orocsy/cod-157",
        description: """
        ## Write Scope
        - docs/TECHNICAL_DESIGN.md only for the accepted-swipe contract section.
        - src/lib/schemas/swipe.ts and src/lib/schemas/recipe-chat.ts only if schema code is required.
        - tests/unit/*contract* only if a schema-level contract test fits.

        ### MIU 1 - Contract
        Document the handoff.

        ## Validation
        ```bash
        pnpm typecheck
        ```

        ## Out Of Scope
        - UI implementation
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      requirements =
        workspace
        |> Path.join(".orocsy/delivery/issue-requirements.json")
        |> File.read!()
        |> Jason.decode!()

      assert "docs/TECHNICAL_DESIGN.md only for the accepted-swipe contract section." in requirements["write_scope"]

      policy =
        workspace
        |> Path.join(".orocsy/delivery/policy.yml")
        |> File.read!()

      assert policy =~ "  - docs/TECHNICAL_DESIGN.md\n"
      assert policy =~ "  - src/lib/schemas/swipe.ts\n"
      assert policy =~ "  - src/lib/schemas/recipe-chat.ts\n"
      assert policy =~ "  - tests/unit/*contract*\n"
      refute policy =~ "only for the accepted-swipe"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace hydration does not abort on partial issue requirements" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-requirements-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-empty-scope",
        identifier: "COD-153",
        title: "Recipe chat generation",
        state: "In Progress",
        description: """
        ## Write Scope

        ### MIU 1 - Provider adapter

        ## Validation
        ```bash
        pnpm test
        ```
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      refute File.regular?(Path.join(workspace, ".orocsy/delivery/issue-requirements.json"))
      refute File.regular?(Path.join(workspace, ".orocsy/delivery/state/current.json"))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace reconciles stale main checkout to existing Linear branch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-branch-reconcile-#{System.unique_integer([:positive])}"
      )

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      branch = "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"

      File.mkdir_p!(source_repo)
      assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: source_repo, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: source_repo)
      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: source_repo)
      File.write!(Path.join(source_repo, "README.md"), "main\n")
      assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: source_repo)
      assert {_output, 0} = System.cmd("git", ["commit", "-m", "Initial main"], cd: source_repo, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["switch", "-c", branch], cd: source_repo, stderr_to_stdout: true)
      File.mkdir_p!(Path.join(source_repo, "src/features/swipe"))
      File.write!(Path.join(source_repo, "src/features/swipe/deck.ts"), "export const deck = true;\n")
      assert {_output, 0} = System.cmd("git", ["add", "src/features/swipe/deck.ts"], cd: source_repo)
      assert {_output, 0} = System.cmd("git", ["commit", "-m", "Add swipe deck"], cd: source_repo, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["switch", "main"], cd: source_repo, stderr_to_stdout: true)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone #{source_repo} . && git checkout -B main origin/main"
      )

      issue = %Issue{
        id: "issue-cod-152",
        identifier: "COD-152",
        title: "Swipe feed UI and mutation flow",
        state: "In Progress",
        branch_name: branch,
        description: "Runtime should reconcile the workspace branch before dispatch."
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert {current_branch, 0} = System.cmd("git", ["branch", "--show-current"], cd: workspace)
      assert String.trim(current_branch) == branch
      assert File.regular?(Path.join(workspace, "src/features/swipe/deck.ts"))

      assert {upstream, 0} =
               System.cmd("git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert String.trim(upstream) == "origin/#{branch}"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace creates missing Linear branch from origin main without tracking main" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-branch-create-#{System.unique_integer([:positive])}"
      )

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      branch = "orocsy/cod-153-miu-5-recipe-chat-generation"

      File.mkdir_p!(source_repo)
      assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: source_repo, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: source_repo)
      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: source_repo)
      File.write!(Path.join(source_repo, "README.md"), "main\n")
      assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: source_repo)
      assert {_output, 0} = System.cmd("git", ["commit", "-m", "Initial main"], cd: source_repo, stderr_to_stdout: true)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone #{source_repo} . && git checkout -B main origin/main"
      )

      issue = %Issue{
        id: "issue-cod-153",
        identifier: "COD-153",
        title: "Recipe chat generation",
        state: "In Progress",
        branch_name: branch,
        description: "Runtime should create the Linear branch before dispatch."
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert {current_branch, 0} = System.cmd("git", ["branch", "--show-current"], cd: workspace)
      assert String.trim(current_branch) == branch

      assert {status, 0} = System.cmd("git", ["status", "--short", "--branch"], cd: workspace)
      refute String.contains?(status, "origin/main")

      assert {_upstream, upstream_status} =
               System.cmd("git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert upstream_status != 0
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace creates missing Linear branch from declared integration branch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-branch-create-from-integration-#{System.unique_integer([:positive])}"
      )

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      integration_branch = "orocsy/feature-recipe-chat-integration"
      issue_branch = "orocsy/cod-201-provider-tests"

      File.mkdir_p!(source_repo)
      assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: source_repo, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: source_repo)
      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: source_repo)
      File.write!(Path.join(source_repo, "README.md"), "main\n")
      assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: source_repo)
      assert {_output, 0} = System.cmd("git", ["commit", "-m", "Initial main"], cd: source_repo, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["switch", "-c", integration_branch], cd: source_repo, stderr_to_stdout: true)
      File.mkdir_p!(Path.join(source_repo, "src/lib/providers"))
      File.write!(Path.join(source_repo, "src/lib/providers/ai-provider.ts"), "export const integration = true;\n")
      assert {_output, 0} = System.cmd("git", ["add", "src/lib/providers/ai-provider.ts"], cd: source_repo)
      assert {_output, 0} = System.cmd("git", ["commit", "-m", "Add integration contract"], cd: source_repo, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["switch", "main"], cd: source_repo, stderr_to_stdout: true)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone #{source_repo} . && git checkout -B main origin/main"
      )

      issue = %Issue{
        id: "issue-cod-201",
        identifier: "COD-201",
        title: "Provider adapter tests",
        state: "Ready for Symphony",
        branch_name: issue_branch,
        description: """
        ## Integration Branch
        `#{integration_branch}`

        ## Write Scope
        - `tests/unit/recipe-provider.test.ts`

        ## MIUs
        ### MIU 1 - Provider adapter tests

        ## Validation
        ```bash
        pnpm test -- tests/unit/recipe-provider.test.ts
        ```
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert {current_branch, 0} = System.cmd("git", ["branch", "--show-current"], cd: workspace)
      assert String.trim(current_branch) == issue_branch
      assert File.regular?(Path.join(workspace, "src/lib/providers/ai-provider.ts"))

      assert {status, 0} = System.cmd("git", ["status", "--short", "--branch"], cd: workspace)
      refute String.contains?(status, "origin/main")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace creates missing Linear branch from template branch contract base" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-branch-create-from-contract-base-#{System.unique_integer([:positive])}"
      )

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      integration_branch = "orocsy/feature-recipe-chat-integration"
      issue_branch = "orocsy/cod-202-follow-up-route"

      File.mkdir_p!(source_repo)
      assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: source_repo, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: source_repo)
      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: source_repo)
      File.write!(Path.join(source_repo, "README.md"), "main\n")
      assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: source_repo)
      assert {_output, 0} = System.cmd("git", ["commit", "-m", "Initial main"], cd: source_repo, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["switch", "-c", integration_branch], cd: source_repo, stderr_to_stdout: true)
      File.mkdir_p!(Path.join(source_repo, "src/app/api/recipe-chats/[chatId]/messages"))

      File.write!(
        Path.join(source_repo, "src/app/api/recipe-chats/[chatId]/messages/route.ts"),
        "export const fromIntegration = true;\n"
      )

      assert {_output, 0} =
               System.cmd("git", ["add", "src/app/api/recipe-chats/[chatId]/messages/route.ts"], cd: source_repo)

      assert {_output, 0} = System.cmd("git", ["commit", "-m", "Add follow-up route contract"], cd: source_repo, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["switch", "main"], cd: source_repo, stderr_to_stdout: true)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone #{source_repo} . && git checkout -B main origin/main"
      )

      issue = %Issue{
        id: "issue-cod-202",
        identifier: "COD-202",
        title: "Follow-up route",
        state: "Ready for Symphony",
        branch_name: issue_branch,
        description: """
        ## Branch / PR Contract

        - Branch: use Linear branch name.
        - Base: `#{integration_branch}`
        - PR: target the integration branch.
        - Merge behavior: workflow owner merges after review.

        ## Scope

        In:

        - src/app/api/recipe-chats/[chatId]/messages/route.ts

        Out:

        - src/app/page.tsx

        ## MIUs

        ### MIU 1 - Follow-Up Route

        - Runtime path: POST /api/recipe-chats/[chatId]/messages

        ## Validation Commands

        ```bash
        pnpm typecheck
        ```
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert {current_branch, 0} = System.cmd("git", ["branch", "--show-current"], cd: workspace)
      assert String.trim(current_branch) == issue_branch

      assert File.regular?(Path.join(workspace, "src/app/api/recipe-chats/[chatId]/messages/route.ts"))

      assert {status, 0} = System.cmd("git", ["status", "--short", "--branch"], cd: workspace)
      refute String.contains?(status, "origin/main")
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace hooks render issue template variables before execution" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-template-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf '%s\\n' '{{ issue.identifier }} {{ issue.id }}' > hook-context.log",
        hook_before_run: "printf '%s\\n' '{{ issue.identifier }} {{ issue.id }}' > before-run-context.log"
      )

      issue = %Issue{id: "issue-template-id", identifier: "MT-HOOK-TEMPLATE"}

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert :ok = Workspace.run_before_run_hook(workspace, issue)
      assert File.read!(Path.join(workspace, "hook-context.log")) == "MT-HOOK-TEMPLATE issue-template-id\n"
      assert File.read!(Path.join(workspace, "before-run-context.log")) == "MT-HOOK-TEMPLATE issue-template-id\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:symphony_elixir, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:symphony_elixir, :workspace_hook_timeout_ms)
      else
        Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.agent.max_concurrent_agents == 10
    assert config.codex.command == "codex app-server"

    assert config.codex.approval_policy == %{
             "granular" => %{
               "sandbox_approval" => true,
               "rules" => false,
               "mcp_elicitations" => true
             }
           }

    assert config.codex.thread_sandbox == "workspace-write"

    assert {:ok, canonical_default_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [canonical_default_workspace_root],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert config.codex.turn_timeout_ms == 3_600_000
    assert config.codex.read_timeout_ms == 5_000
    assert config.codex.stall_timeout_ms == 300_000
    assert config.codex.durable_progress_timeout_ms == 180_000
    assert config.codex.durable_progress_min_tokens == 250_000
    assert config.codex.max_turn_total_tokens == 1_500_000
    assert config.codex.safe_command_approval_patterns == []

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config 'model=\"gpt-5.5\"' app-server"
    )

    assert Config.settings!().codex.command ==
             "codex --config 'model=\"gpt-5.5\"' app-server"

    explicit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-explicit-sandbox-root-#{System.unique_integer([:positive])}"
      )

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)

    on_exit(fn -> File.rm_rf(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "on-request"
    assert config.codex.thread_sandbox == "workspace-write"

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [explicit_workspace, explicit_cache]
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.read_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.stall_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_durable_progress_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.durable_progress_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_durable_progress_min_tokens: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.durable_progress_min_tokens"

    write_workflow_file!(Workflow.workflow_file_path(), codex_durable_progress_first_event_max_tokens: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.durable_progress_first_event_max_tokens"

    write_workflow_file!(Workflow.workflow_file_path(), codex_max_turn_total_tokens: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.max_turn_total_tokens"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.approval_policy == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.thread_sandbox == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "future-policy"
    assert config.codex.thread_sandbox == "future-sandbox"

    assert :ok = Config.validate!()

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.settings!().codex.command == "codex app-server"
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert config.tracker.api_key == api_key
    assert config.workspace.root == Path.expand(workspace_root)
    assert config.codex.command == "#{codex_bin} app-server"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.api_key == "env:#{api_key_env_var}"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"},
               codex: %{approval_policy: %{granular: %{sandbox_approval: true}}}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")

    assert settings.codex.approval_policy == %{
             "granular" => %{"sandbox_approval" => true}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{missing_secret_env}"},
               workspace: %{root: ""}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: explicit_policy},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: nil},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               codex: %Codex{turn_sandbox_policy: nil},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "schema keeps workspace roots raw while sandbox helpers expand only for local use" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.symphony-workspaces"},
               codex: %{}
             })

    assert settings.workspace.root == "~/.symphony-workspaces"

    assert Schema.resolve_turn_sandbox_policy(settings) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("~/.symphony-workspaces")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["~/.symphony-workspaces"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "runtime sandbox policy resolution expands explicit local workspace roots" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [Path.expand("relative/path", issue_workspace)],
               "networkAccess" => true
             }

      assert {:ok, remote_settings} = Config.codex_runtime_settings(issue_workspace, remote: true)

      assert remote_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => ["relative/path"],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      read_only_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}}
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "remote workspace lifecycle uses ssh host aliases from worker config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-WS"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run",
        hook_before_remove: "echo before-remove"
      )

      assert Config.settings!().worker.ssh_hosts == ["worker-01:2200"]
      assert Config.settings!().workspace.root == workspace_root
      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_before_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_after_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.remove_issue_workspaces("MT-SSH-WS", "worker-01:2200")

      trace = File.read!(trace_file)
      assert trace =~ "-p 2200 worker-01 bash -lc"
      assert trace =~ "__SYMPHONY_WORKSPACE__"
      assert trace =~ "~/.symphony-remote-workspaces/MT-SSH-WS"
      assert trace =~ "${workspace#~/}"
      assert trace =~ "echo before-run"
      assert trace =~ "echo after-run"
      assert trace =~ "echo before-remove"
      assert trace =~ "rm -rf"
      assert trace =~ workspace_path
    after
      File.rm_rf(test_root)
    end
  end
end
