defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress"]

    assert config.tracker.terminal_states == [
             "Closed",
             "Cancelled",
             "Canceled",
             "Duplicate",
             "Done"
           ]

    assert config.tracker.assignee == nil
    assert config.tracker.issue_allowlist == []
    assert config.agent.max_turns == 20

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "definitely-not-valid"
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "tracker issue allowlist restricts dispatch candidates" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_issue_allowlist: ["COD-200", "issue-explicit"]
    )

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    allowed_by_identifier = %Issue{
      id: "issue-other",
      identifier: "COD-200",
      title: "Allowed by identifier",
      state: "In Progress"
    }

    allowed_by_id = %Issue{
      id: "issue-explicit",
      identifier: "COD-201",
      title: "Allowed by id",
      state: "In Progress"
    }

    blocked = %Issue{
      id: "issue-blocked",
      identifier: "COD-202",
      title: "Not allowlisted",
      state: "In Progress"
    }

    assert Orchestrator.should_dispatch_issue_for_test(allowed_by_identifier, state)
    assert Orchestrator.should_dispatch_issue_for_test(allowed_by_id, state)
    refute Orchestrator.should_dispatch_issue_for_test(blocked, state)
  end

  test "dependency gate blocks active issues with non-terminal blockers" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    blocked = %Issue{
      id: "issue-blocked",
      identifier: "COD-203",
      title: "Blocked implementation",
      state: "In Progress",
      blocked_by: [%{id: "issue-contract", identifier: "COD-202", state: "In Progress"}]
    }

    unblocked = %Issue{
      id: "issue-unblocked",
      identifier: "COD-204",
      title: "Unblocked implementation",
      state: "In Progress",
      blocked_by: [%{id: "issue-contract", identifier: "COD-202", state: "Done"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(blocked, state)
    assert Orchestrator.should_dispatch_issue_for_test(unblocked, state)
  end

  test "dispatch gate allows retry corrections that target root config files" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-root-config-retry-correction-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-root-config-retry",
        identifier: "COD-ROOTCONFIG",
        title: "Root config retry correction",
        state: "Rework"
      }

      workspace = Path.join(workspace_root, "COD-ROOTCONFIG")
      inbox = Path.join(workspace, ".orocsy/delivery/inbox")
      File.mkdir_p!(inbox)

      File.write!(
        Path.join(inbox, "correction_20260706000000_root_config.json"),
        Jason.encode!(%{
          "correction_id" => "correction_20260706000000_root_config",
          "status" => "open",
          "next_action" => "retry",
          "resolved_at" => nil,
          "summary" => "Fix package.json test script.",
          "required_corrections" => ["Update package.json and rerun validation."]
        })
      )

      state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "worker runtime info replaces a preselected remote host with the actual local host" do
    issue_id = "issue-actual-local-worker"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          worker_host: "worker-a",
          workspace_path: "/remote/workspace"
        }
      }
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_info(
               {:worker_runtime_info, issue_id, %{worker_host: nil, workspace_path: "/local/workspace"}},
               state
             )

    assert updated_state.running[issue_id].worker_host == nil
    assert updated_state.running[issue_id].workspace_path == "/local/workspace"
  end

  test "dispatch gate treats empty retry fingerprint as legacy retry correction" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-empty-fingerprint-retry-correction-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-empty-fingerprint-retry",
        identifier: "COD-EMPTY-FINGERPRINT",
        title: "Empty fingerprint retry correction",
        state: "Rework"
      }

      workspace = Path.join(workspace_root, issue.identifier)
      inbox = Path.join(workspace, ".orocsy/delivery/inbox")
      File.mkdir_p!(inbox)

      File.write!(
        Path.join(inbox, "correction_20260709000000_empty_fingerprint.json"),
        Jason.encode!(%{
          "correction_id" => "correction_20260709000000_empty_fingerprint",
          "status" => "open",
          "source" => "symphony.runtime.scope-access",
          "next_action" => "retry",
          "resolved_at" => nil,
          "summary" => "Fix package.json test script.",
          "required_corrections" => ["Update package.json and rerun validation."],
          "guard" => %{"retry_fingerprint" => %{}}
        })
      )

      state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "dispatch gate parks browser-provider corrections for runtime controller handling" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-browser-controller-correction-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-browser-controller-correction",
        identifier: "COD-BROWSER-CONTROLLER",
        title: "Browser controller correction",
        state: "Rework"
      }

      workspace = Path.join(workspace_root, issue.identifier)
      inbox = Path.join(workspace, ".orocsy/delivery/inbox")
      File.mkdir_p!(inbox)

      File.write!(
        Path.join(inbox, "correction_20260723000000_browser.json"),
        Jason.encode!(%{
          "correction_id" => "correction_20260723000000_browser",
          "status" => "open",
          "source" => "codex.review-rework",
          "next_action" => "retry",
          "resolved_at" => nil,
          "summary" => "Focused Playwright validation could not launch Chrome",
          "findings" => [
            "Chrome process did exit: signal=SIGABRT while tests/e2e/desktop-guest-setup.spec.ts was starting."
          ],
          "required_corrections" => [
            "Retry the exact focused Playwright command outside the worker sandbox."
          ]
        })
      )

      state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "dispatch gate allows actionable validation-controller browser corrections" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-controller-browser-correction-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-controller-browser-correction",
        identifier: "COD-CONTROLLER-BROWSER",
        title: "Controller browser correction",
        state: "Rework"
      }

      workspace = Path.join(workspace_root, issue.identifier)
      inbox = Path.join(workspace, ".orocsy/delivery/inbox")
      File.mkdir_p!(inbox)

      File.write!(
        Path.join(inbox, "correction_20260723000001_controller_browser.json"),
        Jason.encode!(%{
          "correction_id" => "correction_20260723000001_controller_browser",
          "status" => "open",
          "source" => "symphony.runtime.validation-controller",
          "next_action" => "retry",
          "resolved_at" => nil,
          "created_at" => "2026-07-23T00:00:01Z",
          "summary" => "Review-rework authoritative Playwright validation failed",
          "findings" => [
            "tests/e2e/desktop-guest-setup.spec.ts failed after Chrome launched."
          ],
          "required_corrections" => [
            "Fix tests/e2e/desktop-guest-setup.spec.ts and request controller certification."
          ]
        })
      )

      File.write!(
        Path.join(inbox, "correction_20260722000000_stale_provider.json"),
        Jason.encode!(%{
          "correction_id" => "correction_20260722000000_stale_provider",
          "status" => "open",
          "source" => "codex.review-rework",
          "next_action" => "retry",
          "resolved_at" => nil,
          "created_at" => "2026-07-22T00:00:00Z",
          "summary" => "Focused Playwright validation could not launch Chrome",
          "findings" => ["Chrome exited with SIGABRT before the test executed."],
          "required_corrections" => ["Retry outside the worker sandbox."]
        })
      )

      state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

      assert Orchestrator.should_dispatch_issue_for_test(issue, state)

      File.write!(
        Path.join(inbox, "correction_20260724000000_current_provider.json"),
        Jason.encode!(%{
          "correction_id" => "correction_20260724000000_current_provider",
          "status" => "open",
          "source" => "codex.review-rework",
          "next_action" => "retry",
          "resolved_at" => nil,
          "created_at" => "2026-07-23T00:00:01Z",
          "summary" => "Focused Playwright validation could not launch Chrome",
          "findings" => ["Chrome exited with SIGABRT before the test executed."],
          "required_corrections" => ["Retry outside the worker sandbox."]
        })
      )

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "dispatch gate treats a launched Chromium sandbox-behavior failure as actionable product rework" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-browser-product-correction-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-browser-product-correction",
        identifier: "COD-BROWSER-PRODUCT",
        title: "Browser product correction",
        state: "Rework"
      }

      inbox = Path.join([workspace_root, issue.identifier, ".orocsy/delivery/inbox"])
      File.mkdir_p!(inbox)

      correction = %{
        "correction_id" => "correction_20260723000002_product",
        "status" => "open",
        "source" => "codex.review-rework",
        "next_action" => "retry",
        "resolved_at" => nil,
        "summary" => "Playwright Chromium sandbox behavior test failed",
        "findings" => [
          "tests/e2e/browser-sandbox.spec.ts failed after Chrome launched and the application assertion failed."
        ],
        "required_corrections" => [
          "Fix tests/e2e/browser-sandbox.spec.ts and rerun the focused test."
        ]
      }

      File.write!(
        Path.join(inbox, "correction_20260723000002_product.json"),
        Jason.encode!(correction)
      )

      refute SymphonyElixir.DispatchPreflight.playwright_browser_correction?(correction)

      state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "browser SIGABRT after test startup remains actionable product rework" do
    correction = %{
      "summary" => "Playwright browser process crashed during an application assertion",
      "findings" => [
        "Chrome process did exit: signal=SIGABRT after the page entered its ready state."
      ],
      "required_corrections" => [
        "Fix tests/e2e/browser-sandbox.spec.ts and rerun the focused test."
      ]
    }

    refute SymphonyElixir.DispatchPreflight.playwright_browser_correction?(correction)
  end

  test "open stale scope correction prevents redispatch when head and policy hash are unchanged" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stale-scope-correction-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-stale-scope",
        identifier: "COD-STALE-SCOPE",
        title: "Stale scope correction",
        state: "Rework"
      }

      workspace = Path.join(workspace_root, issue.identifier)
      write_scope_retry_preflight!(workspace, issue.identifier, "head-1", "sha256:policy-a")
      write_scope_retry_correction!(workspace, issue, "head-1", "sha256:policy-a")

      state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "open retry correction with changed policy hash allows one retry" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stale-scope-policy-change-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-stale-scope-policy",
        identifier: "COD-STALE-POLICY",
        title: "Stale scope correction policy changed",
        state: "Rework"
      }

      workspace = Path.join(workspace_root, issue.identifier)
      write_scope_retry_preflight!(workspace, issue.identifier, "head-1", "sha256:policy-a")
      write_scope_retry_correction!(workspace, issue, "head-1", "sha256:policy-a")

      state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)

      write_scope_retry_preflight!(workspace, issue.identifier, "head-1", "sha256:policy-b")

      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "stored retry fingerprint compares against live git head when preflight is stale" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stale-scope-live-head-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-stale-scope-live-head",
        identifier: "COD-STALE-LIVE-HEAD",
        title: "Stale scope correction live head changed",
        state: "Rework"
      }

      workspace = Path.join(workspace_root, issue.identifier)
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["config", "user.email", "symphony@example.test"], cd: workspace)
      {_output, 0} = System.cmd("git", ["config", "user.name", "Symphony Test"], cd: workspace)
      File.write!(Path.join(workspace, "README.md"), "# Test\n")
      {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      write_scope_retry_preflight!(workspace, issue.identifier, "stale-preflight-head", "sha256:policy-a")
      write_scope_retry_correction!(workspace, issue, "stale-preflight-head", "sha256:policy-a")

      state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "stored retry fingerprint ignores consumed turn policy patches" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stale-scope-turn-patch-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-stale-scope-turn-patch",
        identifier: "COD-STALE-TURN-PATCH",
        title: "Stale scope correction with consumed turn patch",
        state: "Rework"
      }

      workspace = Path.join(workspace_root, issue.identifier)

      base_bundle =
        SymphonyElixir.IssueRequirements.refresh_scope_bundle_hash(%{
          "issue" => issue.identifier,
          "write_scope" => [
            %{
              "path" => "src/features/swipe/SwipeExperience.tsx",
              "source" => "test.write_scope",
              "operation" => "write",
              "expires" => "branch"
            }
          ],
          "read_context" => [],
          "conflict_scope" => [],
          "denied_scope" => []
        })

      turn_patch_bundle =
        base_bundle
        |> Map.update!("read_context", fn entries ->
          entries ++
            [
              %{
                "path" => "src/features/landing/GuestStartScreen.tsx",
                "source" => "scope_access.auto.direct_import",
                "operation" => "read",
                "expires" => "turn",
                "policy_patch_id" => "scope_access_read_guest_start"
              }
            ]
        end)
        |> SymphonyElixir.IssueRequirements.refresh_scope_bundle_hash()

      write_scope_retry_preflight!(workspace, issue.identifier, "head-1", turn_patch_bundle["policy_hash"], turn_patch_bundle)
      write_scope_retry_correction!(workspace, issue, "head-1", base_bundle["policy_hash"])

      state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "stored retry fingerprint parks when current preflight cannot be read" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stale-scope-missing-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-stale-scope-missing-preflight",
        identifier: "COD-STALE-MISSING-PREFLIGHT",
        title: "Stale scope missing preflight",
        state: "Rework"
      }

      workspace = Path.join(workspace_root, issue.identifier)
      write_scope_retry_correction!(workspace, issue, "head-1", "sha256:policy-a")

      state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "same blocked access fingerprint is parked without starting a worker" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stale-scope-worker-park-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-stale-scope-worker",
        identifier: "COD-STALE-WORKER",
        title: "Stale scope worker park",
        state: "Rework"
      }

      workspace = Path.join(workspace_root, issue.identifier)
      write_scope_retry_preflight!(workspace, issue.identifier, "head-1", "sha256:policy-a")
      write_scope_retry_correction!(workspace, issue, "head-1", "sha256:policy-a")

      state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
      assert state.running == %{}
    after
      File.rm_rf(workspace_root)
    end
  end

  test "dispatch gate parks Rework while a fresh Codex review request is pending" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress", "Rework"],
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy",
      review_monitor_rework_state: "Rework"
    )

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    issue = %Issue{
      id: "issue-review-pending-dispatch",
      identifier: "COD-181",
      title: "Saved Recipe Routes",
      state: "Rework",
      branch_name: "orocsy/cod-181-savedprofile-miu-saved-recipe-routes"
    }

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
          {:ok,
           [
             %{
               "number" => 28,
               "html_url" => "https://github.com/acme/nutribuddy/pull/28",
               "head" => %{
                 "sha" => "999e84e6549a6fefd8e1f9d823a208a822f8c70a",
                 "ref" => "orocsy/cod-181-savedprofile-miu-saved-recipe-routes"
               }
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/28/comments" ->
          {:ok,
           [
             %{
               "body" => "Preserve the existing chatId when re-saving.",
               "commit_id" => "999e84e6549a6fefd8e1f9d823a208a822f8c70a",
               "path" => "src/lib/db/saved-recipe-store.ts",
               "line" => 63,
               "created_at" => "2026-05-18T04:17:07Z",
               "html_url" => "https://github.com/acme/nutribuddy/pull/28#discussion"
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/28/reviews" ->
          {:ok, []}

        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/28/comments?") ->
          {:ok,
           [
             %{
               "body" => "@codex review\n\nFresh review requested for review-rework commit 999e84e.",
               "created_at" => "2026-05-18T04:20:05Z"
             }
           ]}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch gate parks Rework with empty feedback while a fresh Codex review request is pending" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress", "Rework"],
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy",
      review_monitor_rework_state: "Rework"
    )

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    issue = %Issue{
      id: "issue-review-pending-empty-feedback-dispatch",
      identifier: "COD-199",
      title: "Auth Migration Integration",
      state: "Rework",
      branch_name: "orocsy/feature-auth-migration-integration"
    }

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
          {:ok,
           [
             %{
               "number" => 54,
               "html_url" => "https://github.com/acme/nutribuddy/pull/54",
               "head" => %{
                 "sha" => "2bd1ee321e7e813e5636b3fbfbd7b80e09ede26b",
                 "ref" => "orocsy/feature-auth-migration-integration"
               }
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/54/comments" ->
          {:ok, []}

        endpoint == "repos/acme/nutribuddy/pulls/54/reviews" ->
          {:ok, []}

        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/54/comments?") ->
          {:ok,
           [
             %{
               "body" => "@codex review\n\nFresh review requested for pushed handoff commit 2bd1ee3.",
               "created_at" => "2026-05-23T17:56:30Z"
             }
           ]}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch gate allows Rework when feedback is newer than latest Codex review request" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress", "Rework"],
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy",
      review_monitor_rework_state: "Rework"
    )

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}

    issue = %Issue{
      id: "issue-review-newer-feedback-dispatch",
      identifier: "COD-181",
      title: "Saved Recipe Routes",
      state: "Rework",
      branch_name: "orocsy/cod-181-savedprofile-miu-saved-recipe-routes"
    }

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
          {:ok,
           [
             %{
               "number" => 28,
               "html_url" => "https://github.com/acme/nutribuddy/pull/28",
               "head" => %{
                 "sha" => "999e84e6549a6fefd8e1f9d823a208a822f8c70a",
                 "ref" => "orocsy/cod-181-savedprofile-miu-saved-recipe-routes"
               }
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/28/comments" ->
          {:ok,
           [
             %{
               "body" => "New current-head feedback after the review request.",
               "commit_id" => "999e84e6549a6fefd8e1f9d823a208a822f8c70a",
               "path" => "src/lib/db/saved-recipe-store.ts",
               "line" => 63,
               "created_at" => "2026-05-18T04:22:00Z",
               "html_url" => "https://github.com/acme/nutribuddy/pull/28#discussion"
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/28/reviews" ->
          {:ok, []}

        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/28/comments?") ->
          {:ok,
           [
             %{
               "body" => "@codex review\n\nFresh review requested for review-rework commit 999e84e.",
               "created_at" => "2026-05-18T04:20:05Z"
             }
           ]}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch gate allows Rework when body-level Codex review feedback is newer than request" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress", "Rework"],
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy",
      review_monitor_rework_state: "Rework"
    )

    state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new()}
    head_sha = "345f6490d11ba066a69e2ad3776a06ea95a87b66"

    issue = %Issue{
      id: "issue-body-review-feedback-dispatch",
      identifier: "COD-199",
      title: "Auth Integration Check",
      state: "Rework",
      branch_name: "orocsy/feature-auth-migration-integration"
    }

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
          {:ok,
           [
             %{
               "number" => 54,
               "html_url" => "https://github.com/acme/nutribuddy/pull/54",
               "head" => %{
                 "sha" => head_sha,
                 "ref" => "orocsy/feature-auth-migration-integration"
               }
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/54/comments" ->
          {:ok, []}

        endpoint == "repos/acme/nutribuddy/pulls/54/reviews" ->
          {:ok,
           [
             %{
               "state" => "COMMENTED",
               "commit_id" => head_sha,
               "submitted_at" => "2026-05-23T19:15:28Z",
               "html_url" => "https://github.com/acme/nutribuddy/pull/54#pullrequestreview-1",
               "body" => """
               ### Codex Review

               https://github.com/acme/nutribuddy/blob/#{head_sha}/src/lib/server/recipe-chats.ts#L524-L527
               **Create post-signup chats with authenticated ownership**

               This route always creates chats as a guest after signup.
               """
             }
           ]}

        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/54/comments?") ->
          {:ok,
           [
             %{
               "body" => "@codex review\n\nFresh review requested for review-rework commit 345f649.",
               "created_at" => "2026-05-23T19:09:15Z"
             }
           ]}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
      {:ok,
       %{
         "data" => %{
           "repository" => %{
             "pullRequest" => %{
               "headRefOid" => head_sha,
               "reviewThreads" => %{
                 "nodes" => [
                   %{
                     "isResolved" => false,
                     "isOutdated" => false,
                     "comments" => %{
                       "nodes" => [
                         %{
                           "body" => "Older current-head thread feedback.",
                           "path" => "src/features/swipe/SwipeDeck.tsx",
                           "line" => 274,
                           "createdAt" => "2026-05-23T18:51:40Z",
                           "url" => "https://github.com/acme/nutribuddy/pull/54#discussion"
                         }
                       ]
                     }
                   }
                 ],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }
       }}
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_api_runner)
      Application.delete_env(:symphony_elixir, :github_graphql_runner)
    end)

    assert {:ok, %{feedback: feedback}} =
             SymphonyElixir.ReviewMonitor.inspect_issue(issue, %{repo: "acme/nutribuddy"})

    assert Enum.any?(feedback, fn
             %{
               type: :review,
               payload: %{"path" => "src/lib/server/recipe-chats.ts", "line" => 524}
             } ->
               true

             _ ->
               false
           end)

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert is_binary(Map.get(tracker, "project_slug"))
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)

    assert Map.get(hooks, "after_create") =~
             "git clone --depth 1 https://github.com/openai/symphony ."

    assert Map.get(hooks, "after_create") =~ "cd elixir && mise trust"
    assert Map.get(hooks, "after_create") =~ "mise exec -- mix deps.get"

    assert Map.get(hooks, "before_remove") =~
             "cd elixir && mise exec -- mix workspace.before_remove"

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path =
      Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")

    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path =
      Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")

    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path =
      Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")

    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok =
               Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "linear project slug normalizes UI slug to slug id" do
    assert Client.normalize_project_slug_id_for_test("nutribuddy-mvp-delivery-e08d1e292a64") ==
             "e08d1e292a64"

    assert Client.normalize_project_slug_id_for_test("e08d1e292a64") == "e08d1e292a64"
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "normal worker exit schedules active-state continuation retry" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    sent_at_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, sent_at_ms, 500, 1_100)
  end

  test "normal worker exit at pushed handoff checkpoint does not schedule continuation retry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-normal-handoff-stop-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      origin = Path.join(test_root, "origin.git")
      issue_id = "issue-review-handoff-stop"
      branch = "orocsy/cod-152-review-handoff"

      File.mkdir_p!(workspace)
      assert {_output, 0} = System.cmd("git", ["init", "--bare", origin], stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["init", "-b", "main"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "README.md"), "ready\n")
      assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Initial"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd("git", ["switch", "-c", branch], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} = System.cmd("git", ["remote", "add", "origin", origin], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["push", "-u", "origin", branch],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/state"))
      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/events"))
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      File.write!(
        Path.join(workspace, ".orocsy/delivery/state/dispatch-preflight.json"),
        Jason.encode!(%{"mode" => "review_rework"}, pretty: true) <> "\n"
      )

      File.write!(
        Path.join(workspace, ".orocsy/delivery/events/events.jsonl"),
        Jason.encode!(%{
          "event" => "gate.post-miu",
          "status" => "passed",
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
        }) <> "\n"
      )

      issue =
        runtime_handoff_issue(%Issue{
          id: issue_id,
          identifier: "COD-152",
          title: "Certified handoff stop",
          description: "Review handoff is ready.",
          state: "Rework",
          branch_name: branch
        })

      issue_runtime_handoff_certificate!(workspace, issue)

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      ref = make_ref()
      orchestrator_name = Module.concat(__MODULE__, :NormalHandoffStopOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "COD-152",
        issue: issue,
        started_at: DateTime.utc_now(),
        workspace_path: workspace
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, ref, :process, self(), :normal})
      Process.sleep(50)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      assert MapSet.member?(state.completed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)
    after
      File.rm_rf(test_root)
    end
  end

  test "abnormal worker exit at pushed handoff checkpoint does not schedule failure retry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-abnormal-handoff-stop-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      origin = Path.join(test_root, "origin.git")
      issue_id = "issue-review-abnormal-handoff-stop"
      branch = "orocsy/cod-199-review-handoff"

      File.mkdir_p!(workspace)
      assert {_output, 0} = System.cmd("git", ["init", "--bare", origin], stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["init", "-b", "main"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "README.md"), "ready\n")
      assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Initial"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd("git", ["switch", "-c", branch], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} = System.cmd("git", ["remote", "add", "origin", origin], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["push", "-u", "origin", branch],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/state"))
      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/events"))
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      File.write!(
        Path.join(workspace, ".orocsy/delivery/state/dispatch-preflight.json"),
        Jason.encode!(%{"mode" => "integration_check"}, pretty: true) <> "\n"
      )

      File.write!(
        Path.join(workspace, ".orocsy/delivery/events/events.jsonl"),
        Jason.encode!(%{
          "event" => "gate.post-miu",
          "status" => "passed",
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
        }) <> "\n"
      )

      issue =
        runtime_handoff_issue(%Issue{
          id: issue_id,
          identifier: "COD-199",
          title: "Certified abnormal handoff stop",
          description: "Review handoff is ready.",
          state: "Rework",
          branch_name: branch
        })

      issue_runtime_handoff_certificate!(workspace, issue)

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      ref = make_ref()
      orchestrator_name = Module.concat(__MODULE__, :AbnormalHandoffStopOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "COD-199",
        issue: issue,
        started_at: DateTime.utc_now(),
        workspace_path: workspace
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, ref, :process, self(), {:shutdown, :codex_app_server_exit}})
      Process.sleep(50)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      assert MapSet.member?(state.completed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)
    after
      File.rm_rf(test_root)
    end
  end

  test "abnormal worker exit at handoff recovery pushed checkpoint does not schedule failure retry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-abnormal-handoff-recovery-stop-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      origin = Path.join(test_root, "origin.git")
      issue_id = "issue-handoff-recovery-abnormal-stop"
      branch = "orocsy/feature-analytics-observability-integration"

      File.mkdir_p!(workspace)
      assert {_output, 0} = System.cmd("git", ["init", "--bare", origin], stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["init", "-b", "main"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "README.md"), "ready\n")
      assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Initial"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd("git", ["switch", "-c", branch], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} = System.cmd("git", ["remote", "add", "origin", origin], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["push", "-u", "origin", branch],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/state"))
      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/events"))
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      File.write!(
        Path.join(workspace, ".orocsy/delivery/state/dispatch-preflight.json"),
        Jason.encode!(%{"mode" => "handoff_recovery"}, pretty: true) <> "\n"
      )

      File.write!(
        Path.join(workspace, ".orocsy/delivery/events/events.jsonl"),
        Jason.encode!(%{
          "event" => "gate.post-miu",
          "status" => "passed",
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
        }) <> "\n"
      )

      issue =
        runtime_handoff_issue(%Issue{
          id: issue_id,
          identifier: "COD-205",
          title: "Certified recovery handoff stop",
          description: "Recovery handoff is ready.",
          state: "Rework",
          branch_name: branch
        })

      issue_runtime_handoff_certificate!(workspace, issue)

      assert AgentRunner.pushed_handoff_stop_for_test(workspace, issue)

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      ref = make_ref()
      orchestrator_name = Module.concat(__MODULE__, :HandoffRecoveryAbnormalStopOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "COD-205",
        issue: issue,
        started_at: DateTime.utc_now(),
        workspace_path: workspace
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(
        pid,
        {:DOWN, ref, :process, self(), {%RuntimeError{message: "Agent run failed after handoff"}, []}}
      )

      Process.sleep(50)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      assert MapSet.member?(state.completed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)
    after
      File.rm_rf(test_root)
    end
  end

  test "normal worker exit with open correction does not schedule continuation retry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-continuation-correction-block-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      assert {:ok, workspace} = Workspace.create_for_issue("MT-568")

      inbox = Path.join(workspace, ".orocsy/delivery/inbox")
      File.mkdir_p!(inbox)

      File.write!(
        Path.join(inbox, "correction_20260511085751_143ab7b0.json"),
        Jason.encode!(%{
          "correction_id" => "correction_20260511085751_143ab7b0",
          "issue" => "MT-568",
          "next_action" => "block",
          "resolved_at" => nil,
          "status" => "open"
        })
      )

      issue_id = "issue-correction-block"
      ref = make_ref()
      orchestrator_name = Module.concat(__MODULE__, :CorrectionBlockContinuationOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "MT-568",
        issue: %Issue{id: issue_id, identifier: "MT-568", state: "In Progress"},
        started_at: DateTime.utc_now(),
        workspace_path: workspace
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, ref, :process, self(), :normal})
      Process.sleep(50)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.completed, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)
    after
      File.rm_rf(test_root)
    end
  end

  test "approval failures park the issue with an Orocsy correction and tracker comment" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-approval-failure-park-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-approval-park"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-APPROVAL",
        state: "In Progress",
        title: "Needs approval",
        description: "Worker should park",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      ref = make_ref()
      orchestrator_name = Module.concat(__MODULE__, :ApprovalFailureParkOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.utc_now(),
        workspace_path: workspace
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      fake_linear_token = "lin" <> "_api_should_not_leak"

      send(
        pid,
        {:DOWN, ref, :process, self(),
         {%RuntimeError{
            message:
              "Agent run failed: {:approval_required, " <>
                inspect(%{
                  "method" => "item/commandExecution/requestApproval",
                  "params" => %{
                    "command" => ~s(/bin/zsh -lc "ps -axo pid,ppid,stat,command | rg 'git push|ssh'"),
                    "reason" => "command failed; retry without sandbox?",
                    "token" => fake_linear_token
                  }
                }) <>
                "}"
          }, []}}
      )

      Process.sleep(50)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.permission"
      assert correction["next_action"] == "block"
      assert Workspace.blocking_correction_in_workspace?(workspace)

      assert_receive {:memory_tracker_comment, ^issue_id, body}
      assert body =~ "parked this issue"
      assert body =~ "permission"
      assert body =~ "Runtime evidence"
      assert body =~ "item/commandExecution/requestApproval"
      assert body =~ "ps -axo pid,ppid,stat,command"
      refute body =~ fake_linear_token
    after
      File.rm_rf(test_root)
    end
  end

  test "provider usage-limit failures park even when a product correction is open" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-provider-usage-limit-park-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-usage-limit-park"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-USAGE-LIMIT",
        state: "Rework",
        title: "Usage limited worker",
        description: "Worker should park provider quota",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, _product_correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "controller-validation",
                 source_status: "failed",
                 summary: "Fix tests/e2e/ui-state-matrix.spec.ts before validation retry",
                 findings: [
                   "tests/e2e/ui-state-matrix.spec.ts still needs a code/test fix."
                 ],
                 required_corrections: [
                   "Edit tests/e2e/ui-state-matrix.spec.ts and rerun focused validation."
                 ],
                 next_action: "retry"
               })

      ref = make_ref()

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.utc_now(),
        workspace_path: workspace
      }

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{issue_id => running_entry},
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      {:noreply, state} =
        Orchestrator.handle_info(
          {:DOWN, ref, :process, self(),
           {%RuntimeError{
              message: ~s(Agent run failed: {:codex_error, %{"error" => %{"codexErrorInfo" => "usageLimitExceeded", "message" => "You've hit your usage limit."}, "willRetry" => false}})
            }, []}},
          state
        )

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)

      corrections =
        workspace
        |> Path.join(".orocsy/delivery/inbox/correction_*.json")
        |> Path.wildcard()
        |> Enum.map(fn path -> path |> File.read!() |> Jason.decode!() end)

      provider_correction =
        Enum.find(corrections, &(&1["source"] == "symphony.runtime.provider-usage-limit"))

      assert provider_correction
      assert provider_correction["next_action"] == "block"
      assert provider_correction["summary"] =~ "usageLimitExceeded"
      assert Workspace.blocking_correction_in_workspace?(workspace)

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
      assert Orchestrator.rescue_open_corrections_for_test([issue], state) == state

      assert_receive {:memory_tracker_comment, ^issue_id, body}
      assert body =~ "provider-usage-limit"
      assert body =~ "usageLimitExceeded"
      refute_receive {:memory_tracker_state_update, ^issue_id, _state}, 50
    after
      File.rm_rf(test_root)
    end
  end

  test "forbidden command failures park even when a retryable product correction is open" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-forbidden-command-park-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-forbidden-command-park"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-FORBIDDEN-COMMAND",
        state: "Rework",
        title: "Forbidden command worker",
        description: "Worker should park command guard failures before redispatch.",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, product_correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "controller-pr103-codex-review",
                 source_status: "failed",
                 summary: "Fix src/features/swipe/SwipeExperience.tsx before validation retry.",
                 findings: [
                   "src/features/swipe/SwipeExperience.tsx still needs a bounded code/test fix."
                 ],
                 required_corrections: [
                   "Edit src/features/swipe/SwipeExperience.tsx and rerun tests/unit/swipe-experience-request.test.ts."
                 ],
                 next_action: "retry"
               })

      ref = make_ref()

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.utc_now(),
        workspace_path: workspace
      }

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{issue_id => running_entry},
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      reason =
        {:forbidden_command, "/bin/zsh -lc 'git diff --stat origin/main -- src/features/swipe/SwipeExperience.tsx src/app/api/cards/handler.ts'",
         "(^|\\s|[\"'])git\\s+diff(\\s|$)(?![^\"'\\n]*--exit-code origin/main HEAD -- src/app/api/cards/handler\\.ts)"}

      {:noreply, state} =
        Orchestrator.handle_info({:DOWN, ref, :process, self(), reason}, state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)

      corrections =
        workspace
        |> Path.join(".orocsy/delivery/inbox/correction_*.json")
        |> Path.wildcard()
        |> Enum.map(fn path -> path |> File.read!() |> Jason.decode!() end)

      assert Enum.any?(
               corrections,
               &(&1["correction_id"] == product_correction["correction_id"] and
                   &1["next_action"] == "retry")
             )

      permission_correction =
        Enum.find(corrections, &(&1["source"] == "symphony.runtime.permission"))

      assert permission_correction
      assert permission_correction["next_action"] == "block"
      assert permission_correction["summary"] =~ "command denied"
      assert Enum.join(permission_correction["findings"], "\n") =~ "forbidden_command"
      assert Workspace.blocking_correction_in_workspace?(workspace)

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)

      assert_receive {:memory_tracker_comment, ^issue_id, body}
      assert body =~ "permission"
      assert body =~ "forbidden_command"
    after
      File.rm_rf(test_root)
    end
  end

  test "retryable worker failures park after the configured retry budget" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-retry-exhaustion-park-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root,
        max_failed_worker_retries: 2
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-timeout-park"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-TIMEOUT",
        state: "In Progress",
        title: "Provider timeout",
        description: "Worker should park after retries",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      ref = make_ref()
      orchestrator_name = Module.concat(__MODULE__, :RetryExhaustionParkOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.utc_now(),
        workspace_path: workspace,
        retry_attempt: 2
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, {:turn_timeout, 3_600_000}}})
      Process.sleep(50)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.environment"
      assert correction["source_status"] == "retry-exhausted"
      assert correction["next_action"] == "retry"
      assert Workspace.blocking_correction_in_workspace?(workspace)

      assert_receive {:memory_tracker_comment, ^issue_id, body}
      assert body =~ "retry-exhausted"
      assert body =~ "agent.max_failed_worker_retries=2"
    after
      File.rm_rf(test_root)
    end
  end

  test "token budget worker failures park immediately without retry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-token-budget-park-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        max_failed_worker_retries: 3
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-token-budget-park"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-TOKEN",
        state: "In Progress",
        title: "Token budget exhausted",
        description: "Worker should park after the live turn budget",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      ref = make_ref()
      orchestrator_name = Module.concat(__MODULE__, :TokenBudgetParkOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.utc_now(),
        workspace_path: workspace
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(
        pid,
        {:DOWN, ref, :process, self(), {%RuntimeError{message: "Agent run failed: {:turn_token_budget_exceeded, 1_500_000}"}, []}}
      )

      Process.sleep(50)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.token-budget"
      assert correction["source_status"] == "blocked"
      assert correction["next_action"] == "block"
      assert Workspace.blocking_correction_in_workspace?(workspace)

      [correction_event] =
        workspace
        |> Path.join(".orocsy/delivery/events/events.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["event"] == "correction.created"))

      assert correction_event["status"] == "open"
      assert correction_event["run_status"] == "blocked"
      assert correction_event["phase"] == "correction"
      assert correction_event["correction_id"] == correction["correction_id"]
      assert correction_event["source"] == "symphony.runtime.token-budget"
      assert correction_event["source_status"] == "blocked"
      assert correction_event["next_action"] == "block"
      assert correction["artifacts"]["json"] in correction_event["artifacts"]

      current_state =
        workspace
        |> Path.join(".orocsy/delivery/state/current.json")
        |> File.read!()
        |> Jason.decode!()

      assert current_state["status"] == "blocked"
      assert current_state["phase"] == "correction"
      assert current_state["last_event_id"] == correction_event["event_id"]

      assert :ok = Workspace.resolve_blocking_corrections_in_workspace(workspace, "Runtime guard fixed and verified.")

      events =
        workspace
        |> Path.join(".orocsy/delivery/events/events.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      [resolved_event] = Enum.filter(events, &(&1["event"] == "correction.resolved"))
      assert resolved_event["status"] == "resolved"
      assert resolved_event["run_status"] == "retry-ready"
      assert resolved_event["correction_id"] == correction["correction_id"]
      assert resolved_event["source"] == "symphony.runtime.token-budget"

      resolved_state =
        workspace
        |> Path.join(".orocsy/delivery/state/current.json")
        |> File.read!()
        |> Jason.decode!()

      assert resolved_state["status"] == "retry-ready"
      assert resolved_state["phase"] == "correction"
      assert resolved_state["last_event_id"] == resolved_event["event_id"]

      resolved_correction = correction_path |> File.read!() |> Jason.decode!()
      assert resolved_correction["status"] == "resolved"
      assert resolved_correction["resolution_summary"] == "Runtime guard fixed and verified."

      assert_receive {:memory_tracker_comment, ^issue_id, body}
      assert body =~ "token-budget"
      assert body =~ "blocked"
    after
      File.rm_rf(test_root)
    end
  end

  test "token budget worker with fresh local handoff progress schedules recovery retry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-token-budget-handoff-retry-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        max_failed_worker_retries: 3
      )

      issue_id = "issue-token-budget-handoff"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-TOKEN-HANDOFF",
        state: "In Progress",
        title: "Token budget after local handoff work",
        description: "Worker should retry through handoff recovery",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      started_at = DateTime.add(DateTime.utc_now(), -10, :second)
      baseline_ts = DateTime.add(started_at, -60, :second) |> DateTime.to_iso8601()

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 env: [{"GIT_AUTHOR_DATE", baseline_ts}, {"GIT_COMMITTER_DATE", baseline_ts}],
                 stderr_to_stdout: true
               )

      assert {_output, 0} = System.cmd("git", ["branch", "-M", "main"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["switch", "-c", "worker"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.write!(Path.join(workspace, "review-fix.txt"), "local handoff work\n")
      assert {_output, 0} = System.cmd("git", ["add", "review-fix.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Fix review feedback"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      ref = make_ref()
      orchestrator_name = Module.concat(__MODULE__, :TokenBudgetHandoffRetryOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        started_at: started_at,
        workspace_path: workspace
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(
        pid,
        {:DOWN, ref, :process, self(), {%RuntimeError{message: "Agent run failed: {:turn_token_budget_exceeded, 1_500_000}"}, []}}
      )

      Process.sleep(50)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.claimed, issue_id)

      assert %{attempt: 1, workspace_path: ^workspace} =
               Map.fetch!(state.retry_attempts, issue_id)

      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "token budget exit after a fresh validated sparse-fetch push does not retry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-token-budget-pushed-handoff-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      origin = Path.join(test_root, "origin.git")
      issue_id = "issue-token-budget-pushed-handoff"
      branch = "orocsy/cod-300-desktop-guest-setup"

      File.mkdir_p!(workspace)
      assert {_output, 0} = System.cmd("git", ["init", "--bare", origin], stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["init", "-b", "main"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "README.md"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace)
      assert {_output, 0} = System.cmd("git", ["commit", "-m", "Baseline"], cd: workspace, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["remote", "add", "origin", origin], cd: workspace)

      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["config", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd("git", ["push", "-u", "origin", "main"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["switch", "-c", branch], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["push", "origin", "HEAD:refs/heads/#{branch}"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["fetch", "origin", "+refs/heads/#{branch}:refs/remotes/origin/#{branch}"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      started_at = DateTime.add(DateTime.utc_now(), -10, :second)
      File.write!(Path.join(workspace, "guest-setup.tsx"), "export const guestSetup = true;\n")
      assert {_output, 0} = System.cmd("git", ["add", "guest-setup.tsx"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Implement guest setup"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd("git", ["push", "-u", "origin", "HEAD"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)

      assert {remote_head, 0} =
               System.cmd("git", ["rev-parse", "refs/remotes/origin/#{branch}"], cd: workspace)

      refute String.trim(head) == String.trim(remote_head)

      assert {live_remote, 0} =
               System.cmd("git", ["ls-remote", "--heads", "origin", "refs/heads/#{branch}"], cd: workspace)

      assert String.starts_with?(live_remote, String.trim(head))

      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/state"))
      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/events"))
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      File.write!(
        Path.join(workspace, ".orocsy/delivery/state/dispatch-preflight.json"),
        Jason.encode!(%{"mode" => "handoff_recovery"}, pretty: true) <> "\n"
      )

      File.write!(
        Path.join(workspace, ".orocsy/delivery/events/events.jsonl"),
        Jason.encode!(%{
          "event" => "tool.finished",
          "status" => "passed",
          "tool" => "vitest",
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
        }) <> "\n"
      )

      issue =
        runtime_handoff_issue(%Issue{
          id: issue_id,
          identifier: "COD-300",
          state: "Rework",
          title: "Desktop guest setup handoff",
          description: "The worker pushed its validated correction.",
          branch_name: branch,
          updated_at: DateTime.add(started_at, -60, :second),
          labels: []
        })

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        max_failed_worker_retries: 3
      )

      issue_runtime_handoff_certificate!(workspace, issue)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      ref = make_ref()
      orchestrator_name = Module.concat(__MODULE__, :TokenBudgetPushedHandoffOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        started_at: started_at,
        workspace_path: workspace
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(
        pid,
        {:DOWN, ref, :process, self(), {%RuntimeError{message: "Agent run failed: {:turn_token_budget_exceeded, 733_209, 700_000}"}, []}}
      )

      Process.sleep(50)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      assert MapSet.member?(state.completed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
      assert Orchestrator.completed_issue_revision_matches_for_test(issue, state)

      reentered_issue = %{issue | updated_at: DateTime.utc_now()}
      refute Orchestrator.completed_issue_revision_matches_for_test(reentered_issue, state)

      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "remote token budget handoff verifies the selected worker workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-token-budget-handoff-#{System.unique_integer([:positive])}"
      )

    previous_ssh = System.get_env("SYMPHONY_SSH_EXECUTABLE")

    on_exit(fn ->
      restore_env("SYMPHONY_SSH_EXECUTABLE", previous_ssh)
    end)

    try do
      workspace = Path.join(test_root, "workspaces/COD-REMOTE-HANDOFF")
      fake_ssh = Path.join(test_root, "fake-ssh")
      branch = "orocsy/cod-remote-handoff"

      File.mkdir_p!(workspace)
      assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace)
      assert {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "README.md"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace)
      assert {_output, 0} = System.cmd("git", ["commit", "-m", "Baseline"], cd: workspace)
      assert {_output, 0} = System.cmd("git", ["switch", "-c", branch], cd: workspace)

      started_at = DateTime.add(DateTime.utc_now(), -10, :second)
      File.write!(Path.join(workspace, "README.md"), "remote handoff\n")
      assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace)
      assert {_output, 0} = System.cmd("git", ["commit", "-m", "Remote handoff"], cd: workspace)

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.join(test_root, "workspaces"),
        review_monitor_enabled: false
      )

      issue =
        runtime_handoff_issue(%Issue{
          id: "issue-remote-token-budget-handoff",
          identifier: "COD-REMOTE-HANDOFF",
          state: "Rework",
          title: "Remote token handoff",
          description: "The remote worker pushed its validated correction.",
          branch_name: branch,
          labels: []
        })

      issue_runtime_handoff_certificate!(workspace, issue)

      File.write!(fake_ssh, """
      #!/bin/sh
      for argument in "$@"; do
        command="$argument"
      done
      exec /bin/bash -c "$command"
      """)

      File.chmod!(fake_ssh, 0o755)
      System.put_env("SYMPHONY_SSH_EXECUTABLE", fake_ssh)

      assert Orchestrator.fresh_clean_pushed_handoff_stop_for_test(
               %{
                 workspace_path: workspace,
                 worker_host: "worker-a",
                 started_at: started_at,
                 issue: issue
               },
               "handoff_recovery"
             )

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        completed: MapSet.new([issue.id]),
        completed_issue_revisions: %{issue.id => {"rework", nil}},
        completed_issue_worker_hosts: %{issue.id => "worker-a"}
      }

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "token budget worker with fresh upstream progress schedules recovery retry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-token-budget-upstream-handoff-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        max_failed_worker_retries: 3
      )

      issue_id = "issue-token-budget-upstream-handoff"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-TOKEN-UPSTREAM",
        state: "In Progress",
        title: "Token budget after remote handoff work",
        description: "Worker should retry when the upstream branch advanced",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      started_at = DateTime.add(DateTime.utc_now(), -10, :second)
      baseline_ts = DateTime.add(started_at, -60, :second) |> DateTime.to_iso8601()

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["config", "core.logAllRefUpdates", "true"], cd: workspace)

      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 env: [{"GIT_AUTHOR_DATE", baseline_ts}, {"GIT_COMMITTER_DATE", baseline_ts}],
                 stderr_to_stdout: true
               )

      assert {_output, 0} = System.cmd("git", ["branch", "-M", "main"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["switch", "-c", "worker"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd("git", ["remote", "add", "origin", "https://example.org/repo.git"], cd: workspace)

      File.write!(Path.join(workspace, "review-fix.txt"), "remote handoff work\n")
      assert {_output, 0} = System.cmd("git", ["add", "review-fix.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Fix review feedback"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      {remote_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["reset", "--hard", "HEAD~1"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["update-ref", "refs/remotes/origin/worker", String.trim(remote_sha)],
                 cd: workspace
               )

      assert {_output, 0} =
               System.cmd("git", ["branch", "--set-upstream-to", "origin/worker"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {counts, 0} =
               System.cmd("git", ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], cd: workspace)

      assert String.trim(counts) == "0\t1"

      ref = make_ref()
      orchestrator_name = Module.concat(__MODULE__, :TokenBudgetUpstreamHandoffRetryOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        started_at: started_at,
        workspace_path: workspace
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(
        pid,
        {:DOWN, ref, :process, self(), {%RuntimeError{message: "Agent run failed: {:turn_token_budget_exceeded, 1_500_000}"}, []}}
      )

      Process.sleep(50)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.claimed, issue_id)

      assert %{attempt: 1, workspace_path: ^workspace} =
               Map.fetch!(state.retry_attempts, issue_id)

      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "high-token worker without durable progress parks with correction" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-no-progress-park-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 10,
        codex_durable_progress_min_tokens: 100
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-no-progress-park"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-NOPROGRESS",
        state: "In Progress",
        title: "No durable progress",
        description: "Worker should park after high tokens without proof of progress",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn ->
        if Process.alive?(worker_pid) do
          Process.exit(worker_pid, :kill)
        end
      end)

      running_entry = %{
        pid: worker_pid,
        ref: nil,
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.add(DateTime.utc_now(), -10, :second),
        workspace_path: workspace,
        codex_total_tokens: 500
      }

      state =
        %Orchestrator.State{
          max_concurrent_agents: 1,
          running: %{issue_id => running_entry},
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }
        |> Orchestrator.reconcile_no_durable_progress_for_test()

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] in [
               "symphony.runtime.no-durable-progress",
               "symphony.runtime.no-durable-progress-handoff"
             ]

      assert correction["source_status"] == "blocked"
      assert correction["next_action"] == "block"
      assert Workspace.blocking_correction_in_workspace?(workspace)

      assert_receive {:memory_tracker_comment, ^issue_id, body}
      assert body =~ "no-durable-progress"
      assert body =~ "configured failure guard"
    after
      File.rm_rf(test_root)
    end
  end

  test "no durable progress correction includes recent worker evidence" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-no-progress-evidence-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 10,
        codex_durable_progress_min_tokens: 100
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-no-progress-evidence"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-NOPROGRESS-EVIDENCE",
        state: "In Progress",
        title: "No durable progress with evidence",
        description: "Correction should preserve the worker's last useful signals",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      running_entry = %{
        pid: nil,
        ref: nil,
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.add(DateTime.utc_now(), -10, :second),
        workspace_path: workspace,
        codex_total_tokens: 500,
        recent_codex_events: [
          "2026-05-15T06:56:12Z event=notification command=corepack pnpm exec tsc outcome=failed detail=zsh:1: command not found: corepack",
          "2026-05-15T06:56:30Z event=notification command=npm run typecheck -- --pretty false outcome=passed"
        ]
      }

      state =
        %Orchestrator.State{
          max_concurrent_agents: 1,
          running: %{issue_id => running_entry},
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }
        |> Orchestrator.reconcile_no_durable_progress_for_test()

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      [evidence | _] = correction["findings"]
      assert evidence =~ "Recent Codex worker evidence"
      assert evidence =~ "corepack pnpm exec tsc"
      assert evidence =~ "command not found: corepack"
      assert evidence =~ "npm run typecheck"
      assert evidence =~ "outcome=passed"

      assert_receive {:memory_tracker_comment, ^issue_id, body}
      assert body =~ "Runtime evidence"
      assert body =~ "corepack"
      assert body =~ "npm run typecheck"
    after
      File.rm_rf(test_root)
    end
  end

  test "stale durable progress from an earlier run still parks" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stale-progress-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 10,
        codex_durable_progress_min_tokens: 100
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-stale-progress"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-STALEPROGRESS",
        state: "In Progress",
        title: "Stale durable progress",
        description: "Worker should park when all durable evidence predates this run",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      stale_ts = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()
      baseline_ts = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 env: [{"GIT_AUTHOR_DATE", baseline_ts}, {"GIT_COMMITTER_DATE", baseline_ts}],
                 stderr_to_stdout: true
               )

      assert {_output, 0} = System.cmd("git", ["branch", "-M", "main"], cd: workspace)

      events_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(events_dir)

      File.write!(
        Path.join(events_dir, "events.jsonl"),
        Jason.encode!(%{"event" => "gate.declared-scope", "status" => "passed", "ts" => stale_ts}) <>
          "\n"
      )

      assert {_output, 0} =
               System.cmd("git", ["add", ".orocsy/delivery/events/events.jsonl"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Record stale durable event"],
                 cd: workspace,
                 env: [{"GIT_AUTHOR_DATE", stale_ts}, {"GIT_COMMITTER_DATE", stale_ts}],
                 stderr_to_stdout: true
               )

      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      orchestrator_name = Module.concat(__MODULE__, :StaleDurableProgressOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(worker_pid) do
          Process.exit(worker_pid, :kill)
        end

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: worker_pid,
        ref: nil,
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.add(DateTime.utc_now(), -10, :second),
        workspace_path: workspace,
        codex_total_tokens: 500
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :run_poll_cycle)

      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.no-durable-progress"
      assert correction["guard"]["quiet_ms"] >= 10
    after
      File.rm_rf(test_root)
    end
  end

  test "no durable progress correction with current PR feedback is rescued into rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-no-progress-rescue-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-152-rescue",
        identifier: "COD-152",
        title: "Swipe feed UI",
        state: "In Progress",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.no-durable-progress",
                 source_status: "blocked",
                 summary: "Worker exceeded durable progress guard.",
                 findings: ["no-durable-progress"],
                 next_action: "block"
               })

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

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      assert_receive {:memory_tracker_state_update, "issue-cod-152-rescue", "Rework"}
      assert_receive {:memory_tracker_comment, "issue-cod-152-rescue", body}
      assert body =~ "review_rework_needed"
      assert body =~ "Rework"
      assert body =~ "pull/4"

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      resolved = correction_path |> File.read!() |> Jason.decode!()
      assert resolved["status"] == "resolved"
      assert resolved["resolution_summary"] =~ "review_rework_needed"
      refute Workspace.blocking_correction_in_workspace?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "no durable progress review rework stays parked when worker retries are disabled" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-no-progress-review-budget-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework",
        max_failed_worker_retries: 0
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-181-review-budget",
        identifier: "COD-181",
        title: "Saved recipe routes",
        state: "Rework",
        branch_name: "orocsy/cod-181-savedprofile-miu-saved-recipe-routes"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.no-durable-progress",
                 source_status: "blocked",
                 summary: "Worker exceeded durable progress guard while fixing review feedback.",
                 findings: ["no-durable-progress"],
                 next_action: "block"
               })

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 28,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/28",
                 "head" => %{
                   "sha" => "c3a597c3c804357f2ad0059d1bea2928385e0ba6",
                   "ref" => "orocsy/cod-181-savedprofile-miu-saved-recipe-routes"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/28/comments" ->
            {:ok,
             [
               %{
                 "body" => "Persist the chat row before saving right swipes.",
                 "commit_id" => "c3a597c3c804357f2ad0059d1bea2928385e0ba6",
                 "path" => "src/app/api/swipes/handler.ts",
                 "line" => 84,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/28#discussion"
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/28/reviews" ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      assert_receive {:memory_tracker_comment, "issue-cod-181-review-budget", body}
      assert body =~ "worker_prompt_defect"
      assert body =~ "agent.max_failed_worker_retries=0"
      refute_receive {:memory_tracker_state_update, "issue-cod-181-review-budget", "Rework"}, 50

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      classified = correction_path |> File.read!() |> Jason.decode!()
      assert classified["status"] == "open"
      assert classified["classification"] == "worker_prompt_defect"
      assert classified["classification_summary"] =~ "agent.max_failed_worker_retries=0"
      assert Workspace.blocking_correction_in_workspace?(workspace)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "token budget handoff correction with current PR feedback is rescued into rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-token-budget-handoff-rescue-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review", "In Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-181-token-budget-handoff",
        identifier: "COD-181",
        title: "Saved/Profile MIU: Saved Recipe Routes",
        state: "Rework",
        branch_name: "orocsy/cod-181-savedprofile-miu-saved-recipe-routes"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.token-budget-handoff",
                 source_status: "retry-exhausted",
                 summary:
                   "Symphony stopped a Codex worker after it exceeded the configured live turn token budget, but the workspace contains fresh local handoff progress from this run. The worker reached retry attempt 1, which exceeds agent.max_failed_worker_retries=0.",
                 findings: [
                   "Agent run failed for issue_id=issue-cod-181-token-budget-handoff issue_identifier=COD-181: {:turn_token_budget_exceeded, 1542669, 1500000}"
                 ],
                 next_action: "retry"
               })

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 28,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/28",
                 "head" => %{
                   "sha" => "326bb9dd518a91bda82d84e05e9fd27f447c8684",
                   "ref" => "orocsy/cod-181-savedprofile-miu-saved-recipe-routes"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/28/comments" ->
            {:ok,
             [
               %{
                 "body" => "Include full saved-list DTO fields.",
                 "commit_id" => "326bb9dd518a91bda82d84e05e9fd27f447c8684",
                 "path" => "src/app/api/saved-recipes/route.ts",
                 "line" => 155,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/28#discussion"
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/28/reviews" ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state

      assert_receive {:memory_tracker_state_update, "issue-cod-181-token-budget-handoff", "Rework"}

      assert_receive {:memory_tracker_comment, "issue-cod-181-token-budget-handoff", body}
      assert body =~ "review_rework_needed"
      assert body =~ "pull/28"

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      resolved = correction_path |> File.read!() |> Jason.decode!()
      assert resolved["status"] == "resolved"
      assert resolved["resolution_summary"] =~ "review_rework_needed"
      refute Workspace.blocking_correction_in_workspace?(workspace)
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "runtime progress rescue preserves unrelated open blocking corrections" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-no-progress-preserve-unrelated-blocker-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-152-preserve-unrelated-blocker",
        identifier: "COD-152",
        title: "Swipe feed UI",
        state: "In Progress",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, runtime_correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.no-durable-progress",
                 source_status: "blocked",
                 summary: "Worker exceeded durable progress guard.",
                 findings: ["no-durable-progress"],
                 next_action: "block"
               })

      assert {:ok, unrelated_correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.environment",
                 source_status: "blocked",
                 summary: "Dependency installation failed with missing permission.",
                 findings: ["permission denied while preparing workspace"],
                 next_action: "block"
               })

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

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state

      assert_receive {:memory_tracker_state_update, "issue-cod-152-preserve-unrelated-blocker", "Rework"}

      runtime_path = Path.join(workspace, runtime_correction["artifacts"]["json"])
      unrelated_path = Path.join(workspace, unrelated_correction["artifacts"]["json"])

      resolved = runtime_path |> File.read!() |> Jason.decode!()
      still_blocked = unrelated_path |> File.read!() |> Jason.decode!()

      assert resolved["status"] == "resolved"
      assert resolved["resolution_summary"] =~ "review_rework_needed"
      assert still_blocked["status"] == "open"
      assert still_blocked["resolved_at"] == nil
      assert still_blocked["resolution_summary"] == ""
      assert Workspace.blocking_correction_in_workspace?(workspace)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "no durable progress correction waits when a newer Codex review request is pending" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-no-progress-review-pending-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-152-review-pending-rescue",
        identifier: "COD-152",
        title: "Swipe feed UI",
        state: "In Progress",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.no-durable-progress",
                 source_status: "blocked",
                 summary: "Worker exceeded durable progress guard after pushing review fixes.",
                 findings: ["no-durable-progress"],
                 next_action: "block"
               })

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
                 "created_at" => "2026-05-15T09:20:00Z",
                 "html_url" => "https://github.com/acme/nutribuddy/pull/4#discussion"
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/4/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/4/comments?") ->
            {:ok,
             [
               %{
                 "body" => "@codex review\n\nFresh review requested after the pushed fix.",
                 "created_at" => "2026-05-15T09:24:37Z",
                 "html_url" => "https://github.com/acme/nutribuddy/pull/4#issuecomment"
               }
             ]}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state

      refute_receive {:memory_tracker_state_update, "issue-cod-152-review-pending-rescue", "Rework"},
                     50

      refute_receive {:memory_tracker_comment, "issue-cod-152-review-pending-rescue", _body}, 50

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      parked = correction_path |> File.read!() |> Jason.decode!()
      assert parked["status"] == "open"
      assert Workspace.blocking_correction_in_workspace?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "no durable progress rescue does not inspect reviews when review monitor is disabled" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-no-progress-review-disabled-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: false,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-168-review-disabled-rescue",
        identifier: "COD-168",
        title: "Recipe chat create route",
        state: "In Progress",
        branch_name: "orocsy/cod-168-recipe-chat-miu-create-route-and-harness",
        description: """
        ## Write Scope
        - src/app/api/recipe-chats/route.ts

        ### MIU 1 - Create Route
        Create the recipe chat route.

        ## Validation
        ```bash
        pnpm test -- tests/integration/recipe-chat-routes.test.ts
        ```
        """
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.no-durable-progress",
                 source_status: "blocked",
                 summary: "Worker exceeded durable progress guard.",
                 findings: ["no-durable-progress"],
                 next_action: "block"
               })

      parent = self()

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        send(parent, {:unexpected_review_inspection, endpoint})
        {:error, {:unexpected_endpoint, endpoint}}
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      assert_receive {:memory_tracker_comment, "issue-cod-168-review-disabled-rescue", body}
      assert body =~ "retry_with_hydrated_requirements"

      refute_receive {:memory_tracker_state_update, "issue-cod-168-review-disabled-rescue", "Rework"},
                     50

      refute_receive {:unexpected_review_inspection, _endpoint}, 50

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      resolved = correction_path |> File.read!() |> Jason.decode!()
      assert resolved["status"] == "resolved"
      assert resolved["resolution_summary"] =~ "retry_with_hydrated_requirements"
    after
      File.rm_rf(test_root)
    end
  end

  test "repeated review rework retries with same dirty handoff progress block instead of redispatch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-stale-dirty-loop-block-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-152-stale-dirty-review-loop",
        identifier: "COD-152",
        title: "Swipe feed UI and mutation flow",
        state: "Rework",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      dirty_path = Path.join(workspace, "src/features/swipe/SwipeDeck.tsx")
      File.mkdir_p!(Path.dirname(dirty_path))
      File.write!(dirty_path, "baseline swipe deck\n")

      assert {_output, 0} =
               System.cmd("git", ["add", "baseline.txt", "src/features/swipe/SwipeDeck.tsx"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.write!(dirty_path, "dirty review fix from an earlier turn\n")

      stale_progress_time =
        DateTime.utc_now()
        |> DateTime.add(-240, :second)
        |> DateTime.to_naive()
        |> NaiveDateTime.to_erl()

      File.touch!(dirty_path, stale_progress_time)

      for attempt <- 1..2 do
        assert {:ok, _correction} =
                 Workspace.create_correction_in_workspace(workspace, issue, %{
                   source: "symphony.runtime.no-durable-progress-handoff",
                   source_status: "retryable",
                   summary: "Retry #{attempt} for stale dirty handoff progress.",
                   findings: ["no-durable-progress"],
                   next_action: "retry"
                 })

        if attempt == 1 do
          assert :ok =
                   Workspace.resolve_blocking_corrections_in_workspace(
                     workspace,
                     "review_rework_needed: PR #4 has current-head review feedback."
                   )
        end
      end

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 4,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/4",
                 "head" => %{
                   "sha" => "dab63020bf449fb776279c0f0905c79fc3d37ba3",
                   "ref" => "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/4/comments" ->
            {:ok,
             [
               %{
                 "body" => "Open the recipe flow on accepted right swipes.",
                 "commit_id" => "dab63020bf449fb776279c0f0905c79fc3d37ba3",
                 "path" => "src/features/swipe/SwipeDeck.tsx",
                 "line" => 81,
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

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      assert_receive {:memory_tracker_comment, "issue-cod-152-stale-dirty-review-loop", body}
      assert body =~ "worker_prompt_defect"
      assert body =~ "Prior review-rework retries"
      assert body =~ "pull/4"

      classified =
        workspace
        |> Workspace.open_blocking_corrections_in_workspace()
        |> Enum.find(&(&1["classification"] == "worker_prompt_defect"))

      assert classified
      assert classified["classification_summary"] =~ "repeated review-rework"
      assert Workspace.blocking_correction_in_workspace?(workspace)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "repeated review rework retries without workspace progress synthesize a worker prompt defect block" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-loop-block-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-152-review-loop",
        identifier: "COD-152",
        title: "Swipe feed UI and mutation flow",
        state: "Rework",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      for attempt <- 1..2 do
        assert {:ok, _correction} =
                 Workspace.create_correction_in_workspace(workspace, issue, %{
                   source: "symphony.runtime.missing-first-durable-event",
                   source_status: "blocked",
                   summary: "Worker exceeded the first durable Orocsy progress event guard.",
                   findings: ["{:missing_first_durable_event, #{attempt}, 148037, 120000}"],
                   next_action: "block"
                 })

        assert :ok =
                 Workspace.resolve_blocking_corrections_in_workspace(
                   workspace,
                   "review_rework_needed: PR #4 has current-head review feedback."
                 )
      end

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 4,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/4",
                 "head" => %{
                   "sha" => "dab63020bf449fb776279c0f0905c79fc3d37ba3",
                   "ref" => "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/4/comments" ->
            {:ok,
             [
               %{
                 "body" => "Seed the gate from loaded guest limit.",
                 "commit_id" => "dab63020bf449fb776279c0f0905c79fc3d37ba3",
                 "path" => "src/features/swipe/SwipeDeck.tsx",
                 "line" => 47,
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

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      assert_receive {:memory_tracker_comment, "issue-cod-152-review-loop", body}
      assert body =~ "worker_prompt_defect"
      assert body =~ "Prior review-rework retries"
      assert body =~ "pull/4"

      classified =
        workspace
        |> Workspace.open_blocking_corrections_in_workspace()
        |> Enum.find(&(&1["classification"] == "worker_prompt_defect"))

      assert classified
      assert classified["source"] == "symphony.runtime.review-rework-retry-loop"
      assert classified["classification"] == "worker_prompt_defect"
      assert classified["classification_summary"] =~ "repeated review-rework"
      assert Workspace.blocking_correction_in_workspace?(workspace)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "review monitor does not repeat rework comments when issue is already in rework" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy",
      review_monitor_states: ["Human Review"],
      review_monitor_rework_state: "Rework"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue = %Issue{
      id: "issue-cod-152-review-monitor-dedupe",
      identifier: "COD-152",
      title: "Swipe feed UI and mutation flow",
      state: "Rework",
      branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      {:error, {:unexpected_endpoint, endpoint}}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

    assert :ok = SymphonyElixir.ReviewMonitor.run_once()

    refute_receive {:memory_tracker_state_update, "issue-cod-152-review-monitor-dedupe", "Rework"},
                   50

    refute_receive {:memory_tracker_comment, "issue-cod-152-review-monitor-dedupe", _body}, 50
  end

  test "review monitor requests missing Codex review for clean Human Review PR" do
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy",
      review_monitor_states: ["Human Review"],
      review_monitor_rework_state: "Rework"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue = %Issue{
      id: "issue-cod-187-missing-review-request",
      identifier: "COD-187",
      title: "Recipe chat provider selection specs",
      state: "Human Review",
      branch_name: "orocsy/cod-187-provider-selection"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      send(parent, {:github_get, endpoint})

      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
          {:ok,
           [
             %{
               "number" => 29,
               "html_url" => "https://github.com/acme/nutribuddy/pull/29",
               "head" => %{
                 "sha" => "clean-review-head",
                 "ref" => "orocsy/cod-187-provider-selection"
               }
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/29/comments" ->
          {:ok, []}

        endpoint == "repos/acme/nutribuddy/pulls/29/reviews" ->
          {:ok, []}

        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/29/comments?") ->
          {:ok, []}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    Application.put_env(:symphony_elixir, :github_api_post_runner, fn endpoint, fields ->
      send(parent, {:github_post, endpoint, fields})
      {:ok, %{"id" => 123, "body" => fields["body"]}}
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_api_runner)
      Application.delete_env(:symphony_elixir, :github_api_post_runner)
    end)

    assert :ok = SymphonyElixir.ReviewMonitor.run_once()

    assert_receive {:github_post, "repos/acme/nutribuddy/issues/29/comments", %{"body" => body}}
    assert body =~ "@codex review"
    assert body =~ "COD-187"
    assert body =~ "no Codex review request"

    assert_receive {:memory_tracker_comment, "issue-cod-187-missing-review-request", comment}
    assert comment =~ "requested the missing Codex PR review"
    assert comment =~ "pull/29"

    refute_receive {:memory_tracker_state_update, "issue-cod-187-missing-review-request", "Rework"},
                   50
  end

  test "review monitor moves Human Review PR with dirty mergeability to rework" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy",
      review_monitor_states: ["Human Review"],
      review_monitor_rework_state: "Rework",
      review_monitor_request_stale_after_ms: 600_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    head_sha = "1aebf87ed6ffedf7134581baa6d79c287712fcea"

    issue = %Issue{
      id: "issue-cod-266-dirty-mergeability",
      identifier: "COD-266",
      title: "Send guest safety draft on first cards load and retry",
      state: "Human Review",
      branch_name: "orocsy/cod-246-preference-miu-guest-setup-controls"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
          {:ok,
           [
             %{
               "number" => 103,
               "html_url" => "https://github.com/acme/nutribuddy/pull/103",
               "head" => %{
                 "sha" => head_sha,
                 "ref" => "orocsy/cod-246-preference-miu-guest-setup-controls"
               }
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/103" ->
          {:ok,
           %{
             "number" => 103,
             "html_url" => "https://github.com/acme/nutribuddy/pull/103",
             "mergeable" => false,
             "mergeable_state" => "dirty",
             "head" => %{
               "sha" => head_sha,
               "ref" => "orocsy/cod-246-preference-miu-guest-setup-controls"
             }
           }}

        endpoint == "repos/acme/nutribuddy/pulls/103/comments" ->
          {:ok, []}

        endpoint == "repos/acme/nutribuddy/pulls/103/reviews" ->
          {:ok, []}

        endpoint == "repos/acme/nutribuddy/commits/#{head_sha}" ->
          {:ok, %{"commit" => %{"committer" => %{"date" => "2026-07-07T02:41:00Z"}}}}

        String.starts_with?(endpoint, "repos/acme/nutribuddy/commits/#{head_sha}/check-runs?") ->
          {:ok, %{"check_runs" => []}}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_api_runner)
    end)

    assert :ok = SymphonyElixir.ReviewMonitor.run_once()

    assert_receive {:memory_tracker_state_update, "issue-cod-266-dirty-mergeability", "Rework"}
    assert_receive {:memory_tracker_comment, "issue-cod-266-dirty-mergeability", comment}
    assert comment =~ "review_rework_needed"
    assert comment =~ "PR mergeability"
    assert comment =~ "mergeable_state=dirty"
    assert comment =~ "pull/103"
  end

  test "review monitor moves Human Review PR with failed current-head check to rework" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy",
      review_monitor_states: ["Human Review"],
      review_monitor_rework_state: "Rework"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    head_sha = "52b57fa160c80351278fdf5f47db5db8e066fd6c"

    issue = %Issue{
      id: "issue-cod-261-failed-check",
      identifier: "COD-261",
      title: "UI State E2E TDD: Route Interaction Matrix",
      state: "Human Review",
      branch_name: "orocsy/cod-261-ui-state-e2e-tdd-route-interaction-matrix"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
          {:ok,
           [
             %{
               "number" => 101,
               "html_url" => "https://github.com/acme/nutribuddy/pull/101",
               "head" => %{
                 "sha" => head_sha,
                 "ref" => "orocsy/cod-261-ui-state-e2e-tdd-route-interaction-matrix"
               }
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/101" ->
          {:ok,
           %{
             "number" => 101,
             "html_url" => "https://github.com/acme/nutribuddy/pull/101",
             "head" => %{
               "sha" => head_sha,
               "ref" => "orocsy/cod-261-ui-state-e2e-tdd-route-interaction-matrix"
             }
           }}

        endpoint == "repos/acme/nutribuddy/pulls/101/comments" ->
          {:ok, []}

        endpoint == "repos/acme/nutribuddy/pulls/101/reviews" ->
          {:ok, []}

        endpoint == "repos/acme/nutribuddy/commits/#{head_sha}" ->
          {:ok, %{"commit" => %{"committer" => %{"date" => "2026-06-26T07:41:00Z"}}}}

        String.starts_with?(endpoint, "repos/acme/nutribuddy/commits/#{head_sha}/check-runs?") ->
          {:ok,
           %{
             "check_runs" => [
               %{
                 "name" => "Lint, typecheck, test, build, and smoke",
                 "status" => "completed",
                 "conclusion" => "failure",
                 "completed_at" => "2026-06-26T07:45:45Z",
                 "details_url" => "https://github.com/acme/nutribuddy/actions/runs/28224480033/job/83613067033",
                 "output" => %{
                   "title" => "pnpm e2e failed",
                   "summary" => "ui-state-matrix.spec.ts line 116 timed out."
                 }
               },
               %{
                 "name" => "optional smoke",
                 "status" => "completed",
                 "conclusion" => "success",
                 "completed_at" => "2026-06-26T07:45:45Z"
               }
             ]
           }}

        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/101/comments?") ->
          {:ok,
           [
             %{
               "body" => "@codex review",
               "created_at" => "2026-06-26T07:42:37Z"
             }
           ]}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

    assert :ok = SymphonyElixir.ReviewMonitor.run_once()

    assert_receive {:memory_tracker_state_update, "issue-cod-261-failed-check", "Rework"}
    assert_receive {:memory_tracker_comment, "issue-cod-261-failed-check", body}
    assert body =~ "Lint, typecheck, test, build, and smoke failure"
    assert body =~ "pnpm e2e failed"
    assert body =~ "actions/runs/28224480033"
  end

  test "review monitor advances clean Codex result from secondary review state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy",
      review_monitor_states: ["Human Review", "In Review"],
      review_monitor_rework_state: "Rework"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue = %Issue{
      id: "issue-cod-205-clean-review",
      identifier: "COD-205",
      title: "Analytics MIU flow instrumentation",
      state: "In Review",
      branch_name: "orocsy/feature-analytics-observability-integration"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
          {:ok,
           [
             %{
               "number" => 56,
               "html_url" => "https://github.com/acme/nutribuddy/pull/56",
               "head" => %{
                 "sha" => "62857b0c9d03b9dfee2a06b3e73a7354ad343236",
                 "ref" => "orocsy/feature-analytics-observability-integration"
               }
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/56/comments" ->
          {:ok, []}

        endpoint == "repos/acme/nutribuddy/pulls/56/reviews" ->
          {:ok, []}

        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/56/comments?") ->
          {:ok,
           [
             %{
               "body" => "@codex review",
               "created_at" => "2026-05-25T19:18:36Z"
             },
             %{
               "body" => "Codex Review: Didn't find any major issues. Delightful!",
               "created_at" => "2026-05-25T19:24:10Z",
               "user" => %{"login" => "chatgpt-codex-connector[bot]", "type" => "Bot"}
             }
           ]}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

    assert :ok = SymphonyElixir.ReviewMonitor.run_once()

    assert_receive {:memory_tracker_state_update, "issue-cod-205-clean-review", "Human Review"}
    assert_receive {:memory_tracker_comment, "issue-cod-205-clean-review", body}
    assert body =~ "clean Codex review"
    assert body =~ "pull/56"
    refute_receive {:memory_tracker_state_update, "issue-cod-205-clean-review", "Rework"}, 50
  end

  test "review request pending scans issue comment pages beyond the default first page" do
    parent = self()

    old_comments =
      for id <- 1..100 do
        %{
          "body" => "Earlier issue comment #{id}.",
          "created_at" => "2026-05-15T09:00:00Z"
        }
      end

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      send(parent, {:github_endpoint, endpoint})

      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/4/comments?") and
            Regex.match?(~r/(^|[?&])page=1(&|$)/, endpoint) ->
          {:ok, old_comments}

        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/4/comments?") and
            Regex.match?(~r/(^|[?&])page=2(&|$)/, endpoint) ->
          {:ok,
           [
             %{
               "body" => "@codex review\n\nFresh review requested after the pushed fix.",
               "created_at" => "2026-05-15T09:24:37Z"
             }
           ]}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

    feedback = [
      %{
        type: :thread,
        payload: %{
          "comments" => %{
            "nodes" => [
              %{"body" => "Old current-head feedback.", "createdAt" => "2026-05-15T09:20:00Z"}
            ]
          }
        }
      }
    ]

    assert {:ok, true} =
             SymphonyElixir.ReviewMonitor.codex_review_request_pending?(
               "acme/nutribuddy",
               %{"number" => 4},
               feedback
             )

    assert_receive {:github_endpoint, page_one}
    assert page_one =~ ~r/(^|[?&])page=1(&|$)/
    assert page_one =~ ~r/(^|[?&])per_page=100(&|$)/

    assert_receive {:github_endpoint, page_two}
    assert page_two =~ ~r/(^|[?&])page=2(&|$)/
    assert page_two =~ ~r/(^|[?&])per_page=100(&|$)/
  end

  test "review request pending is stale when the PR head advanced after the request" do
    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/4/comments?") ->
          {:ok,
           [
             %{
               "body" => "@codex review\n\nFresh review requested before the pushed follow-up fix.",
               "created_at" => "2026-05-15T09:24:37Z"
             }
           ]}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

    feedback = [
      %{
        type: :thread,
        payload: %{
          "comments" => %{
            "nodes" => [
              %{"body" => "Old current-head feedback.", "createdAt" => "2026-05-15T09:20:00Z"}
            ]
          }
        }
      }
    ]

    assert {:ok, false} =
             SymphonyElixir.ReviewMonitor.codex_review_request_pending?(
               "acme/nutribuddy",
               %{"number" => 4, "head_committed_at" => "2026-05-15T09:30:00Z"},
               feedback
             )
  end

  test "review request pending ignores guidance that quotes the codex review command" do
    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/4/comments?") ->
          {:ok,
           [
             %{
               "body" => "Review feedback found. Please request `@codex review` again after pushing the fix.",
               "created_at" => "2026-05-15T09:24:37Z"
             }
           ]}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

    feedback = [
      %{
        type: :thread,
        payload: %{
          "comments" => %{
            "nodes" => [
              %{"body" => "Current-head feedback.", "createdAt" => "2026-05-15T09:20:00Z"}
            ]
          }
        }
      }
    ]

    assert {:ok, false} =
             SymphonyElixir.ReviewMonitor.codex_review_request_pending?(
               "acme/nutribuddy",
               %{"number" => 4},
               feedback
             )
  end

  test "review request pending expires after configured stale timeout" do
    Application.put_env(:symphony_elixir, :codex_review_request_stale_after_ms, 1)

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/4/comments?") ->
          {:ok,
           [
             %{
               "body" => "@codex review\n\nFresh review requested during a quota outage.",
               "created_at" => "2026-05-15T09:24:37Z"
             }
           ]}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :codex_review_request_stale_after_ms)
      Application.delete_env(:symphony_elixir, :github_api_runner)
    end)

    feedback = [
      %{
        type: :thread,
        payload: %{
          "comments" => %{
            "nodes" => [
              %{"body" => "Old current-head feedback.", "createdAt" => "2026-05-15T09:20:00Z"}
            ]
          }
        }
      }
    ]

    assert {:ok, false} =
             SymphonyElixir.ReviewMonitor.codex_review_request_pending?(
               "acme/nutribuddy",
               %{"number" => 4},
               feedback
             )
  end

  test "review monitor confirms clean Codex result only after a review request" do
    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/4/comments?") ->
          {:ok,
           [
             %{
               "body" => "@codex review",
               "created_at" => "2026-05-15T09:24:37Z"
             },
             %{
               "body" => "Codex Review: Didn't find any major issues. Bravo.",
               "created_at" => "2026-05-15T09:28:00Z",
               "user" => %{"login" => "chatgpt-codex-connector[bot]", "type" => "Bot"}
             }
           ]}

        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/5/comments?") ->
          {:ok,
           [
             %{
               "body" => "Codex Review: Didn't find any major issues. Bravo.",
               "created_at" => "2026-05-15T09:28:00Z",
               "user" => %{"login" => "chatgpt-codex-connector[bot]", "type" => "Bot"}
             }
           ]}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

    assert {:ok, true} =
             SymphonyElixir.ReviewMonitor.clean_codex_review_after_latest_request?(
               "acme/nutribuddy",
               %{"number" => 4}
             )

    assert {:ok, false} =
             SymphonyElixir.ReviewMonitor.clean_codex_review_after_latest_request?(
               "acme/nutribuddy",
               %{"number" => 5}
             )
  end

  test "review monitor treats clean Codex result after latest request as clearing older active threads" do
    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
          {:ok,
           [
             %{
               "number" => 17,
               "html_url" => "https://github.com/acme/nutribuddy/pull/17",
               "head" => %{"sha" => "head-after-rework", "ref" => "orocsy/mt-clean-review"}
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/17/comments" ->
          {:ok, []}

        endpoint == "repos/acme/nutribuddy/pulls/17/reviews" ->
          {:ok, []}

        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/17/comments?") ->
          {:ok,
           [
             %{
               "body" => "@codex review",
               "created_at" => "2026-05-17T22:42:51Z"
             },
             %{
               "body" => "Codex Review: Didn't find any major issues. Bravo.",
               "created_at" => "2026-05-17T22:46:37Z",
               "user" => %{"login" => "chatgpt-codex-connector[bot]", "type" => "Bot"}
             }
           ]}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
      {:ok,
       %{
         "data" => %{
           "repository" => %{
             "pullRequest" => %{
               "headRefOid" => "head-after-rework",
               "reviewThreads" => %{
                 "nodes" => [
                   %{
                     "isResolved" => false,
                     "isOutdated" => false,
                     "comments" => %{
                       "nodes" => [
                         %{
                           "body" => "Classify JSON parse failures as invalid_json.",
                           "path" => "src/lib/providers/ai-provider.ts",
                           "line" => 107,
                           "createdAt" => "2026-05-17T22:40:30Z",
                           "url" => "https://github.com/acme/nutribuddy/pull/17#discussion"
                         }
                       ]
                     }
                   }
                 ],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }
       }}
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_api_runner)
      Application.delete_env(:symphony_elixir, :github_graphql_runner)
    end)

    issue = %Issue{
      id: "issue-clean-review",
      identifier: "MT-250",
      title: "Clean review should clear old thread",
      state: "Human Review",
      branch_name: "orocsy/mt-clean-review"
    }

    assert {:ok, %{feedback: [], feedback_source: :review_threads}} =
             SymphonyElixir.ReviewMonitor.inspect_issue(issue, %{repo: "acme/nutribuddy"})
  end

  test "review monitor inspects declared integration branch when issue branch PR has no feedback" do
    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      decoded = URI.decode(endpoint)

      cond do
        String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
            String.contains?(decoded, "head=acme:orocsy/cod-190-handoff") ->
          {:ok,
           [
             %{
               "number" => 34,
               "html_url" => "https://github.com/acme/nutribuddy/pull/34",
               "head" => %{"ref" => "orocsy/cod-190-handoff", "sha" => "issue-branch-head"}
             }
           ]}

        String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
            String.contains?(decoded, "head=acme:orocsy/feature-deepseek-provider-integration") ->
          {:ok,
           [
             %{
               "number" => 33,
               "html_url" => "https://github.com/acme/nutribuddy/pull/33",
               "head" => %{
                 "ref" => "orocsy/feature-deepseek-provider-integration",
                 "sha" => "integration-head"
               }
             }
           ]}

        decoded in [
          "repos/acme/nutribuddy/pulls/33/comments",
          "repos/acme/nutribuddy/pulls/33/reviews",
          "repos/acme/nutribuddy/issues/33/comments",
          "repos/acme/nutribuddy/pulls/34/comments",
          "repos/acme/nutribuddy/pulls/34/reviews",
          "repos/acme/nutribuddy/issues/34/comments"
        ] ->
          {:ok, []}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, variables ->
      nodes =
        case variables["number"] do
          33 ->
            [
              %{
                "isResolved" => false,
                "isOutdated" => false,
                "comments" => %{
                  "nodes" => [
                    %{
                      "body" => "Wire DeepSeek selection into follow-up messages.",
                      "path" => "src/app/api/recipe-chats/[chatId]/messages/route.ts",
                      "line" => 190,
                      "createdAt" => "2026-05-18T18:31:40Z",
                      "url" => "https://github.com/acme/nutribuddy/pull/33#discussion"
                    }
                  ]
                }
              }
            ]

          _ ->
            []
        end

      {:ok,
       %{
         "data" => %{
           "repository" => %{
             "pullRequest" => %{
               "headRefOid" => "head",
               "reviewThreads" => %{
                 "nodes" => nodes,
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }
       }}
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_api_runner)
      Application.delete_env(:symphony_elixir, :github_graphql_runner)
    end)

    issue = %Issue{
      id: "issue-cod-190",
      identifier: "COD-190",
      title: "DeepSeek Integration Check",
      state: "Rework",
      branch_name: "orocsy/cod-190-handoff",
      description: """
      ## Base / Branch Contract

      - Final integration branch: `orocsy/feature-deepseek-provider-integration`.
      - Final PR target: `main`.
      """
    }

    assert {:ok,
            %{
              pr_number: 33,
              pr_url: "https://github.com/acme/nutribuddy/pull/33",
              head_ref: "orocsy/feature-deepseek-provider-integration",
              head_sha: "integration-head",
              feedback: [_],
              feedback_source: :review_threads
            }} = SymphonyElixir.ReviewMonitor.inspect_issue(issue, %{repo: "acme/nutribuddy"})
  end

  test "no durable progress correction without PR feedback retries after requirements hydration" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-no-progress-hydrated-retry-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-153-rescue",
        identifier: "COD-153",
        title: "Recipe chat generation",
        state: "In Progress",
        branch_name: "orocsy/cod-153-miu-5-recipe-chat-generation",
        description: """
        ## Write Scope
        - src/app/api/recipes/**
        - src/features/recipe-chat/**

        ## Base Branch
        orocsy/feature-recipe-chat-integration

        ### MIU 1 - Recipe Chat
        Generate recipe chat responses from accepted swipe context.

        ## Validation
        ```bash
        pnpm test -- tests/unit/recipe-chat.test.ts
        ```
        """
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.no-durable-progress",
                 source_status: "blocked",
                 summary: "Worker exceeded durable progress guard.",
                 findings: ["no-durable-progress"],
                 next_action: "block"
               })

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") -> {:ok, []}
          true -> {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      assert_receive {:memory_tracker_comment, "issue-cod-153-rescue", body}
      assert body =~ "retry_with_hydrated_requirements"
      assert body =~ "orocsy/cod-153-miu-5-recipe-chat-generation"
      refute_receive {:memory_tracker_state_update, "issue-cod-153-rescue", "Rework"}, 50

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      resolved = correction_path |> File.read!() |> Jason.decode!()
      assert resolved["status"] == "resolved"
      assert resolved["resolution_summary"] =~ "retry_with_hydrated_requirements"
      refute Workspace.blocking_correction_in_workspace?(workspace)
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "no durable progress after hydrated dispatch preflight stays blocked" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-no-progress-after-preflight-block-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-157-preflight-block",
        identifier: "COD-157",
        title: "Bridge contract",
        state: "In Progress",
        branch_name: "orocsy/cod-157-bridge-contract",
        description: """
        ## Write Scope
        - docs/TECHNICAL_DESIGN.md only for the accepted-swipe to recipe-chat contract section.

        ### MIU 1 - Accepted Swipe To Recipe Chat Contract
        Define the accepted swipe handoff DTO and downstream responsibilities.

        ## Validation
        ```bash
        pnpm test -- tests/unit/domain-schemas.test.ts
        ```
        """
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"],
          cd: workspace,
          env: [
            {"GIT_AUTHOR_DATE", "2020-01-01T00:00:00Z"},
            {"GIT_COMMITTER_DATE", "2020-01-01T00:00:00Z"}
          ],
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "integration.txt"), "merged COD-159/COD-160 baseline\n")

      {_output, 0} =
        System.cmd("git", ["add", "integration.txt"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Integration baseline"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", issue.branch_name],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      preflight_ts =
        DateTime.utc_now()
        |> DateTime.add(-10, :second)
        |> DateTime.to_iso8601()

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        Jason.encode!(%{
          "branch" => issue.branch_name,
          "event" => "dispatch.preflight",
          "issue" => issue.identifier,
          "mode" => "fresh_implementation",
          "required_worker_event" => "technical-miu-trace",
          "source" => "symphony.runtime.dispatch-preflight",
          "status" => "passed",
          "tool" => "dispatch-preflight",
          "ts" => preflight_ts
        }) <> "\n"
      )

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.no-durable-progress",
                 source_status: "blocked",
                 summary: "Worker exceeded durable progress guard.",
                 findings: ["no-durable-progress"],
                 next_action: "block"
               })

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") -> {:ok, []}
          true -> {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      assert_receive {:memory_tracker_comment, "issue-cod-157-preflight-block", body}
      assert body =~ "worker_prompt_defect"
      assert body =~ "runtime-only preflight had already run"
      refute body =~ "retry_with_hydrated_requirements"

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      classified = correction_path |> File.read!() |> Jason.decode!()
      assert classified["status"] == "open"
      assert classified["classification"] == "worker_prompt_defect"
      assert classified["classification_summary"] =~ "hydrated dispatch preflight"
      assert Workspace.blocking_correction_in_workspace?(workspace)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "no durable progress after hydrated dispatch preflight ignores stale dirty files" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-no-progress-stale-dirty-block-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-199-stale-dirty-block",
        identifier: "COD-199",
        title: "Auth integration check",
        state: "Rework",
        branch_name: "orocsy/feature-auth-migration-integration",
        description: """
        ## Write Scope
        - tests/integration/recipe-chat-routes.test.ts

        ## Base / Branch Contract
        - Final integration branch: `orocsy/feature-auth-migration-integration`.

        ### MIU 1 - Restore recipe chat validation
        Repair the integration test helper and fallback behavior before rerunning focused validation.

        ## Validation
        ```bash
        pnpm exec vitest run tests/integration/guest-migration.test.ts tests/integration/recipe-chat-routes.test.ts
        ```
        """
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", issue.branch_name],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      stale_dirty_path = Path.join(workspace, "tests/integration/recipe-chat-routes.test.ts")
      File.mkdir_p!(Path.dirname(stale_dirty_path))
      File.write!(stale_dirty_path, "stale dirty handoff from earlier worker\n")

      {_output, 0} =
        System.cmd("touch", ["-t", "202001010000", stale_dirty_path],
          cd: workspace,
          stderr_to_stdout: true
        )

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      preflight_ts =
        DateTime.utc_now()
        |> DateTime.add(-10, :second)
        |> DateTime.to_iso8601()

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        Jason.encode!(%{
          "branch" => issue.branch_name,
          "event" => "dispatch.preflight",
          "issue" => issue.identifier,
          "mode" => "integration_check",
          "required_worker_event" => "technical-miu-trace",
          "source" => "symphony.runtime.dispatch-preflight",
          "status" => "passed",
          "tool" => "dispatch-preflight",
          "ts" => preflight_ts
        }) <> "\n"
      )

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.no-durable-progress-handoff",
                 source_status: "retryable",
                 summary: "Worker hit the no durable progress handoff guard.",
                 findings: ["no-durable-progress"],
                 next_action: "retry"
               })

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      correction_json = correction_path |> File.read!() |> Jason.decode!()

      correction_created_at =
        DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.truncate(:second)

      File.write!(
        correction_path,
        Jason.encode!(
          Map.put(correction_json, "created_at", DateTime.to_iso8601(correction_created_at)),
          pretty: true
        )
      )

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") -> {:ok, []}
          true -> {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      assert_receive {:memory_tracker_comment, "issue-cod-199-stale-dirty-block", body}
      assert body =~ "worker_prompt_defect"
      assert body =~ "runtime-only preflight had already run"
      refute body =~ "retry_with_hydrated_requirements"

      classified = correction_path |> File.read!() |> Jason.decode!()
      assert classified["status"] == "open"
      assert classified["classification"] == "worker_prompt_defect"
      assert classified["classification_summary"] =~ "hydrated dispatch preflight"
      assert Workspace.blocking_correction_in_workspace?(workspace)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "classified handoff correction resolves when same-turn dirty progress precedes correction" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fresh-dirty-handoff-rescue-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-208-fresh-dirty-handoff",
        identifier: "COD-208",
        title: "Analytics Integration Check And Final PR Handoff",
        state: "Rework",
        branch_name: "orocsy/feature-analytics-observability-integration",
        description: """
        ## Ticket Type
        integration-check

        ## Integration Branch
        orocsy/feature-analytics-observability-integration

        ## Write Scope
        - Merge conflict resolution for the analytics integration branch.
        """
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", issue.branch_name],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      dirty_path = Path.join(workspace, "tests/unit/recipe-chat-page-view.test.ts")
      File.mkdir_p!(Path.dirname(dirty_path))
      File.write!(dirty_path, "fresh dirty handoff progress\n")

      fresh_progress_time =
        DateTime.utc_now()
        |> DateTime.add(-25 * 60, :second)
        |> DateTime.to_naive()
        |> NaiveDateTime.to_erl()

      File.touch!(dirty_path, fresh_progress_time)

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        Jason.encode!(%{
          "branch" => issue.branch_name,
          "event" => "dispatch.preflight",
          "issue" => issue.identifier,
          "mode" => "integration_check",
          "required_worker_event" => "technical-miu-trace",
          "source" => "symphony.runtime.dispatch-preflight",
          "status" => "passed",
          "tool" => "dispatch-preflight",
          "ts" => DateTime.utc_now() |> DateTime.add(-20, :second) |> DateTime.to_iso8601()
        }) <> "\n"
      )

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.no-durable-progress-handoff",
                 source_status: "retryable",
                 summary: "Worker hit the no durable progress handoff guard after local progress.",
                 findings: ["no-durable-progress"],
                 next_action: "retry"
               })

      assert :ok =
               Workspace.classify_blocking_corrections_in_workspace(
                 workspace,
                 "worker_prompt_defect",
                 "worker_prompt_defect: runtime progress correction happened after hydrated dispatch preflight, so requirements hydration is not new retry evidence under runtime-preflight-worker-progress-contract-v19."
               )

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      assert_receive {:memory_tracker_comment, "issue-cod-208-fresh-dirty-handoff", body}
      assert body =~ "retry_dirty_handoff_recovery"
      assert body =~ "dirty-handoff recovery prompt"

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      resolved = correction_path |> File.read!() |> Jason.decode!()
      assert resolved["status"] == "resolved"
      assert resolved["resolution_summary"] =~ "retry_dirty_handoff_recovery"
      refute Workspace.blocking_correction_in_workspace?(workspace)
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing first durable event correction without PR feedback retries after requirements hydration" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-first-event-hydrated-retry-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-153-missing-first-event",
        identifier: "COD-153",
        title: "Recipe chat generation",
        state: "In Progress",
        branch_name: "orocsy/cod-153-miu-5-recipe-chat-generation",
        description: """
        ## Write Scope
        - src/app/api/recipes/**
        - src/features/recipe-chat/**

        ## Base Branch
        orocsy/feature-recipe-chat-integration

        ### MIU 1 - Recipe Chat
        Generate recipe chat responses from accepted swipe context.

        ## Validation
        ```bash
        pnpm test -- tests/unit/recipe-chat.test.ts
        ```
        """
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.missing-first-durable-event",
                 source_status: "blocked",
                 summary: "Worker exceeded the first durable Orocsy progress event guard.",
                 findings: ["{:missing_first_durable_event, 92035, 148866, 120000}"],
                 next_action: "block"
               })

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") -> {:ok, []}
          true -> {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      assert_receive {:memory_tracker_comment, "issue-cod-153-missing-first-event", body}
      assert body =~ "retry_with_hydrated_requirements"

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      resolved = correction_path |> File.read!() |> Jason.decode!()
      assert resolved["status"] == "resolved"
      assert resolved["resolution_summary"] =~ "retry_with_hydrated_requirements"
      refute Workspace.blocking_correction_in_workspace?(workspace)
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "repeated missing first durable event retries without workspace progress are classified and blocked" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-first-event-loop-block-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-153-missing-first-event-loop",
        identifier: "COD-153",
        title: "Recipe chat generation",
        state: "In Progress",
        branch_name: "orocsy/cod-153-miu-5-recipe-chat-generation",
        description: """
        ## Write Scope
        - src/app/api/recipes/**
        - src/features/recipe-chat/**

        ## Base Branch
        orocsy/feature-recipe-chat-integration

        ### MIU 1 - Recipe Chat
        Generate recipe chat responses from accepted swipe context.

        ## Validation
        ```bash
        pnpm test -- tests/unit/recipe-chat.test.ts
        ```
        """
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      for attempt <- 1..2 do
        assert {:ok, _correction} =
                 Workspace.create_correction_in_workspace(workspace, issue, %{
                   source: "symphony.runtime.missing-first-durable-event",
                   source_status: "blocked",
                   summary: "Worker exceeded the first durable Orocsy progress event guard.",
                   findings: ["{:missing_first_durable_event, #{attempt}, 148866, 120000}"],
                   next_action: "block"
                 })

        assert :ok =
                 Workspace.resolve_blocking_corrections_in_workspace(
                   workspace,
                   "retry_with_hydrated_requirements: no current PR feedback found and issue requirements are parseable."
                 )
      end

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.missing-first-durable-event",
                 source_status: "blocked",
                 summary: "Worker exceeded the first durable Orocsy progress event guard.",
                 findings: ["{:missing_first_durable_event, 92035, 148866, 120000}"],
                 next_action: "block"
               })

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") -> {:ok, []}
          true -> {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      assert_receive {:memory_tracker_comment, "issue-cod-153-missing-first-event-loop", body}
      assert body =~ "worker_prompt_defect"
      assert body =~ "no dirty files"
      assert body =~ "runtime-preflight-worker-progress-contract-v19"

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      classified = correction_path |> File.read!() |> Jason.decode!()
      assert classified["status"] == "open"
      assert classified["classification"] == "worker_prompt_defect"
      assert classified["classification_summary"] =~ "repeated runtime progress retries"

      assert classified["classification_summary"] =~
               "runtime-preflight-worker-progress-contract-v19"

      assert Workspace.blocking_correction_in_workspace?(workspace)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "stale worker prompt defect correction is resolved after runtime prompt fix" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worker-prompt-defect-stale-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-153-stale-worker-prompt-defect",
        identifier: "COD-153",
        title: "Recipe chat generation",
        state: "In Progress",
        branch_name: "orocsy/cod-153-miu-5-recipe-chat-generation"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.missing-first-durable-event",
                 source_status: "blocked",
                 summary: "Worker exceeded the first durable Orocsy progress event guard.",
                 findings: ["{:missing_first_durable_event, 92035, 148866, 120000}"],
                 next_action: "block"
               })

      assert :ok =
               Workspace.classify_blocking_corrections_in_workspace(
                 workspace,
                 "worker_prompt_defect",
                 "worker_prompt_defect: repeated runtime progress retries produced no branch, file, or commit progress."
               )

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      assert_receive {:memory_tracker_comment, "issue-cod-153-stale-worker-prompt-defect", body}
      assert body =~ "resolved stale `worker_prompt_defect`"
      assert body =~ "runtime-preflight-worker-progress-contract-v19"

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      resolved = correction_path |> File.read!() |> Jason.decode!()
      assert resolved["status"] == "resolved"
      assert resolved["resolution_summary"] =~ "worker_prompt_defect_resolved_by_runtime_fix"
      refute Workspace.blocking_correction_in_workspace?(workspace)
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "mixed stale worker prompt defect and runtime config/progress corrections resolve after dispatch preflight fix" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worker-prompt-defect-mixed-stale-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress", "Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review", "In Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-152-mixed-stale-worker-prompt-defect",
        identifier: "COD-152",
        title: "Swipe feed UI and mutation flow",
        state: "Rework",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, _classified_correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.review-rework-retry-loop",
                 source_status: "blocked",
                 summary: "Repeated review-rework runtime progress retries produced no workspace progress.",
                 findings: ["review_rework_needed loop exhausted without workspace progress"],
                 next_action: "block"
               })

      assert :ok =
               Workspace.classify_blocking_corrections_in_workspace(
                 workspace,
                 "worker_prompt_defect",
                 "worker_prompt_defect: repeated review-rework runtime progress retries did not complete the dirty handoff under worker-prompt-v3-branch-first-bounded-turn."
               )

      assert {:ok, _unclassified_correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.missing-first-durable-event",
                 source_status: "blocked",
                 summary: "Worker exceeded the first durable Orocsy progress event guard.",
                 findings: ["{:missing_first_durable_event, 58102, 223796, 120000}"],
                 next_action: "block"
               })

      assert {:ok, _startup_correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.worker",
                 source_status: "retry-exhausted",
                 summary: "Symphony worker exited unexpectedly and exceeded the safe retry policy.",
                 findings: [
                   "Agent run failed for issue_id=issue-cod-152-mixed-stale-worker-prompt-defect issue_identifier=COD-152: {:response_error, %{\"code\" => -32600, \"message\" => \"failed to load configuration: invalid transport\\nin `mcp_servers.cloudflare-api`\\n\"}}"
                 ],
                 next_action: "block"
               })

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state

      assert_receive {:memory_tracker_comment, "issue-cod-152-mixed-stale-worker-prompt-defect", body}

      assert body =~ "resolved stale `worker_prompt_defect`"
      assert body =~ "runtime-preflight-worker-progress-contract-v19"

      resolved_corrections =
        workspace
        |> Path.join(".orocsy/delivery/inbox/correction_*.json")
        |> Path.wildcard()
        |> Enum.map(fn path -> path |> File.read!() |> Jason.decode!() end)

      assert length(resolved_corrections) == 3
      assert Enum.all?(resolved_corrections, &(&1["status"] == "resolved"))

      assert Enum.all?(
               resolved_corrections,
               &String.contains?(
                 &1["resolution_summary"],
                 "runtime-preflight-worker-progress-contract-v19"
               )
             )

      refute Workspace.blocking_correction_in_workspace?(workspace)
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "current worker prompt defect resolves when branch advanced after correction and routes review feedback to rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worker-prompt-defect-later-progress-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review", "In Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-152-later-progress-worker-prompt-defect",
        identifier: "COD-152",
        title: "Swipe feed UI and mutation flow",
        state: "Rework",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)

      baseline_ts = DateTime.add(DateTime.utc_now(), -120, :second) |> DateTime.to_iso8601()
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 env: [{"GIT_AUTHOR_DATE", baseline_ts}, {"GIT_COMMITTER_DATE", baseline_ts}],
                 stderr_to_stdout: true
               )

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.review-rework-retry-loop",
                 source_status: "blocked",
                 summary: "Repeated review-rework runtime progress retries produced no workspace progress.",
                 findings: ["review_rework_needed loop exhausted without workspace progress"],
                 next_action: "block"
               })

      assert :ok =
               Workspace.classify_blocking_corrections_in_workspace(
                 workspace,
                 "worker_prompt_defect",
                 "worker_prompt_defect: repeated review-rework runtime progress retries did not complete the dirty handoff under runtime-preflight-worker-progress-contract-v19."
               )

      progress_ts = DateTime.add(DateTime.utc_now(), 120, :second) |> DateTime.to_iso8601()
      File.write!(Path.join(workspace, "src.txt"), "review fix\n")
      assert {_output, 0} = System.cmd("git", ["add", "src.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Fix review feedback"],
                 cd: workspace,
                 env: [{"GIT_AUTHOR_DATE", progress_ts}, {"GIT_COMMITTER_DATE", progress_ts}],
                 stderr_to_stdout: true
               )

      assert {head_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
      head_sha = String.trim(head_sha)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 4,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/4",
                 "head" => %{
                   "sha" => head_sha,
                   "ref" => "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/4/comments" ->
            {:ok,
             [
               %{
                 "body" => "Open the recipe flow on accepted right swipes.",
                 "commit_id" => head_sha,
                 "path" => "src/features/swipe/SwipeDeck.tsx",
                 "line" => 81,
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

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state

      assert_receive {:memory_tracker_state_update, "issue-cod-152-later-progress-worker-prompt-defect", "Rework"}

      assert_receive {:memory_tracker_comment, "issue-cod-152-later-progress-worker-prompt-defect", body}

      assert body =~ "workspace progress appeared after the correction"
      assert body =~ "pull/4"

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      resolved = correction_path |> File.read!() |> Jason.decode!()
      assert resolved["status"] == "resolved"

      assert resolved["resolution_summary"] =~
               "worker_prompt_defect_resolved_by_later_workspace_progress"

      refute Workspace.blocking_correction_in_workspace?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "current worker prompt defect resolves when newer Codex review feedback arrives after review request" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worker-prompt-defect-fresh-review-feedback-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review", "In Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-152-fresh-review-feedback-worker-prompt-defect",
        identifier: "COD-152",
        title: "Swipe feed UI and mutation flow",
        state: "Rework",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.review-rework-retry-loop",
                 source_status: "blocked",
                 summary: "Repeated review-rework runtime progress retries produced no workspace progress.",
                 findings: ["review_rework_needed loop exhausted without workspace progress"],
                 next_action: "block"
               })

      assert :ok =
               Workspace.classify_blocking_corrections_in_workspace(
                 workspace,
                 "worker_prompt_defect",
                 "worker_prompt_defect: repeated review-rework runtime progress retries did not complete the dirty handoff under runtime-preflight-worker-progress-contract-v19."
               )

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      correction_json = correction_path |> File.read!() |> Jason.decode!()

      File.write!(
        correction_path,
        Jason.encode!(Map.put(correction_json, "created_at", "2026-05-15T09:30:00Z"),
          pretty: true
        )
      )

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 4,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/4",
                 "head" => %{
                   "sha" => "d3c2c0052fdf0ffad3b1b7b0f1371a58b66ecabc",
                   "ref" => "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/4/comments" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/4/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/4/comments?") ->
            {:ok,
             [
               %{
                 "body" => "@codex review\n\nFresh review requested after d3c2c00.",
                 "created_at" => "2026-05-15T09:24:37Z",
                 "html_url" => "https://github.com/acme/nutribuddy/pull/4#issuecomment"
               }
             ]}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => "d3c2c0052fdf0ffad3b1b7b0f1371a58b66ecabc",
                 "reviewThreads" => %{
                   "nodes" => [
                     %{
                       "isResolved" => false,
                       "isOutdated" => false,
                       "comments" => %{
                         "nodes" => [
                           %{
                             "body" => "Do not leave accepted cooks stuck.",
                             "path" => "src/features/swipe/SwipeDeck.tsx",
                             "line" => 86,
                             "createdAt" => "2026-05-15T09:27:16Z",
                             "url" => "https://github.com/acme/nutribuddy/pull/4#discussion"
                           }
                         ]
                       }
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state

      refute_receive {:memory_tracker_state_update, "issue-cod-152-fresh-review-feedback-worker-prompt-defect", _state},
                     50

      refute_receive {:memory_tracker_comment, "issue-cod-152-fresh-review-feedback-worker-prompt-defect", _body},
                     50

      parked = correction_path |> File.read!() |> Jason.decode!()
      assert parked["status"] == "open"
      assert Workspace.blocking_correction_in_workspace?(workspace)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)

      File.write!(
        correction_path,
        Jason.encode!(Map.put(parked, "created_at", "2026-05-15T09:20:00Z"), pretty: true)
      )

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state

      assert_receive {:memory_tracker_state_update, "issue-cod-152-fresh-review-feedback-worker-prompt-defect", "Rework"}

      assert_receive {:memory_tracker_comment, "issue-cod-152-fresh-review-feedback-worker-prompt-defect", body}

      assert body =~ "fresh Codex review feedback arrived"
      assert body =~ "pull/4"

      resolved = correction_path |> File.read!() |> Jason.decode!()
      assert resolved["status"] == "resolved"

      assert resolved["resolution_summary"] =~
               "worker_prompt_defect_resolved_by_fresh_review_feedback"

      refute Workspace.blocking_correction_in_workspace?(workspace)
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "current worker prompt defect resolves when dirty workspace progress exists after correction" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worker-prompt-defect-dirty-progress-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review", "In Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-152-dirty-progress-worker-prompt-defect",
        identifier: "COD-152",
        title: "Swipe feed UI and mutation flow",
        state: "In Review",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)

      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {head_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
      head_sha = String.trim(head_sha)

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.review-rework-retry-loop",
                 source_status: "blocked",
                 summary: "Repeated review-rework runtime progress retries produced no workspace progress.",
                 findings: ["review_rework_needed loop exhausted without workspace progress"],
                 next_action: "block"
               })

      assert :ok =
               Workspace.classify_blocking_corrections_in_workspace(
                 workspace,
                 "worker_prompt_defect",
                 "worker_prompt_defect: repeated review-rework runtime progress retries did not complete the dirty handoff under runtime-preflight-worker-progress-contract-v19."
               )

      dirty_path = Path.join(workspace, "src/features/swipe/SwipeDeck.tsx")
      File.mkdir_p!(Path.dirname(dirty_path))
      File.write!(dirty_path, "review fix is dirty but real\n")

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 4,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/4",
                 "head" => %{
                   "sha" => head_sha,
                   "ref" => "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/4/comments" ->
            {:ok,
             [
               %{
                 "body" => "Open the recipe flow on accepted right swipes.",
                 "commit_id" => head_sha,
                 "path" => "src/features/swipe/SwipeDeck.tsx",
                 "line" => 81,
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

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state

      assert_receive {:memory_tracker_state_update, "issue-cod-152-dirty-progress-worker-prompt-defect", "Rework"}

      assert_receive {:memory_tracker_comment, "issue-cod-152-dirty-progress-worker-prompt-defect", body}

      assert body =~ "workspace progress appeared after the correction"
      assert body =~ "pull/4"

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      resolved = correction_path |> File.read!() |> Jason.decode!()
      assert resolved["status"] == "resolved"

      assert resolved["resolution_summary"] =~
               "worker_prompt_defect_resolved_by_later_workspace_progress"

      refute Workspace.blocking_correction_in_workspace?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "already classified worker prompt defect correction stays blocked without repeating comments" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worker-prompt-defect-dedupe-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-153-worker-prompt-defect",
        identifier: "COD-153",
        title: "Recipe chat generation",
        state: "In Progress",
        branch_name: "orocsy/cod-153-miu-5-recipe-chat-generation"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, _correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.missing-first-durable-event",
                 source_status: "blocked",
                 summary: "Worker exceeded the first durable Orocsy progress event guard.",
                 findings: ["{:missing_first_durable_event, 92035, 148866, 120000}"],
                 next_action: "block"
               })

      assert :ok =
               Workspace.classify_blocking_corrections_in_workspace(
                 workspace,
                 "worker_prompt_defect",
                 "worker_prompt_defect: repeated runtime progress retries produced no branch, file, or commit progress under runtime-preflight-worker-progress-contract-v19."
               )

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        {:error, {:unexpected_endpoint, endpoint}}
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      refute_receive {:memory_tracker_comment, "issue-cod-153-worker-prompt-defect", _body}, 50
      assert Workspace.blocking_correction_in_workspace?(workspace)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight skips review inspection when monitor is disabled even with repo configured" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-disabled-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: false,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-168-review-disabled",
        identifier: "COD-168",
        title: "Recipe chat create route",
        state: "In Progress",
        branch_name: "orocsy/cod-168-recipe-chat-miu-create-route-and-harness",
        description: """
        ## Write Scope
        - src/app/api/recipe-chats/route.ts

        ### MIU 1 - Create Route
        Create the recipe chat route.
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      parent = self()

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        send(parent, {:unexpected_review_inspection, endpoint})
        {:error, {:unexpected_endpoint, endpoint}}
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, %{"mode" => "fresh_implementation"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert get_in(preflight, ["review", "feedback_source"]) == "disabled"
      assert get_in(preflight, ["review", "feedback_count"]) == 0
      refute_receive {:unexpected_review_inspection, _endpoint}, 50
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight consumes active turn grants abandoned by a stopped worker" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-preflight-stale-turn-grant-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: false
      )

      issue = %Issue{
        id: "issue-stale-turn-grant",
        identifier: "MT-STALE-TURN-GRANT",
        title: "Expire abandoned turn grant",
        state: "Rework",
        branch_name: "orocsy/mt-stale-turn-grant",
        description: """
        ## Ticket Type

        Implementation

        ## Write Scope

        - `src/features/landing/LandingExperience.tsx`
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      patch = %{
        "schema_version" => 1,
        "patch_id" => "scope_access_stale_turn",
        "status" => "active",
        "decision" => "allow_once",
        "decision_class" => "allow_once",
        "reason_class" => "safe_read_context",
        "source" => "symphony.runtime.scope-access-controller",
        "target" => "read_context",
        "operation" => "add",
        "policy_hash_before" => "sha256:stale-turn-policy",
        "request" => %{
          "operation" => "read",
          "paths" => ["tests/unit/desktop-guest-setup.test.tsx"],
          "policy_hash" => "sha256:stale-turn-policy"
        },
        "entries" => [
          %{
            "path" => "tests/unit/desktop-guest-setup.test.tsx",
            "source" => "scope_access.auto.direct_import",
            "operation" => "read",
            "expires" => "turn"
          }
        ]
      }

      assert {:ok, written_patch} =
               SymphonyElixir.ScopeAccess.Controller.write_policy_patch(workspace, patch)

      assert written_patch["status"] == "active"

      unsigned_path =
        Path.join([
          workspace,
          SymphonyElixir.ScopeAccess.Controller.policy_patch_dir(),
          "unsigned-active.json"
        ])

      unsigned_patch =
        written_patch
        |> Map.drop(["controller_signature"])
        |> Map.put("patch_id", "scope_access_unsigned_turn")
        |> Map.put("path", Path.relative_to(unsigned_path, workspace))

      File.write!(unsigned_path, Jason.encode!(unsigned_patch, pretty: true) <> "\n")

      assert {:ok, preflight} = SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      persisted_patch =
        workspace
        |> Path.join(written_patch["path"])
        |> File.read!()
        |> Jason.decode!()

      assert persisted_patch["status"] == "consumed"
      assert SymphonyElixir.ControllerEvidence.valid?(persisted_patch)

      assert unsigned_path |> File.read!() |> Jason.decode!() |> Map.fetch!("status") == "active"

      refute Enum.any?(
               get_in(preflight, ["requirements", "scope_bundle", "read_context"]) || [],
               &(&1["path"] == "tests/unit/desktop-guest-setup.test.tsx")
             )
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight falls back when issue requirements are partial" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-partial-requirements-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: false
      )

      issue = %Issue{
        id: "issue-cod-partial-preflight",
        identifier: "COD-PARTIAL",
        title: "Partially structured issue",
        state: "In Progress",
        branch_name: "orocsy/cod-partial-preflight",
        description: """
        ## Validation
        ```bash
        pnpm typecheck
        ```
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, %{"mode" => "fresh_implementation"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert get_in(preflight, ["requirements", "identifier"]) == "COD-PARTIAL"
      assert get_in(preflight, ["requirements", "write_scope"]) == []
      assert get_in(preflight, ["requirements", "mius"]) == []
      assert get_in(preflight, ["review", "feedback_source"]) == "disabled"
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight records current review feedback before Codex starts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-dispatch-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-152-preflight",
        identifier: "COD-152",
        title: "Swipe feed UI and mutation flow",
        state: "Rework",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow",
        description: """
        ## Write Scope
        - src/features/swipe/**

        ### MIU 1 - Swipe Deck
        Connect accepted swipes to the recipe flow.

        ## Validation
        ```bash
        pnpm test -- tests/unit/swipe-deck.test.ts
        ```
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 4,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/4",
                 "head" => %{
                   "sha" => "2830e3d4a36de99e8b8f40caeb7858712ad84f6c",
                   "ref" => "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/4/comments" ->
            {:ok,
             [
               %{
                 "body" => """
                 **P1** Open the recipe flow on accepted right swipes.

                 When `action === "right"` and the server accepts, keep the accepted recipe/chat payload and route into the recipe flow instead of advancing the deck and losing the card.

                 Also inspect `src/app/api/recipe-chats/[chatId]/messages/route.ts` when the review feedback names a related route in the body.
                 """,
                 "commit_id" => "2830e3d4a36de99e8b8f40caeb7858712ad84f6c",
                 "path" => "src/features/swipe/SwipeDeck.tsx",
                 "line" => 81,
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

      assert {:ok, %{"mode" => "review_rework"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["checkpoint_event"] == "review-feedback-classified"
      assert preflight["first_task"] =~ "request a fresh Codex review directly"
      assert preflight["first_task"] =~ "no structured Runtime Contract"
      assert get_in(preflight, ["toolchain", "executables", "npm", "available"]) in [true, false]
      assert is_list(get_in(preflight, ["toolchain", "package_scripts"]))
      assert get_in(preflight, ["review", "feedback_count"]) == 1
      assert [feedback] = get_in(preflight, ["review", "feedback"])
      assert feedback["path"] == "src/features/swipe/SwipeDeck.tsx"
      assert feedback["line"] == 81
      assert feedback["body"] =~ "Open the recipe flow"
      assert feedback["body"] =~ "server accepts"

      events = File.read!(Path.join(workspace, ".orocsy/delivery/events/events.jsonl"))
      assert events =~ ~s("event":"dispatch.preflight")
      assert events =~ ~s("required_worker_event":"review-feedback-classified")
      refute events =~ ~s("tool":"review-feedback-classified")
      assert events =~ "symphony.runtime.dispatch-preflight"

      prompt = PromptBuilder.build_prompt(issue, workspace: workspace)
      assert String.starts_with?(prompt, "Runtime dispatch preflight:")
      assert prompt =~ "review rework"
      assert prompt =~ "src/features/swipe/SwipeDeck.tsx:81"
      assert prompt =~ "Open the recipe flow"
      assert prompt =~ "server accepts"
      assert prompt =~ "Worker-required checkpoint: `review-feedback-classified`"
      assert prompt =~ "Runtime preflight is not worker progress"

      assert prompt =~
               "Target feedback file(s): `src/features/swipe/SwipeDeck.tsx`"

      refute prompt =~ "Target feedback file(s): `src/app/api/recipe-chats/[chatId]/messages/route.ts`"

      assert prompt =~ "Toolchain preflight:"
      assert prompt =~ "Validation command guidance:"
      assert prompt =~ "Review rework execution contract"
      assert prompt =~ "do not append `review-feedback-classified` as a first action"
      assert prompt =~ "classification alone is lifecycle context"
      assert prompt =~ "request a fresh Codex review directly"
      assert prompt =~ "--type handoff.requested"
      assert prompt =~ "legacy issue with no Runtime Contract gate"
      refute prompt =~ "commit, push the same branch, and request fresh Codex review"
      refute prompt =~ "You are an agent for this repository."
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight inspects only the authoritative contract branch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-contract-review-branch-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      contract_branch = "orocsy/cod-274-contract-branch"
      stale_tracker_branch = "orocsy/cod-274-stale-tracker-branch"

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue =
        runtime_handoff_issue(%Issue{
          id: "issue-cod-274-contract-review-branch",
          identifier: "COD-274",
          title: "Desktop shell review rework",
          state: "Rework",
          branch_name: contract_branch,
          description: "Fix current review feedback on the existing PR."
        })
        |> Map.put(:branch_name, stale_tracker_branch)
        |> Map.update!(:description, fn description ->
          description <> "\n## Review Branch\n#{stale_tracker_branch}\n"
        end)

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        decoded = URI.decode(endpoint)

        cond do
          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(decoded, "head=acme:#{contract_branch}") ->
            {:ok,
             [
               %{
                 "number" => 110,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/110",
                 "head" => %{
                   "sha" => "118a18d424313e5e21d898cccd40b4a560157ce2",
                   "ref" => contract_branch
                 }
               }
             ]}

          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(decoded, "head=acme:#{stale_tracker_branch}") ->
            {:ok,
             [
               %{
                 "number" => 111,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/111",
                 "head" => %{
                   "sha" => "218a18d424313e5e21d898cccd40b4a560157ce2",
                   "ref" => stale_tracker_branch
                 }
               }
             ]}

          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/110/comments" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/110/reviews" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/111/comments" ->
            {:ok,
             [
               %{
                 "body" => "Feedback from the stale PR must be ignored.",
                 "commit_id" => "218a18d424313e5e21d898cccd40b4a560157ce2",
                 "path" => "README.md",
                 "line" => 113,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/111#discussion"
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/111/reviews" ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, %{"mode" => "fresh_implementation"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert get_in(preflight, ["requirements", "integration_branch"]) == contract_branch
      assert get_in(preflight, ["review", "pr_number"]) == 110
      assert preflight["branch"] == contract_branch
      assert get_in(preflight, ["review", "feedback"]) == []
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight preserves the original review certification baseline across retries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-baseline-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-266-preflight-baseline",
        identifier: "COD-266",
        title: "Guest safety review rework",
        state: "Rework",
        branch_name: "orocsy/cod-266",
        description: """
        ## Write Scope
        - src/app/api/cards/handler.ts

        ### MIU 1 - Preserve guest safety
        Keep allergy filtering active.
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {:ok, review_head} = Agent.start_link(fn -> String.duplicate("a", 40) end)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        head_sha = Agent.get(review_head, & &1)

        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 103,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/103",
                 "head" => %{"sha" => head_sha, "ref" => "orocsy/cod-266"}
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/103/comments" ->
            {:ok,
             [
               %{
                 "body" => "Preserve allergy filtering.",
                 "commit_id" => head_sha,
                 "path" => "src/app/api/cards/handler.ts",
                 "line" => 133,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/103#discussion"
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/103/reviews" ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, first_preflight} = SymphonyElixir.DispatchPreflight.prepare(workspace, issue)
      first_head = String.duplicate("a", 40)
      assert first_preflight["certification_base_sha"] == first_head
      assert SymphonyElixir.ControllerEvidence.valid?(first_preflight)

      Agent.update(review_head, fn _ -> String.duplicate("b", 40) end)

      refined_issue = %{
        issue
        | description: """
          ## Runtime Contract

          ```yaml
          schema_version: 1
          ticket_type: implementation
          base_branch: main
          integration_branch: orocsy/cod-266
          certification_base_sha: #{String.duplicate("c", 40)}
          dependencies: []
          mius:
            - id: COD-266-MIU-1
              write_scope:
                - src/app/api/cards/handler.ts
              validations:
                - pnpm typecheck
          final_validations:
            - pnpm typecheck
          review:
            authority: github_codex
            require_current_head: true
          ```
          """
      }

      assert {:ok, second_preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, refined_issue)

      assert second_preflight["certification_base_sha"] == first_head
      assert get_in(second_preflight, ["review", "head_sha"]) == String.duplicate("b", 40)
      assert SymphonyElixir.ControllerEvidence.valid?(second_preflight)
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight preserves a signed nil baseline across contract refinements" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nil-certification-baseline-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-cod-signed-nil-baseline",
        identifier: "COD-NIL",
        title: "Signed nil baseline",
        state: "In Progress",
        branch_name: "orocsy/cod-nil",
        description: """
        ## Write Scope
        - README.md
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert {:ok, first_preflight} = SymphonyElixir.DispatchPreflight.prepare(workspace, issue)
      assert is_nil(first_preflight["certification_base_sha"])
      assert SymphonyElixir.ControllerEvidence.valid?(first_preflight)

      refined_issue = %{
        issue
        | description: """
          ## Runtime Contract

          ```yaml
          schema_version: 1
          ticket_type: implementation
          base_branch: main
          integration_branch: orocsy/cod-nil
          certification_base_sha: #{String.duplicate("a", 40)}
          dependencies: []
          mius:
            - id: COD-NIL-MIU-1
              write_scope:
                - README.md
              validations:
                - pnpm typecheck
          final_validations:
            - pnpm typecheck
          review:
            authority: github_codex
            require_current_head: true
          ```
          """
      }

      assert {:ok, second_preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, refined_issue)

      assert is_nil(second_preflight["certification_base_sha"])
      assert SymphonyElixir.ControllerEvidence.valid?(second_preflight)
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight signs an explicit recovery certification baseline" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-explicit-certification-baseline-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      baseline = String.duplicate("a", 40)
      review_head = String.duplicate("b", 40)

      issue = %Issue{
        id: "issue-cod-266-explicit-baseline",
        identifier: "COD-266",
        title: "Guest safety recovery",
        state: "Rework",
        branch_name: "orocsy/generated-child",
        description: """
        ## Runtime Contract

        ```yaml
        schema_version: 1
        ticket_type: implementation
        base_branch: main
        integration_branch: orocsy/cod-246-preference-miu-guest-setup-controls
        certification_base_sha: #{baseline}
        dependencies: []
        mius:
          - id: COD-266-MIU-1
            write_scope:
              - src/app/api/cards/handler.ts
            validations:
              - pnpm typecheck
        final_validations:
          - pnpm typecheck
        review:
          authority: github_codex
          require_current_head: true
        ```
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "issue" => "COD-266",
          "branch" => "orocsy/cod-246-preference-miu-guest-setup-controls",
          "review" => %{"head_sha" => String.duplicate("c", 40)}
        })
      )

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 103,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/103",
                 "head" => %{
                   "sha" => review_head,
                   "ref" => "orocsy/cod-246-preference-miu-guest-setup-controls"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/103/comments" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/103/reviews" ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, preflight} = SymphonyElixir.DispatchPreflight.prepare(workspace, issue)
      {:ok, compiled} = SymphonyElixir.RuntimeContract.compile(issue.description)

      assert preflight["certification_base_sha"] == baseline
      assert get_in(preflight, ["review", "head_sha"]) == review_head
      assert preflight["issue_id"] == issue.id
      assert preflight["contract_hash"] == compiled.contract_hash

      assert preflight["issue_revision"] ==
               SymphonyElixir.RuntimeContract.issue_revision(issue.description, issue.updated_at)

      assert SymphonyElixir.ControllerEvidence.valid?(preflight)
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight blocks unsigned legacy baseline reseeding without an explicit contract baseline" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-unsigned-certification-baseline-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-cod-legacy-baseline",
        identifier: "COD-LEGACY",
        title: "Legacy recovery",
        state: "In Progress",
        branch_name: "orocsy/cod-legacy",
        description: """
        ## Write Scope
        - README.md

        ## Validation
        ```bash
        pnpm typecheck
        ```
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "issue" => "COD-LEGACY",
          "branch" => "orocsy/cod-legacy",
          "review" => %{"head_sha" => String.duplicate("a", 40)}
        })
      )

      assert {:error, {:invalid_certification_preflight, :missing_controller_signature}} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight blocks tampered signed evidence even with an explicit recovery baseline" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-tampered-certification-baseline-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      baseline = String.duplicate("a", 40)

      issue = %Issue{
        id: "issue-cod-tampered-baseline",
        identifier: "COD-TAMPERED",
        title: "Tampered recovery",
        state: "Rework",
        branch_name: "orocsy/cod-tampered",
        description: """
        ## Runtime Contract

        ```yaml
        schema_version: 1
        ticket_type: implementation
        base_branch: main
        integration_branch: orocsy/cod-tampered
        certification_base_sha: #{baseline}
        dependencies: []
        mius:
          - id: COD-TAMPERED-MIU-1
            write_scope:
              - README.md
            validations:
              - pnpm typecheck
        final_validations:
          - pnpm typecheck
        review:
          authority: github_codex
          require_current_head: true
        ```
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)

      tampered =
        SymphonyElixir.ControllerEvidence.sign(%{
          "issue" => issue.identifier,
          "branch" => issue.branch_name,
          "certification_base_sha" => baseline
        })
        |> Map.put("certification_base_sha", String.duplicate("b", 40))

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(tampered)
      )

      assert {:error, {:invalid_certification_preflight, :invalid_controller_signature}} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(Map.put(tampered, "controller_signature", nil))
      )

      assert {:error, {:invalid_certification_preflight, :invalid_controller_signature}} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight keeps test-spec child tickets out of shared PR review rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-test-spec-shared-pr-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-265-preflight",
        identifier: "COD-265",
        title: "COD-246A test-spec",
        state: "Rework",
        branch_name: "orocsy/cod-265-generated-child-branch",
        description: """
        ## Ticket Type
        test-spec

        ## Base Branch
        `orocsy/cod-246-preference-miu-guest-setup-controls` on PR #103.

        ## Integration Branch
        Same shared branch: `orocsy/cod-246-preference-miu-guest-setup-controls`.

        ## Branch / PR Contract
        Use the existing branch/PR only. Do not open a new PR. Do not merge.

        ## Write Scope
        - tests/unit/swipe-experience-request.test.ts
        - tests/integration/cards-route.test.ts

        ### MIU 1 - Frontend request contract
        Add failing tests for the first cards request payload.
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 103,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/103",
                 "head" => %{
                   "sha" => "61f167a7821990d822f3d06f3d610c7c87a67431",
                   "ref" => "orocsy/cod-246-preference-miu-guest-setup-controls"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/103/comments" ->
            {:ok,
             [
               %{
                 "body" => "**Apply guest safety preferences before loading cards**",
                 "commit_id" => "61f167a7821990d822f3d06f3d610c7c87a67431",
                 "path" => "src/features/swipe/SwipeExperience.tsx",
                 "line" => 105,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/103#discussion"
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/103/reviews" ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, %{"mode" => "fresh_implementation"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["checkpoint_event"] == "technical-miu-trace"
      assert SymphonyElixir.ControllerEvidence.valid?(preflight)
      assert preflight["branch"] == "orocsy/cod-246-preference-miu-guest-setup-controls"
      assert get_in(preflight, ["review", "feedback_count"]) == 0

      prompt = PromptBuilder.build_prompt(issue, workspace: workspace)
      assert prompt =~ "fresh implementation"
      refute prompt =~ "Review rework execution contract"
      refute prompt =~ "Apply guest safety preferences before loading cards"
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight keeps in-scope test-spec review feedback" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-test-spec-scoped-review-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-265-in-scope-preflight",
        identifier: "COD-265",
        title: "COD-246A test-spec",
        state: "Rework",
        branch_name: "orocsy/cod-265-generated-child-branch",
        description: """
        ## Ticket Type
        test-spec

        ## Integration Branch
        Same shared branch: `orocsy/cod-246-preference-miu-guest-setup-controls`.

        ## Branch / PR Contract
        Use the existing branch/PR only. Do not open a new PR. Do not merge.

        ## Write Scope
        - tests/app/(authenticated)/@modal/page.test.tsx
        - tests/integration/cards-route.test.ts

        ### MIU 1 - Frontend request contract
        Add failing tests for the first cards request payload.
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 103,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/103",
                 "head" => %{
                   "sha" => "61f167a7821990d822f3d06f3d610c7c87a67431",
                   "ref" => "orocsy/cod-246-preference-miu-guest-setup-controls"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/103/comments" ->
            {:ok,
             [
               %{
                 "body" => "**Assert first request carries the bounded guest draft**",
                 "commit_id" => "61f167a7821990d822f3d06f3d610c7c87a67431",
                 "path" => "tests/app/(authenticated)/@modal/page.test.tsx",
                 "line" => 42,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/103#discussion-test"
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/103/reviews" ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, %{"mode" => "review_rework"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["checkpoint_event"] == "review-feedback-classified"
      assert get_in(preflight, ["review", "feedback_count"]) == 1

      assert [%{"path" => "tests/app/(authenticated)/@modal/page.test.tsx"}] =
               get_in(preflight, ["review", "feedback"])
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight filters shared PR review feedback to implementation child write scope" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-impl-shared-pr-scoped-feedback-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-266-preflight",
        identifier: "COD-266",
        title: "COD-246B impl",
        state: "Rework",
        branch_name: "orocsy/cod-266-generated-child-branch",
        description: """
        ## Ticket Type
        implementation

        ## Base Branch
        `orocsy/cod-246-preference-miu-guest-setup-controls` on PR #103.

        ## Integration Branch
        Same shared branch: `orocsy/cod-246-preference-miu-guest-setup-controls`.

        ## Branch / PR Contract
        Use the existing branch/PR only. Do not open a new PR. Do not merge.

        ## Write Scope
        - src/features/swipe/SwipeExperience.tsx
        - tests/unit/swipe-experience-request.test.ts

        ## Shared Files
        - src/app/api/cards/handler.ts is owned by COD-246C. Do not edit it here.

        ## Out Of Scope
        - src/app/api/cards/handler.ts

        ### MIU 1 - Initial load carries guest safety draft
        Send the bounded guest preference draft on first cards load and retry.
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 103,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/103",
                 "head" => %{
                   "sha" => "d47b2d36d682f72129cf63f9f2b8416cb4b6bd45",
                   "ref" => "orocsy/cod-246-preference-miu-guest-setup-controls"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/103/comments" ->
            {:ok,
             [
               %{
                 "body" => "**Apply guest safety preferences before loading cards**",
                 "commit_id" => "d47b2d36d682f72129cf63f9f2b8416cb4b6bd45",
                 "path" => "src/features/swipe/SwipeExperience.tsx",
                 "line" => 105,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/103#discussion-1"
               },
               %{
                 "body" => "**Cap guest preference arrays before storing/prompting** Coordinate with `src/features/swipe/SwipeExperience.tsx` after COD-266.",
                 "commit_id" => "d47b2d36d682f72129cf63f9f2b8416cb4b6bd45",
                 "path" => "src/app/api/swipes/handler.ts",
                 "line" => 53,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/103#discussion-2"
               },
               %{
                 "body" => "**Validate recipes before trusting provider safety**",
                 "commit_id" => "d47b2d36d682f72129cf63f9f2b8416cb4b6bd45",
                 "path" => "src/lib/server/recipe-chats.ts",
                 "line" => 359,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/103#discussion-3"
               },
               %{
                 "body" => "**Move the safety header helper** This should be handled in `src/app/api/cards/handler.ts`.",
                 "commit_id" => "d47b2d36d682f72129cf63f9f2b8416cb4b6bd45",
                 "path" => "src/features/swipe/SwipeExperience.tsx",
                 "line" => 121,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/103#discussion-4"
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/103/reviews" ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, %{"mode" => "review_rework"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["checkpoint_event"] == "review-feedback-classified"
      assert preflight["branch"] == "orocsy/cod-246-preference-miu-guest-setup-controls"
      assert get_in(preflight, ["review", "feedback_count"]) == 1

      assert [%{"path" => "src/features/swipe/SwipeExperience.tsx"}] =
               get_in(preflight, ["review", "feedback"])

      prompt = PromptBuilder.build_prompt(issue, workspace: workspace)
      assert prompt =~ "Apply guest safety preferences before loading cards"
      refute prompt =~ "Cap guest preference arrays"
      refute prompt =~ "Validate recipes before trusting provider safety"
      refute prompt =~ "Move the safety header helper"
      refute prompt =~ "src/app/api/swipes/handler.ts"
      refute prompt =~ "src/lib/server/recipe-chats.ts"
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch prompt routes playwright sandbox corrections to the runtime validation controller" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-playwright-chromium-guidance-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "COD-261")
      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      inbox_dir = Path.join(workspace, ".orocsy/delivery/inbox")
      File.mkdir_p!(state_dir)
      File.mkdir_p!(inbox_dir)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      File.write!(
        Path.join(inbox_dir, "correction_20260626155312_21719ed6.json"),
        Jason.encode!(%{
          "correction_id" => "correction_20260626155312_21719ed6",
          "status" => "open",
          "next_action" => "retry",
          "summary" => "COD-261 focused Playwright validation still blocked by local Chrome launch sandbox",
          "findings" => [
            "Playwright browserType.launch failed because Chrome exited SIGABRT."
          ],
          "required_corrections" => [
            "Retry validation in an environment where Chrome/Playwright can launch."
          ]
        })
      )

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "handoff_recovery",
          "branch" => "orocsy/cod-261",
          "checkpoint_event" => "correction-scoped-fix",
          "first_task" => "Resolve the open Orocsy correction before dirty handoff recovery.",
          "requirements" => %{"runtime_contract_status" => "structured"},
          "toolchain" => %{
            "package_manager" => "pnpm",
            "executables" => %{
              "corepack" => %{"available" => false},
              "pnpm" => %{"available" => true}
            },
            "package_scripts" => ["test"]
          },
          "review" => %{
            "pr_url" => "https://github.com/acme/nutribuddy/pull/101",
            "head_sha" => "5e9fd54fa8"
          },
          "open_corrections" => []
        })
      )

      prompt = SymphonyElixir.DispatchPreflight.prompt_context(workspace)

      assert prompt =~ "Validation command guidance:"
      assert prompt =~ "do not rerun Playwright"
      assert prompt =~ "Runtime Contract final handoff gate"
      assert prompt =~ "validation controller run Playwright outside the worker sandbox"
      assert prompt =~ "Open Orocsy corrections:"
      refute prompt =~ "PLAYWRIGHT_CHANNEL"

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "review_rework",
          "branch" => "orocsy/cod-261",
          "checkpoint_event" => "correction-scoped-fix",
          "first_task" => "Fix current-head review feedback before the stale preflight sees a correction.",
          "requirements" => %{"runtime_contract_status" => "structured"},
          "toolchain" => %{
            "package_manager" => "pnpm",
            "executables" => %{
              "corepack" => %{"available" => false},
              "pnpm" => %{"available" => true}
            },
            "package_scripts" => ["test"]
          },
          "review" => %{
            "pr_url" => "https://github.com/acme/nutribuddy/pull/101",
            "head_sha" => "5e9fd54fa8",
            "feedback" => []
          },
          "open_corrections" => []
        })
      )

      review_prompt = SymphonyElixir.DispatchPreflight.prompt_context(workspace)

      assert review_prompt =~ "Validation command guidance:"
      assert review_prompt =~ "do not rerun Playwright"
      assert review_prompt =~ "Runtime Contract final handoff gate"
      assert review_prompt =~ "validation controller run Playwright outside the worker sandbox"
      assert review_prompt =~ "Worker-required checkpoint: `correction-scoped-fix`"
      assert review_prompt =~ "First task: Resolve the open Orocsy correction"
      assert review_prompt =~ "without worker-side validation"
      assert review_prompt =~ "append handoff.requested"
      refute review_prompt =~ "Fix current-head review feedback before the stale preflight"
      refute review_prompt =~ "PLAYWRIGHT_CHANNEL"

      assert {:ok, live_review_preflight} = SymphonyElixir.DispatchPreflight.read_for_prompt(workspace)
      refute live_review_preflight["first_task"] =~ "run focused validation"

      issue = %Issue{
        id: "issue-cod-261-live-browser-correction",
        identifier: "COD-261",
        title: "Live browser correction",
        description: "Structured review correction prompt",
        state: "Rework",
        url: "https://example.org/issues/COD-261",
        labels: []
      }

      production_prompt = PromptBuilder.build_prompt(issue, workspace: workspace)
      assert production_prompt =~ "Runtime correction dispatch preflight:"
      assert production_prompt =~ "Validation command guidance:"
      assert production_prompt =~ "do not rerun Playwright"
      assert production_prompt =~ "Worker-required checkpoint: `correction-scoped-fix`"
      assert production_prompt =~ "resolve this non-controller correction"
      assert production_prompt =~ "without worker-side validation"
      refute production_prompt =~ "PLAYWRIGHT_CHANNEL"

      large_finding = String.duplicate("validation-output-", 2_000)

      Enum.each(1..6, fn index ->
        File.write!(
          Path.join(inbox_dir, "correction_2026062615531#{index}_extra.json"),
          Jason.encode!(%{
            "correction_id" => "correction-extra-#{index}",
            "status" => "open",
            "next_action" => "retry",
            "summary" => "Extra correction #{index}",
            "findings" => [large_finding],
            "created_at" => "2026-06-26T15:53:1#{index}Z"
          })
        )
      end)

      assert {:ok, bounded_preflight} = SymphonyElixir.DispatchPreflight.read_for_prompt(workspace)
      assert length(bounded_preflight["open_corrections"]) == 5
      refute SymphonyElixir.DispatchPreflight.prompt_context(workspace) =~ large_finding
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight uses focused issue brief to find final integration PR feedback" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-brief-integration-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-190-preflight",
        identifier: "COD-190",
        title: "DeepSeek integration handoff",
        state: "Rework",
        branch_name: "orocsy/cod-190-handoff",
        description: "Handoff issue with focused brief in workspace."
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery"))

      File.write!(Path.join(workspace, ".orocsy/delivery/issue-brief.md"), """
      # COD-190 Issue Brief

      ## Base / Branch Contract

      - Final integration branch: `orocsy/feature-deepseek-provider-integration`.
      - Final PR target: `main`.
      """)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        decoded = URI.decode(endpoint)

        cond do
          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(decoded, "head=acme:orocsy/cod-190-handoff") ->
            {:ok,
             [
               %{
                 "number" => 34,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/34",
                 "head" => %{"sha" => "issue-head", "ref" => "orocsy/cod-190-handoff"}
               }
             ]}

          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(decoded, "head=acme:orocsy/feature-deepseek-provider-integration") ->
            {:ok,
             [
               %{
                 "number" => 33,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/33",
                 "head" => %{
                   "sha" => "integration-head",
                   "ref" => "orocsy/feature-deepseek-provider-integration"
                 }
               }
             ]}

          decoded in [
            "repos/acme/nutribuddy/pulls/33/comments",
            "repos/acme/nutribuddy/pulls/33/reviews",
            "repos/acme/nutribuddy/issues/33/comments",
            "repos/acme/nutribuddy/pulls/34/comments",
            "repos/acme/nutribuddy/pulls/34/reviews",
            "repos/acme/nutribuddy/issues/34/comments"
          ] ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, variables ->
        nodes =
          case variables["number"] do
            33 ->
              [
                %{
                  "isResolved" => false,
                  "isOutdated" => false,
                  "comments" => %{
                    "nodes" => [
                      %{
                        "body" => "Reject invalid provider modes instead of faking.",
                        "path" => "src/app/api/recipe-chats/route.ts",
                        "line" => 514,
                        "createdAt" => "2026-05-18T18:31:40Z",
                        "url" => "https://github.com/acme/nutribuddy/pull/33#discussion"
                      }
                    ]
                  }
                }
              ]

            _ ->
              []
          end

        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => "head",
                 "reviewThreads" => %{
                   "nodes" => nodes,
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert {:ok, %{"mode" => "review_rework"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert get_in(preflight, ["review", "pr_number"]) == 33

      assert get_in(preflight, ["review", "pr_url"]) ==
               "https://github.com/acme/nutribuddy/pull/33"

      assert get_in(preflight, ["review", "head_ref"]) ==
               "orocsy/feature-deepseek-provider-integration"

      assert preflight["branch"] == "orocsy/feature-deepseek-provider-integration"
      assert get_in(preflight, ["review", "feedback_count"]) == 1

      assert get_in(preflight, ["requirements", "issue_brief", "path"]) ==
               ".orocsy/delivery/issue-brief.md"

      assert [%{"path" => "src/app/api/recipe-chats/route.ts"}] =
               get_in(preflight, ["review", "feedback"])
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight routes dirty integration PRs to integration check mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dirty-integration-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-199-preflight",
        identifier: "COD-199",
        title: "Auth Integration Check And Final PR Handoff",
        state: "Rework",
        branch_name: "orocsy/cod-199-auth-integration-check-and-final-pr-handoff",
        description: "Integration handoff issue with focused brief in workspace."
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery"))

      File.write!(Path.join(workspace, ".orocsy/delivery/issue-brief.md"), """
      # COD-199 Issue Brief

      ## Ticket Type
      integration-check

      ## Integration Branch
      orocsy/feature-auth-migration-integration

      ## Write Scope
      - Merge conflict resolution for the auth integration branch.
      - src/features/profile/index.tsx

      ### MIU 1 - Resolve mergeability
      Resolve the current PR conflict only.

      ## Validation
      ```bash
      pnpm typecheck
      ```
      """)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        decoded = URI.decode(endpoint)

        cond do
          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(
                decoded,
                "head=acme:orocsy/cod-199-auth-integration-check-and-final-pr-handoff"
              ) ->
            {:ok, []}

          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(decoded, "per_page=100") ->
            {:ok, []}

          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(decoded, "head=acme:orocsy/feature-auth-migration-integration") ->
            {:ok,
             [
               %{
                 "number" => 54,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/54",
                 "head" => %{
                   "sha" => "integration-head",
                   "ref" => "orocsy/feature-auth-migration-integration"
                 }
               }
             ]}

          decoded == "repos/acme/nutribuddy/pulls/54" ->
            {:ok,
             %{
               "number" => 54,
               "html_url" => "https://github.com/acme/nutribuddy/pull/54",
               "head" => %{
                 "sha" => "integration-head",
                 "ref" => "orocsy/feature-auth-migration-integration"
               },
               "mergeable" => false,
               "mergeable_state" => "dirty"
             }}

          decoded == "repos/acme/nutribuddy/pulls/54/comments" ->
            {:ok,
             [
               %{
                 "body" => "Review feedback exists, but the dirty integration PR must resolve mergeability first.",
                 "commit_id" => "integration-head",
                 "path" => "src/features/profile/index.tsx",
                 "line" => 14,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/54#discussion"
               }
             ]}

          decoded == "repos/acme/nutribuddy/pulls/54/reviews" ->
            {:ok, []}

          String.starts_with?(decoded, "repos/acme/nutribuddy/issues/54/comments?") ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, %{"mode" => "integration_check"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["branch"] == "orocsy/feature-auth-migration-integration"
      assert preflight["checkpoint_event"] == "technical-miu-trace"
      assert get_in(preflight, ["review", "pr_number"]) == 54
      assert get_in(preflight, ["review", "mergeable"]) == false
      assert get_in(preflight, ["review", "mergeable_state"]) == "dirty"
      assert get_in(preflight, ["review", "feedback_count"]) == 0

      prompt = PromptBuilder.build_prompt(issue, workspace: workspace)
      assert String.starts_with?(prompt, "Runtime dispatch preflight:")
      assert prompt =~ "Mode: integration check"
      assert prompt =~ "PR mergeability: `dirty`"
      assert prompt =~ "Integration check execution contract"
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight keeps clean integration PRs out of fresh implementation mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-clean-integration-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-199-clean-preflight",
        identifier: "COD-199",
        title: "Auth Integration Check And Final PR Handoff",
        state: "Rework",
        branch_name: "orocsy/cod-199-auth-integration-check-and-final-pr-handoff",
        description: "Integration handoff issue with focused brief in workspace."
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery"))

      File.write!(Path.join(workspace, ".orocsy/delivery/issue-brief.md"), """
      # COD-199 Issue Brief

      ## Ticket Type
      integration-check

      ## Integration Branch
      orocsy/feature-auth-migration-integration

      ## Write Scope
      - PR #54 head branch only: orocsy/feature-auth-migration-integration
      - Final PR validation notes and handoff comments only.

      ## Validation
      ```bash
      pnpm typecheck
      ```
      """)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        decoded = URI.decode(endpoint)

        cond do
          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(
                decoded,
                "head=acme:orocsy/cod-199-auth-integration-check-and-final-pr-handoff"
              ) ->
            {:ok, []}

          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(decoded, "per_page=100") ->
            {:ok, []}

          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(decoded, "head=acme:orocsy/feature-auth-migration-integration") ->
            {:ok,
             [
               %{
                 "number" => 54,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/54",
                 "head" => %{
                   "sha" => "integration-head",
                   "ref" => "orocsy/feature-auth-migration-integration"
                 }
               }
             ]}

          decoded == "repos/acme/nutribuddy/pulls/54" ->
            {:ok,
             %{
               "number" => 54,
               "html_url" => "https://github.com/acme/nutribuddy/pull/54",
               "head" => %{
                 "sha" => "integration-head",
                 "ref" => "orocsy/feature-auth-migration-integration"
               },
               "mergeable" => true,
               "mergeable_state" => "clean"
             }}

          decoded in [
            "repos/acme/nutribuddy/pulls/54/comments",
            "repos/acme/nutribuddy/pulls/54/reviews",
            "repos/acme/nutribuddy/issues/54/comments"
          ] ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, %{"mode" => "integration_check"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["branch"] == "orocsy/feature-auth-migration-integration"
      assert preflight["checkpoint_event"] == "technical-miu-trace"
      assert get_in(preflight, ["review", "pr_number"]) == 54
      assert get_in(preflight, ["review", "mergeable"]) == true
      assert get_in(preflight, ["review", "mergeable_state"]) == "clean"
      assert preflight["first_task"] =~ "Validate the current pushed integration handoff"

      prompt = PromptBuilder.build_prompt(issue, workspace: workspace)
      assert prompt =~ "Mode: integration check"
      assert prompt =~ "PR mergeability: `clean`"
      assert prompt =~ "validate and request/confirm review without product edits"
      refute prompt =~ "Mode: fresh implementation"
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight keeps incidental merge-conflict wording out of integration check mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-implementation-merge-conflict-wording-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-205-preflight",
        identifier: "COD-205",
        title: "Analytics MIU: Flow Instrumentation",
        state: "Rework",
        branch_name: "orocsy/cod-205-analytics-miu-flow-instrumentation",
        description: "Implementation ticket with focused brief in workspace."
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery"))

      File.write!(Path.join(workspace, ".orocsy/delivery/issue-brief.md"), """
      # COD-205 Issue Brief

      ## Ticket Type
      implementation

      ## Integration Branch
      orocsy/feature-analytics-observability-integration

      ## Write Scope
      - Bring latest dependencies forward. If that merge conflicts outside the paths below, record a blocker.
      - src/app/api/cards/route.ts

      ## Validation
      ```bash
      pnpm typecheck
      ```
      """)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        decoded = URI.decode(endpoint)

        cond do
          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(
                decoded,
                "head=acme:orocsy/cod-205-analytics-miu-flow-instrumentation"
              ) ->
            {:ok, []}

          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(decoded, "per_page=100") ->
            {:ok, []}

          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(
                decoded,
                "head=acme:orocsy/feature-analytics-observability-integration"
              ) ->
            {:ok,
             [
               %{
                 "number" => 56,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/56",
                 "head" => %{
                   "sha" => "analytics-head",
                   "ref" => "orocsy/feature-analytics-observability-integration"
                 }
               }
             ]}

          decoded == "repos/acme/nutribuddy/pulls/56" ->
            {:ok,
             %{
               "number" => 56,
               "html_url" => "https://github.com/acme/nutribuddy/pull/56",
               "head" => %{
                 "sha" => "analytics-head",
                 "ref" => "orocsy/feature-analytics-observability-integration"
               },
               "mergeable" => true,
               "mergeable_state" => "clean"
             }}

          decoded in [
            "repos/acme/nutribuddy/pulls/56/comments",
            "repos/acme/nutribuddy/pulls/56/reviews",
            "repos/acme/nutribuddy/issues/56/comments"
          ] ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, %{"mode" => "fresh_implementation"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["branch"] == "orocsy/cod-205-analytics-miu-flow-instrumentation"
      assert get_in(preflight, ["review", "pr_number"]) == 56
      refute preflight["first_task"] =~ "integration handoff"
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight routes dirty local work to handoff recovery mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dirty-handoff-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: false
      )

      issue = %Issue{
        id: "issue-cod-205-dirty-preflight",
        identifier: "COD-205",
        title: "Analytics MIU: Flow Instrumentation",
        state: "Rework",
        branch_name: "orocsy/cod-205-analytics-miu-flow-instrumentation",
        description: "Recover interrupted review work."
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/feature-analytics-observability-integration"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nDirty handoff.\n")

      assert {:ok, %{"mode" => "handoff_recovery"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["branch"] == "orocsy/feature-analytics-observability-integration"
      assert preflight["first_task"] =~ "Recover the existing dirty/local handoff checkpoint"
      assert preflight["first_task"] =~ "fix exact in-scope validation failures"

      prompt = PromptBuilder.build_prompt(issue, workspace: workspace)
      assert prompt =~ "Mode: handoff recovery"
      assert prompt =~ "Dirty workspace recovery is the only task"
      assert prompt =~ "focused validation fails and names exact in-scope files"

      assert prompt =~
               "Record an Orocsy correction and stop only when validation lacks an actionable in-scope target"

      refute prompt =~ "Mode: fresh implementation"

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      inbox_dir = Path.join(workspace, ".orocsy/delivery/inbox")
      File.mkdir_p!(event_dir)
      File.mkdir_p!(inbox_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        Jason.encode!(%{
          "event" => "validation.finished",
          "status" => "passed",
          "tool" => "vitest",
          "command" => "pnpm exec vitest run tests/unit/analytics.test.ts",
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
        }) <> "\n"
      )

      File.write!(
        Path.join(inbox_dir, "correction_dirty_validated_review.json"),
        Jason.encode!(%{
          "correction_id" => "correction_dirty_validated_review",
          "status" => "open",
          "next_action" => "retry",
          "source" => "codex.review-rework",
          "summary" => "Fix README.md analytics review feedback",
          "findings" => ["README.md:2 - keep the analytics handoff bounded"]
        })
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 56,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/56",
                 "head" => %{"sha" => "abc123", "ref" => issue.branch_name}
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/56/comments" ->
            {:ok,
             [
               %{
                 "body" => "Keep the analytics handoff bounded.",
                 "commit_id" => "abc123",
                 "path" => "README.md",
                 "line" => 2,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/56#discussion"
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/56/reviews" ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, %{"mode" => "handoff_recovery"} = reviewed_preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert reviewed_preflight["checkpoint_event"] == "correction-scoped-fix"
      assert reviewed_preflight["first_task"] =~ "existing focused dirty delta first"
      assert reviewed_preflight["first_task"] =~ "without manufacturing another edit"

      reviewed_prompt = PromptBuilder.build_prompt(issue, workspace: workspace)
      assert reviewed_prompt =~ "Dirty validated handoff checkpoint"
      assert reviewed_prompt =~ "without another edit or duplicate validation"
      assert reviewed_prompt =~ "Current-head review feedback"
      assert reviewed_prompt =~ "Keep the analytics handoff bounded."
      assert reviewed_prompt =~ "do not commit or request review until"
      refute reviewed_prompt =~ "Mode: review rework"
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight gives dirty test-spec handoff expected-failure guidance" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dirty-test-spec-handoff-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: false
      )

      issue = %Issue{
        id: "issue-cod-265-dirty-preflight",
        identifier: "COD-265",
        title: "COD-246A test-spec",
        state: "Rework",
        branch_name: "orocsy/cod-246-preference-miu-guest-setup-controls",
        description: """
        ## Ticket Type
        test-spec

        ## Write Scope
        - tests/unit/swipe-experience-request.test.ts

        ## Validation
        ```bash
        pnpm exec vitest run --configLoader runner tests/unit/swipe-experience-request.test.ts
        ```
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.mkdir_p!(Path.join(workspace, "tests/unit"))
      File.write!(Path.join(workspace, "tests/unit/swipe-experience-request.test.ts"), "test('base', () => {})\n")

      {_output, 0} =
        System.cmd("git", ["add", "tests/unit/swipe-experience-request.test.ts"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      File.write!(Path.join(workspace, "tests/unit/swipe-experience-request.test.ts"), "test('expected failure', () => {})\n")

      assert {:ok, %{"mode" => "handoff_recovery"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["first_task"] =~ "dirty test-spec checkpoint"
      assert preflight["first_task"] =~ "implementation is intentionally not present yet"
      assert preflight["first_task"] =~ "do not edit production source"
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight delegates structured dirty test-spec validation to the controller" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-structured-dirty-test-spec-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: false
      )

      issue = %Issue{
        id: "issue-cod-274-dirty-preflight",
        identifier: "COD-274",
        title: "Test-Spec: safe-area app chrome",
        state: "In Progress",
        branch_name: "orocsy/cod-274-safe-area-tests",
        description: """
        ## Runtime Contract

        ```yaml
        schema_version: 1
        ticket_type: test-spec
        base_branch: main
        integration_branch: orocsy/cod-274-safe-area-tests
        dependencies: []
        mius:
          - id: COD-274-MIU-1
            write_scope:
              - tests/e2e/app-shell-responsive.spec.ts
            validations:
              - pnpm exec playwright test tests/e2e/app-shell-responsive.spec.ts
        final_validations:
          - pnpm exec playwright test tests/e2e/app-shell-responsive.spec.ts
        review:
          authority: github_codex
          require_current_head: true
        ```
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.mkdir_p!(Path.join(workspace, "tests/e2e"))
      test_file = Path.join(workspace, "tests/e2e/app-shell-responsive.spec.ts")
      File.write!(test_file, "test('base', () => {})\n")
      {_output, 0} = System.cmd("git", ["add", "."], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)
      File.write!(test_file, "test.fail('expected failure', () => {})\n")

      assert {:ok, %{"mode" => "handoff_recovery"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["checkpoint_event"] == "runtime-contract-gate"
      assert preflight["first_task"] =~ "miu.completion_requested"
      assert preflight["first_task"] =~ "Do not run contract-declared validation inside the Codex worker"
      assert preflight["first_task"] =~ "validation controller"
      assert preflight["first_task"] =~ "Do not edit production source"

      prompt_context = SymphonyElixir.DispatchPreflight.prompt_context(workspace)
      assert prompt_context =~ "append only its exact event"
      assert prompt_context =~ "miu.completion_requested"
      assert prompt_context =~ "handoff.requested"
      refute prompt_context =~ "focused validation such as `gate.post-miu`"

      inbox_dir = Path.join(workspace, ".orocsy/delivery/inbox")
      File.mkdir_p!(inbox_dir)

      File.write!(
        Path.join(inbox_dir, "correction_structured_browser.json"),
        Jason.encode!(%{
          "correction_id" => "correction_structured_browser",
          "status" => "open",
          "next_action" => "retry",
          "summary" => "Browser validation failed in the worker sandbox"
        })
      )

      assert {:ok, %{"mode" => "handoff_recovery"} = corrected_preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert corrected_preflight["checkpoint_event"] == "correction-scoped-fix"
      assert corrected_preflight["first_task"] =~ "Browser validation failed in the worker sandbox"
      assert corrected_preflight["first_task"] =~ "run focused validation"
      refute corrected_preflight["first_task"] =~ "active Runtime Contract gate"

      File.write!(
        Path.join(inbox_dir, "correction_structured_browser.json"),
        Jason.encode!(%{
          "correction_id" => "correction_structured_browser",
          "status" => "resolved",
          "next_action" => "retry",
          "resolved_at" => "2026-07-16T12:00:00Z",
          "summary" => "Browser validation failed in the worker sandbox"
        })
      )

      File.write!(
        Path.join(inbox_dir, "correction_controller_validation.json"),
        Jason.encode!(%{
          "correction_id" => "correction_controller_validation",
          "source" => "symphony.runtime.validation-controller",
          "status" => "open",
          "next_action" => "retry",
          "resolved_at" => nil,
          "summary" => "Controller validation failed",
          "findings" => [
            "Command: pnpm exec vitest run tests/unit/app-shell.test.ts",
            "Reason: command_failed; exit code: 1",
            "Declared write scope: tests/unit/app-shell.test.ts",
            "Validation output:\nFAIL app shell > owns exactly one responsive screen slot\nError: Expect test to fail"
          ],
          "guard" => %{"miu_id" => "COD-274-MIU-1"}
        })
      )

      assert {:ok, %{"mode" => "handoff_recovery"} = controller_preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert controller_preflight["checkpoint_event"] == "runtime-contract-gate"
      assert controller_preflight["first_task"] =~ "active Runtime Contract gate"
      assert controller_preflight["first_task"] =~ "Do not run contract-declared validation inside the Codex worker"

      assert [controller_correction] = controller_preflight["open_corrections"]
      assert controller_correction["source"] == "symphony.runtime.validation-controller"
      assert controller_correction["next_action"] == "retry"
      assert controller_correction["guard"] == %{"miu_id" => "COD-274-MIU-1"}
      assert length(controller_correction["findings"]) == 4
      assert List.last(controller_correction["findings"]) =~ "Expect test to fail"

      controller_prompt = PromptBuilder.build_prompt(issue, workspace: workspace)
      assert controller_prompt =~ "Validation output:"
      assert controller_prompt =~ "owns exactly one responsive screen slot"
      assert controller_prompt =~ "Expect test to fail"

      for index <- 1..5 do
        File.write!(
          Path.join(inbox_dir, "correction_zzzz_generic_#{index}.json"),
          Jason.encode!(%{
            "correction_id" => "correction_zzzz_generic_#{index}",
            "status" => "open",
            "next_action" => "retry",
            "summary" => "Newer generic correction #{index}"
          })
        )
      end

      assert {:ok, %{"mode" => "handoff_recovery"} = generic_first_preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert generic_first_preflight["checkpoint_event"] == "correction-scoped-fix"
      assert generic_first_preflight["first_task"] =~ "Newer generic correction"
      assert length(generic_first_preflight["open_corrections"]) == 6

      assert Enum.any?(generic_first_preflight["open_corrections"], fn correction ->
               correction["source"] == "symphony.runtime.validation-controller"
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight keeps clean in-progress implementation branches in fresh implementation mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-in-progress-implementation-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: false
      )

      issue = %Issue{
        id: "issue-cod-213",
        identifier: "COD-213",
        title: "Cloudflare Runtime Foundation Implementation",
        state: "In Progress",
        branch_name: "orocsy/cod-213-cloudflare-runtime-foundation-implementation",
        description:
          "## Ticket Type\n\nimplementation\n\n## Runtime Problem\n\nContinue the remaining runtime foundation implementation.\n\n## Write Scope\n\n- `package.json`\n\n## Validation\n\n```bash\npnpm lint\n```\n"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://example.org/repo.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          [
            "update-ref",
            "refs/remotes/origin/orocsy/feature-cloudflare-infra-integration",
            "HEAD"
          ],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          ["switch", "-c", "orocsy/cod-213-cloudflare-runtime-foundation-implementation"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nCheckpoint.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Add checkpoint"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          ["branch", "--set-upstream-to", "origin/orocsy/feature-cloudflare-infra-integration"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      assert {:ok, %{"mode" => "fresh_implementation"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["first_task"] =~ "Start with the first MIU"
      refute preflight["first_task"] =~ "Recover the existing dirty/local handoff"
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight ignores copied issue briefs when classifying fresh implementation work" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-brief-dirty-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: false
      )

      issue = %Issue{
        id: "issue-cod-219",
        identifier: "COD-219",
        title: "D1 Schema And Migration Smoke Implementation",
        state: "In Progress",
        branch_name: "orocsy/cod-219-d1-schema-and-migration-smoke-implementation",
        description:
          "## Ticket Type\n\nimplementation\n\n## Runtime Problem\n\nCreate the D1 schema and local migration smoke foundation.\n\n## Write Scope\n\n- `migrations/`\n\n## Validation\n\n```bash\nwrangler d1 migrations apply DB --local\n```\n"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd(
          "git",
          ["switch", "-c", "orocsy/cod-219-d1-schema-and-migration-smoke-implementation"],
          cd: workspace,
          stderr_to_stdout: true
        )

      brief_dir = Path.join(workspace, ".codex/agentic/issue-briefs")
      File.mkdir_p!(brief_dir)
      File.write!(Path.join(brief_dir, "COD-219.md"), "# COD-219\n\nFocused schema brief.\n")

      assert {:ok, %{"mode" => "fresh_implementation"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["first_task"] =~ "Start with the first MIU"
      refute preflight["first_task"] =~ "Recover the existing dirty/local handoff"

      prompt = PromptBuilder.build_prompt(issue, workspace: workspace)
      assert prompt =~ "Issue technical brief is available on disk."
      assert prompt =~ ".codex/agentic/issue-briefs/COD-219.md"
      assert prompt =~ "Mode: fresh implementation"
      refute prompt =~ "Mode: handoff recovery"
      refute prompt =~ "Local handoff recovery checkpoint"
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight routes validated ahead in-progress implementation branches to handoff recovery" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-validated-ahead-handoff-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: false
      )

      issue = %Issue{
        id: "issue-cod-215",
        identifier: "COD-215",
        title: "Cloudflare Provider Implementation",
        state: "In Progress",
        branch_name: "orocsy/cod-215-cloudflare-provider-implementation",
        description:
          "## Ticket Type\n\nimplementation\n\n## Runtime Problem\n\nComplete provider handoff.\n\n## Write Scope\n\n- `src/lib/providers/*`\n\n## Validation\n\n```bash\npnpm exec vitest run tests/unit/lib/providers\n```\n"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://example.org/repo.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          [
            "update-ref",
            "refs/remotes/origin/orocsy/feature-cloudflare-infra-integration",
            "HEAD"
          ],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/cod-215-cloudflare-provider-implementation"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nProvider handoff.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Add provider handoff"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          ["branch", "--set-upstream-to", "origin/orocsy/feature-cloudflare-infra-integration"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      events_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(events_dir)

      File.write!(
        Path.join(events_dir, "events.jsonl"),
        Jason.encode!(%{
          "event" => "tool.finished",
          "tool" => "gate.post-miu",
          "command" => "pnpm exec vitest run tests/unit/lib/providers",
          "status" => "passed",
          "ts" => "2026-06-01T02:00:00Z"
        }) <> "\n"
      )

      assert {:ok, %{"mode" => "handoff_recovery"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["branch"] == "orocsy/cod-215-cloudflare-provider-implementation"
      assert preflight["first_task"] =~ "Recover the existing dirty/local handoff checkpoint"
      refute preflight["first_task"] =~ "Start with the first MIU"
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight keeps handoff recovery on discovered PR head branch when clean" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-clean-handoff-recovery-pr-head-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      origin = Path.join(test_root, "origin.git")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-205-clean-recovery-preflight",
        identifier: "COD-205",
        title: "Analytics MIU: Flow Instrumentation",
        state: "Rework",
        branch_name: "orocsy/cod-205-analytics-miu-flow-instrumentation",
        description: "Recover interrupted review work."
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert {_output, 0} = System.cmd("git", ["init", "--bare", origin], stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["init", "-b", "main"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "symphony@example.test"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd("git", ["config", "user.name", "Symphony Test"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      assert {_output, 0} =
               System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Initial"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} = System.cmd("git", ["remote", "add", "origin", origin], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["push", "-u", "origin", "main"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["switch", "-c", "orocsy/feature-analytics-observability-integration"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nRecovered handoff.\n")

      assert {_output, 0} =
               System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Recovered handoff"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      {head_sha, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      head_sha = String.trim(head_sha)

      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["push", "-u", "origin", "orocsy/feature-analytics-observability-integration"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["switch", "-c", "orocsy/cod-205-analytics-miu-flow-instrumentation"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/events"))

      File.write!(Path.join(workspace, ".orocsy/delivery/issue-brief.md"), """
      # COD-205 Issue Brief

      ## Ticket Type
      implementation

      ## Integration Branch
      orocsy/feature-analytics-observability-integration

      ## Write Scope
      - src/app/api/cards/route.ts
      - tests/integration/analytics-instrumentation.test.ts
      """)

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      File.write!(
        Path.join(workspace, ".orocsy/delivery/events/events.jsonl"),
        Jason.encode!(%{
          "event" => "gate.post-miu",
          "status" => "passed",
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
        }) <> "\n"
      )

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        decoded = URI.decode(endpoint)

        cond do
          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(
                decoded,
                "head=acme:orocsy/cod-205-analytics-miu-flow-instrumentation"
              ) ->
            {:ok, []}

          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(
                decoded,
                "head=acme:orocsy/feature-analytics-observability-integration"
              ) ->
            {:ok,
             [
               %{
                 "number" => 56,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/56",
                 "head" => %{
                   "sha" => head_sha,
                   "ref" => "orocsy/feature-analytics-observability-integration"
                 }
               }
             ]}

          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(decoded, "per_page=100") ->
            {:ok, []}

          decoded == "repos/acme/nutribuddy/pulls/56" ->
            {:ok,
             %{
               "number" => 56,
               "html_url" => "https://github.com/acme/nutribuddy/pull/56",
               "head" => %{
                 "sha" => head_sha,
                 "ref" => "orocsy/feature-analytics-observability-integration"
               },
               "mergeable" => true,
               "mergeable_state" => "clean"
             }}

          decoded in [
            "repos/acme/nutribuddy/pulls/56/comments",
            "repos/acme/nutribuddy/pulls/56/reviews",
            "repos/acme/nutribuddy/issues/56/comments"
          ] ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, %{"mode" => "handoff_recovery"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["branch"] == "orocsy/feature-analytics-observability-integration"

      assert get_in(preflight, ["review", "head_ref"]) ==
               "orocsy/feature-analytics-observability-integration"

      assert get_in(preflight, ["review", "head_sha"]) == head_sha
      assert is_nil(preflight["certification_base_sha"])

      assert {current_branch, 0} =
               System.cmd("git", ["branch", "--show-current"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert String.trim(current_branch) == "orocsy/feature-analytics-observability-integration"
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight prioritizes current review feedback over stale clean branch handoff recovery" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-feedback-over-stale-recovery-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      origin = Path.join(test_root, "origin.git")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-205-feedback-over-recovery",
        identifier: "COD-205",
        title: "Analytics MIU: Flow Instrumentation",
        state: "Rework",
        branch_name: "orocsy/cod-205-analytics-miu-flow-instrumentation",
        description: "Fix current review feedback on the integration PR."
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert {_output, 0} = System.cmd("git", ["init", "--bare", origin], stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["init", "-b", "main"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "symphony@example.test"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd("git", ["config", "user.name", "Symphony Test"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      assert {_output, 0} =
               System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Initial"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} = System.cmd("git", ["remote", "add", "origin", origin], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["push", "-u", "origin", "main"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["switch", "-c", "orocsy/feature-analytics-observability-integration"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nIntegration handoff.\n")

      assert {_output, 0} =
               System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Integration handoff"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      {head_sha, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      head_sha = String.trim(head_sha)

      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["push", "-u", "origin", "orocsy/feature-analytics-observability-integration"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["switch", "-c", "orocsy/cod-205-analytics-miu-flow-instrumentation"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery"))

      File.write!(Path.join(workspace, ".orocsy/delivery/issue-brief.md"), """
      # COD-205 Issue Brief

      ## Ticket Type
      implementation

      ## Integration Branch
      orocsy/feature-analytics-observability-integration

      ## Write Scope
      - tests/integration/cards-route.test.ts
      """)

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        decoded = URI.decode(endpoint)

        cond do
          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(
                decoded,
                "head=acme:orocsy/cod-205-analytics-miu-flow-instrumentation"
              ) ->
            {:ok, []}

          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(
                decoded,
                "head=acme:orocsy/feature-analytics-observability-integration"
              ) ->
            {:ok,
             [
               %{
                 "number" => 56,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/56",
                 "head" => %{
                   "sha" => head_sha,
                   "ref" => "orocsy/feature-analytics-observability-integration"
                 }
               }
             ]}

          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(decoded, "per_page=100") ->
            {:ok, []}

          decoded == "repos/acme/nutribuddy/pulls/56" ->
            {:ok,
             %{
               "number" => 56,
               "html_url" => "https://github.com/acme/nutribuddy/pull/56",
               "head" => %{
                 "sha" => head_sha,
                 "ref" => "orocsy/feature-analytics-observability-integration"
               },
               "mergeable" => true,
               "mergeable_state" => "clean"
             }}

          decoded in [
            "repos/acme/nutribuddy/pulls/56/comments",
            "repos/acme/nutribuddy/pulls/56/reviews",
            "repos/acme/nutribuddy/issues/56/comments"
          ] ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => head_sha,
                 "reviewThreads" => %{
                   "nodes" => [
                     %{
                       "isResolved" => false,
                       "isOutdated" => false,
                       "comments" => %{
                         "nodes" => [
                           %{
                             "author" => %{"login" => "codex"},
                             "body" => "Import cards handler from its new module.",
                             "path" => "tests/integration/cards-route.test.ts",
                             "line" => 13,
                             "originalLine" => 13,
                             "createdAt" => "2026-05-25T15:38:22Z",
                             "outdated" => false,
                             "url" => "https://github.com/acme/nutribuddy/pull/56#discussion"
                           }
                         ]
                       }
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert PromptBuilder.workspace_recovery_checkpoint(workspace) =~
               "Local handoff recovery checkpoint:"

      assert {:ok, %{"mode" => "review_rework"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["branch"] == "orocsy/feature-analytics-observability-integration"
      assert preflight["checkpoint_event"] == "review-feedback-classified"
      assert get_in(preflight, ["review", "feedback_count"]) == 1

      assert [%{"path" => "tests/integration/cards-route.test.ts", "line" => 13}] =
               get_in(preflight, ["review", "feedback"])

      assert {current_branch, 0} =
               System.cmd("git", ["branch", "--show-current"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert String.trim(current_branch) == "orocsy/feature-analytics-observability-integration"
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight routes integration handoff without discovered PR to integration check mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-integration-preflight-no-pr-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-208-no-pr-preflight",
        identifier: "COD-208",
        title: "Analytics Integration Check And Final PR Handoff",
        state: "In Progress",
        branch_name: "orocsy/cod-208-analytics-integration-check-and-final-pr-handoff",
        description: "Integration handoff issue with focused brief in workspace."
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery"))

      File.write!(Path.join(workspace, ".orocsy/delivery/issue-brief.md"), """
      # COD-208 Issue Brief

      ## Ticket Type
      integration-check

      ## Integration Branch
      orocsy/feature-analytics-observability-integration

      ## Write Scope
      - Merge conflict resolution for the analytics integration branch.
      - Final PR validation notes only.

      ### MIU 1 - Analytics integration handoff
      Validate the analytics integration branch and complete final PR handoff.

      ## Validation
      ```bash
      pnpm typecheck
      ```
      """)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        decoded = URI.decode(endpoint)

        cond do
          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, %{"mode" => "integration_check"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["branch"] == "orocsy/feature-analytics-observability-integration"
      assert preflight["checkpoint_event"] == "technical-miu-trace"
      assert get_in(preflight, ["review", "pr_number"]) == nil
      assert get_in(preflight, ["review", "feedback_source"]) == "no_pr"
      assert preflight["first_task"] =~ "configured integration branch"
      assert preflight["first_task"] =~ "create or update the final integration PR"

      prompt = PromptBuilder.build_prompt(issue, workspace: workspace)
      assert prompt =~ "Mode: integration check"
      assert prompt =~ "PR: unknown"
      assert prompt =~ "If PR is unknown"
      refute prompt =~ "Mode: fresh implementation"
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight keeps truncated multibyte review feedback valid UTF-8" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-dispatch-preflight-utf8-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-152-preflight-utf8",
        identifier: "COD-152",
        title: "Swipe feed UI and mutation flow",
        state: "Rework",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow",
        description: """
        ## Write Scope
        - src/features/swipe/**

        ### MIU 1 - UTF-8 review feedback
        Preserve current review feedback in dispatch preflight.
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      review_body = String.duplicate("a", 1_199) <> "🙂 still review feedback"

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 4,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/4",
                 "head" => %{
                   "sha" => "2830e3d4a36de99e8b8f40caeb7858712ad84f6c",
                   "ref" => "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/4/comments" ->
            {:ok,
             [
               %{
                 "body" => review_body,
                 "commit_id" => "2830e3d4a36de99e8b8f40caeb7858712ad84f6c",
                 "path" => "src/features/swipe/SwipeDeck.tsx",
                 "line" => 81,
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

      assert {:ok, %{"mode" => "review_rework"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert [feedback] = get_in(preflight, ["review", "feedback"])
      assert String.valid?(feedback["body"])
      assert String.ends_with?(feedback["body"], "...")

      preflight_path = Path.join(workspace, ".orocsy/delivery/state/dispatch-preflight.json")
      assert {:ok, decoded} = preflight_path |> File.read!() |> Jason.decode()

      assert decoded["review"]["feedback"] |> List.first() |> Map.fetch!("body") ==
               feedback["body"]
    after
      File.rm_rf(test_root)
    end
  end

  test "review rework preflight adds current-head review paths as temporary scope bundle write scope" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-scope-bundle-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-266-preflight",
        identifier: "COD-266",
        title: "Send guest safety draft",
        state: "Rework",
        branch_name: "orocsy/cod-246-preference-miu-guest-setup-controls",
        description: """
        ## Ticket Type
        Implementation

        ## Write Scope
        - src/features/swipe/SwipeExperience.tsx

        ## Out Of Scope
        - src/app/api/cards/handler.ts

        ### MIU 1 - Guest safety draft
        Send guest preferences to the first cards request.

        ## Validation
        ```bash
        pnpm exec vitest run --configLoader runner tests/unit/swipe-experience-request.test.ts
        ```
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      head_sha = "1aebf87ed6ffedf7134581baa6d79c287712fcea"

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 103,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/103",
                 "head" => %{
                   "sha" => head_sha,
                   "ref" => "orocsy/cod-246-preference-miu-guest-setup-controls"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/103/comments" ->
            {:ok,
             [
               %{
                 "body" => """
                 **P1** The `/api/cards` handler still ignores guest safety preferences.

                 Update `src/app/api/cards/handler.ts` so the current PR review path is covered.
                 """,
                 "commit_id" => head_sha,
                 "path" => "src/app/api/cards/handler.ts",
                 "line" => 42,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/103#discussion_r3533275206"
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/103/reviews" ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, %{"mode" => "review_rework"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert get_in(preflight, ["requirements", "write_scope"]) == [
               "src/features/swipe/SwipeExperience.tsx"
             ]

      assert preflight["policy_hash"] == get_in(preflight, ["requirements", "scope_bundle", "policy_hash"])

      bundle = get_in(preflight, ["requirements", "scope_bundle"])

      assert Enum.any?(bundle["write_scope"], fn entry ->
               match?(
                 %{
                   "path" => "src/app/api/cards/handler.ts",
                   "source" => "github.current_head_review",
                   "operation" => "write",
                   "expires" => "review_thread_resolved_or_outdated",
                   "review_url" => "https://github.com/acme/nutribuddy/pull/103#discussion_r3533275206"
                 },
                 entry
               ) and entry["reason"] =~ "/api/cards"
             end)

      assert %{
               "path" => "src/app/api/cards/handler.ts",
               "source" => "linear.out_of_scope",
               "operation" => "read",
               "expires" => "branch"
             } in bundle["denied_scope"]
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight keeps fresh implementation checkpoint as worker-required progress" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fresh-dispatch-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-153-preflight",
        identifier: "COD-153",
        title: "Recipe chat generation",
        state: "In Progress",
        branch_name: "orocsy/cod-153-miu-5-recipe-chat-generation",
        description: """
        ## Write Scope
        - src/app/api/recipes/**
        - src/features/recipe-chat/**

        ## Base Branch
        orocsy/feature-recipe-chat-integration

        ### MIU 1 - Recipe Chat
        Generate recipe chat responses from accepted swipe context.

        ## Validation
        ```bash
        pnpm test -- tests/unit/recipe-chat.test.ts
        ```
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery"))

      File.write!(
        Path.join(workspace, ".orocsy/delivery/issue-brief.md"),
        "# COD-153 Brief\nTarget shape and focused tests.\n"
      )

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") -> {:ok, []}
          true -> {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, %{"mode" => "fresh_implementation"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["checkpoint_event"] == "technical-miu-trace"
      assert is_nil(preflight["certification_base_sha"])
      assert SymphonyElixir.ControllerEvidence.valid?(preflight)

      assert get_in(preflight, ["requirements", "base_branch"]) ==
               "orocsy/feature-recipe-chat-integration"

      assert get_in(preflight, ["requirements", "issue_brief", "path"]) ==
               ".orocsy/delivery/issue-brief.md"

      assert get_in(preflight, ["toolchain", "executables", "npm", "available"]) in [true, false]

      assert get_in(preflight, ["requirements", "write_scope"]) == [
               "src/app/api/recipes/**",
               "src/features/recipe-chat/**"
             ]

      events = File.read!(Path.join(workspace, ".orocsy/delivery/events/events.jsonl"))
      assert events =~ ~s("event":"dispatch.preflight")
      assert events =~ ~s("required_worker_event":"technical-miu-trace")
      refute events =~ ~s("tool":"technical-miu-trace")
      assert events =~ "symphony.runtime.dispatch-preflight"

      state_file = Path.join(workspace, ".orocsy/delivery/state/current.json")
      state = state_file |> File.read!() |> Jason.decode!()
      assert get_in(state, ["dispatch_preflight", "mode"]) == "fresh_implementation"

      prompt = PromptBuilder.build_prompt(issue, workspace: workspace)
      assert String.starts_with?(prompt, "Runtime dispatch preflight:")
      assert prompt =~ "fresh implementation"
      assert prompt =~ "Base/PR target branch: `orocsy/feature-recipe-chat-integration`"
      assert prompt =~ "Issue technical brief is available on disk."
      assert prompt =~ ".orocsy/delivery/issue-brief.md"
      assert prompt =~ "Issue brief: `.orocsy/delivery/issue-brief.md`"
      assert prompt =~ "First MIU: MIU 1 - Recipe Chat"
      assert prompt =~ "First write-scope path: src/app/api/recipes/**"
      assert prompt =~ "Worker-required checkpoint: `technical-miu-trace`"
      assert prompt =~ "Runtime preflight is not worker progress"
      assert prompt =~ "Toolchain preflight:"
      assert prompt =~ "Validation command guidance:"
    after
      File.rm_rf(test_root)
    end
  end

  test "dispatch preflight degrades to fresh implementation when review inspection fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-dispatch-preflight-failure-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy"
      )

      issue = %Issue{
        id: "issue-cod-153-preflight-review-error",
        identifier: "COD-153",
        title: "Recipe chat generation",
        state: "In Progress",
        branch_name: "orocsy/cod-153-miu-5-recipe-chat-generation",
        description: """
        ## Write Scope
        - src/app/api/recipes/**

        ### MIU 1 - Recipe Chat
        Generate recipe chat responses from accepted swipe context.
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      Application.put_env(:symphony_elixir, :github_api_runner, fn _endpoint ->
        {:error, :network_unavailable}
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, %{"mode" => "fresh_implementation"} = preflight} =
               SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      assert preflight["checkpoint_event"] == "technical-miu-trace"
      assert get_in(preflight, ["review", "feedback_source"]) == "inspection_failed"
      assert get_in(preflight, ["review", "feedback_count"]) == 0
    after
      File.rm_rf(test_root)
    end
  end

  test "runtime dispatch preflight does not satisfy first durable event guard" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-preflight-first-event-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100,
        codex_durable_progress_first_event_max_tokens: 1_000
      )

      issue = %Issue{
        id: "issue-cod-153-preflight-guard",
        identifier: "COD-153",
        title: "Recipe chat generation",
        state: "In Progress",
        branch_name: "orocsy/cod-153-miu-5-recipe-chat-generation",
        description: """
        ## Write Scope
        - src/features/recipe-chat/**

        ### MIU 1 - Recipe Chat
        Generate recipe chat responses.

        ## Validation
        ```bash
        pnpm test -- tests/unit/recipe-chat.test.ts
        ```
        """
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert {:ok, _preflight} = SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue.id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            workspace_path: workspace,
            started_at: DateTime.add(DateTime.utc_now(), -1, :second),
            codex_total_tokens: 2_000
          }
        },
        claimed: MapSet.new([issue.id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)
      refute Map.has_key?(state.running, issue.id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()
      assert correction["source"] == "symphony.runtime.missing-first-durable-event"
      assert correction["guard"]["first_event_max_tokens"] == 1_000
    after
      File.rm_rf(test_root)
    end
  end

  test "review rework preflight does not satisfy first edit token budget" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-preflight-first-edit-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100_000,
        codex_durable_progress_first_event_max_tokens: 120_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cod-152-review-first-edit",
        identifier: "COD-152",
        title: "Swipe feed UI and mutation flow",
        state: "Rework",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow",
        description: """
        ## Write Scope
        - src/features/swipe/**

        ### MIU 1 - Swipe Deck
        Connect accepted swipes to the recipe flow.
        """
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 4,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/4",
                 "head" => %{
                   "sha" => "2830e3d4a36de99e8b8f40caeb7858712ad84f6c",
                   "ref" => "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/4/comments" ->
            {:ok,
             [
               %{
                 "body" => "Open the recipe flow on accepted right swipes.",
                 "commit_id" => "2830e3d4a36de99e8b8f40caeb7858712ad84f6c",
                 "path" => "src/features/swipe/SwipeDeck.tsx",
                 "line" => 81,
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

      assert {:ok, _preflight} = SymphonyElixir.DispatchPreflight.prepare(workspace, issue)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue.id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            workspace_path: workspace,
            started_at: DateTime.add(DateTime.utc_now(), -1, :second),
            codex_total_tokens: 50_000
          }
        },
        claimed: MapSet.new([issue.id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)
      refute Map.has_key?(state.running, issue.id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.missing-first-durable-event"
      assert correction["guard"]["first_event_max_tokens"] == 45_000
      assert correction["guard"]["first_event_progress_tokens"] == 50_000
      assert correction["guard"]["cached_input_tokens"] == 0
      assert correction["summary"] =~ "first durable Orocsy progress event"
    after
      File.rm_rf(test_root)
    end
  end

  test "pending Codex review request stops review rework before first durable event correction" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-request-first-event-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100_000,
        codex_durable_progress_first_event_max_tokens: 1_000
      )

      issue = %Issue{
        id: "issue-cod-205-review-request-wait",
        identifier: "COD-205",
        title: "Analytics MIU review request wait",
        state: "Rework",
        branch_name: "orocsy/cod-205-analytics-miu-flow-instrumentation"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      preflight_path = Path.join(workspace, ".orocsy/delivery/state/dispatch-preflight.json")
      File.mkdir_p!(Path.dirname(preflight_path))
      File.write!(preflight_path, Jason.encode!(%{"mode" => "review_rework"}))

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 55,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/55",
                 "head" => %{
                   "sha" => "6b7fdf439d8e62163607af21bdf7a98fcbef31b8",
                   "ref" => "orocsy/cod-205-analytics-miu-flow-instrumentation"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/55/comments" ->
            {:ok,
             [
               %{
                 "body" => "Migrate live guest data stores, not only seeded shadow state.",
                 "commit_id" => "6b7fdf439d8e62163607af21bdf7a98fcbef31b8",
                 "path" => "src/lib/server/guest-migration.ts",
                 "line" => 282,
                 "created_at" => "2026-05-24T13:08:00Z",
                 "html_url" => "https://github.com/acme/nutribuddy/pull/55#discussion"
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/55/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/55/comments?") ->
            {:ok,
             [
               %{
                 "body" => "@codex review",
                 "created_at" => "2026-05-24T13:11:20Z",
                 "html_url" => "https://github.com/acme/nutribuddy/pull/55#issuecomment"
               }
             ]}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue.id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            workspace_path: workspace,
            started_at: DateTime.add(DateTime.utc_now(), -1, :second),
            codex_total_tokens: 1_500
          }
        },
        claimed: MapSet.new([issue.id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      refute Map.has_key?(state.running, issue.id)
      refute MapSet.member?(state.claimed, issue.id)
      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "review rework first edit token budget allows configured forty five thousand ceiling" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-configured-first-edit-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100_000,
        codex_durable_progress_first_event_max_tokens: 45_000
      )

      issue = %Issue{
        id: "issue-cod-182-review-configured-first-edit",
        identifier: "COD-182",
        title: "Profile preferences route",
        state: "Rework",
        branch_name: "orocsy/cod-182-savedprofile-miu-profile-preferences-route"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      preflight_path = Path.join(workspace, ".orocsy/delivery/state/dispatch-preflight.json")
      File.mkdir_p!(Path.dirname(preflight_path))
      File.write!(preflight_path, Jason.encode!(%{"mode" => "review_rework"}))

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue.id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            workspace_path: workspace,
            started_at: DateTime.add(DateTime.utc_now(), -1, :second),
            codex_total_tokens: 30_054
          }
        },
        claimed: MapSet.new([issue.id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      assert Map.has_key?(state.running, issue.id)
      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "review rework first edit token budget ignores cached prompt input" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-cached-first-edit-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100_000,
        codex_durable_progress_first_event_max_tokens: 120_000
      )

      issue = %Issue{
        id: "issue-cod-152-review-cached-first-edit",
        identifier: "COD-152",
        title: "Swipe feed UI and mutation flow",
        state: "Rework",
        branch_name: "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      preflight_path = Path.join(workspace, ".orocsy/delivery/state/dispatch-preflight.json")
      File.mkdir_p!(Path.dirname(preflight_path))
      File.write!(preflight_path, Jason.encode!(%{"mode" => "review_rework"}))

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue.id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            workspace_path: workspace,
            started_at: DateTime.add(DateTime.utc_now(), -1, :second),
            codex_total_tokens: 52_626,
            codex_cached_input_tokens: 30_976
          }
        },
        claimed: MapSet.new([issue.id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)
      assert Map.has_key?(state.running, issue.id)
      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "fresh implementation first event token budget ignores cached prompt input" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fresh-cached-first-event-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100_000,
        codex_durable_progress_first_event_max_tokens: 45_000
      )

      issue = %Issue{
        id: "issue-cod-175-fresh-cached-first-event",
        identifier: "COD-175",
        title: "Saved/Profile Contract",
        state: "In Progress",
        branch_name: "orocsy/cod-175-savedprofile-contract"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue.id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            workspace_path: workspace,
            started_at: DateTime.add(DateTime.utc_now(), -1, :second),
            codex_total_tokens: 109_334,
            codex_cached_input_tokens: 83_456
          }
        },
        claimed: MapSet.new([issue.id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      assert Map.has_key?(state.running, issue.id)
      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "fresh implementation first event token budget ignores initial prompt input baseline" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fresh-initial-input-first-event-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100_000,
        codex_durable_progress_first_event_max_tokens: 45_000
      )

      issue = %Issue{
        id: "issue-cod-175-fresh-initial-input-first-event",
        identifier: "COD-175",
        title: "Saved/Profile Contract",
        state: "In Progress",
        branch_name: "orocsy/cod-175-savedprofile-contract"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue.id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            workspace_path: workspace,
            started_at: DateTime.add(DateTime.utc_now(), -1, :second),
            codex_total_tokens: 56_254,
            codex_cached_input_tokens: 11_008,
            codex_initial_uncached_input_tokens: 16_602
          }
        },
        claimed: MapSet.new([issue.id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      assert Map.has_key?(state.running, issue.id)
      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "fresh implementation no durable progress guard ignores cached prompt input" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fresh-cached-no-progress-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 45_000,
        codex_durable_progress_first_event_max_tokens: 120_000
      )

      issue = %Issue{
        id: "issue-cod-175-fresh-cached-no-progress",
        identifier: "COD-175",
        title: "Saved/Profile Contract",
        state: "In Progress",
        branch_name: "orocsy/cod-175-savedprofile-contract"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue.id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            workspace_path: workspace,
            started_at: DateTime.add(DateTime.utc_now(), -70, :second),
            codex_total_tokens: 109_334,
            codex_cached_input_tokens: 83_456
          }
        },
        claimed: MapSet.new([issue.id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      assert Map.has_key?(state.running, issue.id)
      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "review rework no durable progress guard ignores cached prompt input" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-cached-no-progress-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 30_000,
        codex_durable_progress_first_event_max_tokens: 120_000
      )

      issue = %Issue{
        id: "issue-cod-157-review-cached-no-progress",
        identifier: "COD-157",
        title: "Bridge contract accepted swipe to recipe chat",
        state: "Rework",
        branch_name: "orocsy/cod-157-bridge-contract-accepted-swipe-to-recipe-chat"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      preflight_path = Path.join(workspace, ".orocsy/delivery/state/dispatch-preflight.json")
      File.mkdir_p!(Path.dirname(preflight_path))
      File.write!(preflight_path, Jason.encode!(%{"mode" => "review_rework"}))

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue.id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            workspace_path: workspace,
            started_at: DateTime.add(DateTime.utc_now(), -70, :second),
            codex_total_tokens: 110_756,
            codex_cached_input_tokens: 87_040
          }
        },
        claimed: MapSet.new([issue.id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      assert Map.has_key?(state.running, issue.id)
      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "integration check no durable progress guard parks low-output cached loops" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-integration-cached-no-progress-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 30_000,
        codex_durable_progress_first_event_max_tokens: 120_000
      )

      issue = %Issue{
        id: "issue-cod-199-integration-cached-no-progress",
        identifier: "COD-199",
        title: "Auth Integration Check",
        state: "Rework",
        branch_name: "orocsy/feature-auth-migration-integration"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      preflight_path = Path.join(workspace, ".orocsy/delivery/state/dispatch-preflight.json")
      File.mkdir_p!(Path.dirname(preflight_path))
      File.write!(preflight_path, Jason.encode!(%{"mode" => "integration_check"}))

      started_at = DateTime.add(DateTime.utc_now(), -70, :second)
      event_path = Path.join(workspace, ".orocsy/delivery/events/events.jsonl")
      File.mkdir_p!(Path.dirname(event_path))

      File.write!(
        event_path,
        Jason.encode!(%{
          "event" => "tool.finished",
          "tool" => "integration-conflict-slice",
          "status" => "passed",
          "ts" => started_at |> DateTime.add(1, :second) |> DateTime.to_iso8601()
        }) <> "\n"
      )

      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn ->
        if Process.alive?(worker_pid) do
          Process.exit(worker_pid, :kill)
        end
      end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue.id => %{
            pid: worker_pid,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            workspace_path: workspace,
            started_at: started_at,
            codex_total_tokens: 1_206_308,
            codex_cached_input_tokens: 1_200_296
          }
        },
        claimed: MapSet.new([issue.id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      refute Map.has_key?(state.running, issue.id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.no-durable-progress"
      assert correction["guard"]["min_tokens"] == 5_000
    after
      File.rm_rf(test_root)
    end
  end

  test "integration check progress clock ignores unresolved dirty file mtimes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-integration-dirty-clock-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 30_000,
        codex_durable_progress_first_event_max_tokens: 120_000
      )

      issue = %Issue{
        id: "issue-cod-199-integration-dirty-clock",
        identifier: "COD-199",
        title: "Auth Integration Check",
        state: "Rework",
        branch_name: "orocsy/feature-auth-migration-integration"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} = System.cmd("git", ["branch", "-M", "main"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["switch", "-c", "worker"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      preflight_path = Path.join(workspace, ".orocsy/delivery/state/dispatch-preflight.json")
      File.mkdir_p!(Path.dirname(preflight_path))
      File.write!(preflight_path, Jason.encode!(%{"mode" => "integration_check"}))

      started_at = DateTime.add(DateTime.utc_now(), -70, :second)
      event_path = Path.join(workspace, ".orocsy/delivery/events/events.jsonl")
      File.mkdir_p!(Path.dirname(event_path))

      File.write!(
        event_path,
        Jason.encode!(%{
          "event" => "tool.finished",
          "tool" => "technical-miu-trace",
          "status" => "passed",
          "ts" => started_at |> DateTime.add(1, :second) |> DateTime.to_iso8601()
        }) <> "\n"
      )

      dirty_path = Path.join(workspace, "tests/integration/recipe-chat-routes.test.ts")
      File.mkdir_p!(Path.dirname(dirty_path))
      File.write!(dirty_path, "<<<<<<< HEAD\nstill conflicted\n>>>>>>> origin/main\n")

      running_entry = %{
        workspace_path: workspace,
        started_at: started_at
      }

      assert Orchestrator.durable_progress_quiet_ms_for_test(running_entry, DateTime.utc_now()) >=
               60_000
    after
      File.rm_rf(test_root)
    end
  end

  test "integration check first event guard parks before long cached analysis" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-integration-first-event-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 30_000,
        codex_durable_progress_first_event_max_tokens: 120_000
      )

      issue = %Issue{
        id: "issue-cod-199-integration-first-event",
        identifier: "COD-199",
        title: "Auth Integration Check",
        state: "Rework",
        branch_name: "orocsy/feature-auth-migration-integration"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      preflight_path = Path.join(workspace, ".orocsy/delivery/state/dispatch-preflight.json")
      File.mkdir_p!(Path.dirname(preflight_path))
      File.write!(preflight_path, Jason.encode!(%{"mode" => "integration_check"}))

      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn ->
        if Process.alive?(worker_pid) do
          Process.exit(worker_pid, :kill)
        end
      end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue.id => %{
            pid: worker_pid,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            workspace_path: workspace,
            started_at: DateTime.add(DateTime.utc_now(), -70, :second),
            codex_total_tokens: 443_305,
            codex_cached_input_tokens: 440_805
          }
        },
        claimed: MapSet.new([issue.id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      refute Map.has_key?(state.running, issue.id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.missing-first-durable-event"
      assert correction["guard"]["first_event_max_tokens"] == 2_000
    after
      File.rm_rf(test_root)
    end
  end

  test "high-token worker with durable progress is not parked" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-durable-progress-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-durable-progress"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-PROGRESS",
        state: "In Progress",
        title: "Durable progress",
        description: "Worker should not park when durable evidence exists",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      started_at = DateTime.add(DateTime.utc_now(), -10, :second)
      baseline_ts = DateTime.add(started_at, -60, :second) |> DateTime.to_iso8601()

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 env: [{"GIT_AUTHOR_DATE", baseline_ts}, {"GIT_COMMITTER_DATE", baseline_ts}],
                 stderr_to_stdout: true
               )

      assert {_output, 0} = System.cmd("git", ["branch", "-M", "main"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["switch", "-c", "worker"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.write!(Path.join(workspace, "progress.txt"), "committed work proves progress\n")
      assert {_output, 0} = System.cmd("git", ["add", "progress.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Add progress"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {commit_ts, 0} =
               System.cmd("git", ["log", "-1", "--format=%cI", "HEAD", "--not", "main"], cd: workspace)

      assert String.trim(commit_ts) != ""

      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      orchestrator_name = Module.concat(__MODULE__, :DurableProgressOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(worker_pid) do
          Process.exit(worker_pid, :kill)
        end

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      running_entry = %{
        pid: worker_pid,
        ref: nil,
        identifier: issue.identifier,
        issue: issue,
        started_at: started_at,
        workspace_path: workspace,
        codex_total_tokens: 500
      }

      assert Orchestrator.durable_progress_quiet_ms_for_test(running_entry, DateTime.utc_now()) <
               60_000

      state =
        %Orchestrator.State{
          max_concurrent_agents: 1,
          running: %{issue_id => running_entry},
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }
        |> Orchestrator.reconcile_no_durable_progress_for_test()

      assert Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.claimed, issue_id)
      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "recent focused validation progress keeps watchdog from parking worker" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-validation-progress-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-runtime-validation-progress"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-VALIDATION-PROGRESS",
        state: "In Progress",
        title: "Runtime validation progress",
        description: "Successful focused validation should count as live progress",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      orchestrator_name = Module.concat(__MODULE__, :RuntimeValidationProgressOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(worker_pid) do
          Process.exit(worker_pid, :kill)
        end

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      started_at = DateTime.add(DateTime.utc_now(), -10, :second)

      running_entry = %{
        pid: worker_pid,
        ref: nil,
        identifier: issue.identifier,
        issue: issue,
        started_at: started_at,
        workspace_path: workspace,
        codex_total_tokens: 500,
        last_validation_command: "npm run typecheck -- --pretty false",
        last_validation_progress_at: DateTime.utc_now()
      }

      assert Orchestrator.durable_progress_quiet_ms_for_test(running_entry, DateTime.utc_now()) <
               60_000

      state =
        :sys.get_state(pid)
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Orchestrator.reconcile_no_durable_progress_for_test()

      assert Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.claimed, issue_id)
      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "codex function-call validation output records command evidence and progress" do
    command_at = DateTime.add(DateTime.utc_now(), -2, :second)
    output_at = DateTime.utc_now()

    running_entry = %{
      started_at: DateTime.add(command_at, -30, :second),
      recent_codex_events: [],
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_cached_input_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      codex_last_reported_cached_input_tokens: 0,
      session_id: nil,
      turn_count: 0
    }

    function_call_update = %{
      event: :notification,
      timestamp: command_at,
      payload: %{
        payload: %{
          "method" => "codex/event/response_item",
          "params" => %{
            "type" => "response_item",
            "payload" => %{
              "type" => "function_call",
              "name" => "exec_command",
              "arguments" => Jason.encode!(%{"cmd" => "pnpm typecheck"})
            }
          }
        }
      }
    }

    function_output_update = %{
      event: :notification,
      timestamp: output_at,
      payload: %{
        payload: %{
          "method" => "codex/event/response_item",
          "params" => %{
            "type" => "response_item",
            "payload" => %{
              "type" => "function_call_output",
              "call_id" => "call-validation",
              "output" => "Process exited with code 0\n> nutribuddy@0.1.0 typecheck\n> tsc --noEmit\n"
            }
          }
        }
      }
    }

    {running_entry, _token_delta} =
      Orchestrator.integrate_codex_update_for_test(running_entry, function_call_update)

    assert running_entry.last_validation_command == "pnpm typecheck"

    {running_entry, _token_delta} =
      Orchestrator.integrate_codex_update_for_test(running_entry, function_output_update)

    assert running_entry.last_validation_command == "pnpm typecheck"
    assert DateTime.compare(running_entry.last_validation_progress_at, output_at) == :eq

    assert Enum.any?(running_entry.recent_codex_events, fn event ->
             event =~ "command=pnpm typecheck" and event =~ "outcome=passed"
           end)
  end

  test "codex function-call build failure records validation blocker evidence" do
    command_at = DateTime.add(DateTime.utc_now(), -2, :second)
    output_at = DateTime.utc_now()

    running_entry = %{
      started_at: DateTime.add(command_at, -30, :second),
      recent_codex_events: [],
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_cached_input_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      codex_last_reported_cached_input_tokens: 0,
      session_id: nil,
      turn_count: 0
    }

    function_call_update = %{
      event: :notification,
      timestamp: command_at,
      payload: %{
        payload: %{
          "method" => "codex/event/response_item",
          "params" => %{
            "type" => "response_item",
            "payload" => %{
              "type" => "function_call",
              "name" => "exec_command",
              "arguments" => Jason.encode!(%{"cmd" => "pnpm exec next build --webpack"})
            }
          }
        }
      }
    }

    function_output_update = %{
      event: :notification,
      timestamp: output_at,
      payload: %{
        payload: %{
          "method" => "codex/event/response_item",
          "params" => %{
            "type" => "response_item",
            "payload" => %{
              "type" => "function_call_output",
              "call_id" => "call-validation",
              "output" => "Process exited with code 1\nFailed to compile.\nsrc/app/api/cards/route.ts Type error: Route handler export is invalid\n"
            }
          }
        }
      }
    }

    {running_entry, _token_delta} =
      Orchestrator.integrate_codex_update_for_test(running_entry, function_call_update)

    assert running_entry.last_validation_command == "pnpm exec next build --webpack"

    {running_entry, _token_delta} =
      Orchestrator.integrate_codex_update_for_test(running_entry, function_output_update)

    assert running_entry.last_validation_command == "pnpm exec next build --webpack"
    assert running_entry.last_validation_failure_command == "pnpm exec next build --webpack"
    assert DateTime.compare(running_entry.last_validation_failure_at, output_at) == :eq
    assert running_entry.last_validation_failure_evidence =~ "src/app/api/cards/route.ts"
    assert is_nil(running_entry.last_validation_progress_at)

    assert Enum.any?(running_entry.recent_codex_events, fn event ->
             event =~ "command=pnpm exec next build --webpack" and event =~ "outcome=failed"
           end)
  end

  test "quiet high-token worker with validation failure creates validation blocker correction" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-validation-blocker-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 1,
        codex_durable_progress_min_tokens: 100,
        codex_durable_progress_first_event_max_tokens: 120_000
      )

      issue_id = "issue-validation-blocker"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-VALIDATION-BLOCKER",
        state: "In Progress",
        title: "Validation blocker",
        description: "Failed build should become validation rework, not dirty handoff recovery",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      started_at = DateTime.utc_now()
      Process.sleep(5)
      failed_at = DateTime.utc_now()

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            started_at: started_at,
            workspace_path: workspace,
            codex_total_tokens: 500,
            last_validation_command: "pnpm exec next build --webpack",
            last_validation_failure_at: failed_at,
            last_validation_failure_command: "pnpm exec next build --webpack",
            last_validation_failure_evidence: "src/app/api/cards/route.ts Type error: Route handler export is invalid",
            recent_codex_events: [
              "event=notification command=pnpm exec next build --webpack outcome=failed detail=src/app/api/cards/route.ts Type error"
            ]
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.validation-blocker"
      assert correction["source_status"] == "retryable"
      assert correction["next_action"] == "retry"
      assert correction["summary"] =~ "pnpm exec next build --webpack"
      refute correction["source"] =~ "no-durable-progress"
      assert Enum.join(correction["findings"], "\n") =~ "src/app/api/cards/route.ts"
      assert correction["guard"]["command"] == "pnpm exec next build --webpack"
    after
      File.rm_rf(test_root)
    end
  end

  test "rescue keeps concrete validation blocker open for bounded validation rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-validation-blocker-rescue-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-validation-blocker-rescue",
        identifier: "MT-VALIDATION-RESCUE",
        state: "In Progress",
        title: "Validation blocker rescue",
        description: "Runtime should redispatch bounded validation rework.",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      {:ok, correction} =
        Workspace.create_correction_in_workspace(workspace, issue, %{
          source: "symphony.runtime.validation-blocker",
          source_status: "retryable",
          summary: "Validation command `pnpm exec next build --webpack` failed.",
          findings: [
            "Validation command failed: pnpm exec next build --webpack",
            "Validation failure evidence: src/app/api/cards/route.ts Type error: Route handler export is invalid"
          ],
          required_corrections: ["Fix the failed validation command."],
          next_action: "retry"
        })

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      refute_receive {:memory_tracker_comment, "issue-validation-blocker-rescue", _body}, 50

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      kept = correction_path |> File.read!() |> Jason.decode!()
      assert kept["status"] == "open"
      assert Workspace.blocking_correction_in_workspace?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "rescue keeps legacy concrete validation command correction open for bounded validation rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-legacy-validation-rescue-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-legacy-validation-rescue",
        identifier: "MT-LEGACY-VALIDATION",
        state: "Rework",
        title: "Legacy validation correction rescue",
        description: "Runtime should redispatch bounded validation rework.",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      {:ok, correction} =
        Workspace.create_correction_in_workspace(workspace, issue, %{
          source: "validation",
          source_status: "blocked",
          summary: "pnpm typecheck fails on pre-existing generated Next cards route export",
          findings: [
            "Command: pnpm typecheck. Output: .next/types/app/api/cards/route.ts(14,13): error TS2344: exported handleCardsRequest is incompatible with Next route allowed exports."
          ],
          required_corrections: [
            "Clean or regenerate .next route types or move handleCardsRequest out of src/app/api/cards/route.ts in a separate scoped fix, then rerun pnpm typecheck."
          ],
          next_action: "block"
        })

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      refute_receive {:memory_tracker_comment, "issue-legacy-validation-rescue", _body}, 50

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      kept = correction_path |> File.read!() |> Jason.decode!()
      assert kept["status"] == "open"
      assert Workspace.blocking_correction_in_workspace?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "rescue keeps handoff validation failure correction open for bounded validation rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-handoff-validation-rescue-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-handoff-validation-rescue",
        identifier: "MT-HANDOFF-VALIDATION",
        state: "In Progress",
        title: "Handoff validation correction rescue",
        description: "Runtime should redispatch bounded handoff validation rework.",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      {:ok, correction} =
        Workspace.create_correction_in_workspace(workspace, issue, %{
          source: "COD-214-handoff-recovery",
          source_status: "blocked",
          summary: "Focused D1 validation failed; dirty migration is not handoff-ready",
          findings: [
            "Command failed: pnpm exec vitest run tests/integration/d1-persistence-contract.test.ts tests/integration/d1-migration-smoke.test.ts. Failure kind: validation. d1-persistence-contract.test.ts failed 5 tests because migrations/0001_d1_persistence_schema.sql is missing expected contract fields/tables."
          ],
          required_corrections: [
            "Update the dirty D1 migration to satisfy the accepted D1 persistence contract."
          ],
          next_action: "block"
        })

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      refute_receive {:memory_tracker_comment, "issue-handoff-validation-rescue", _body}, 50

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      kept = correction_path |> File.read!() |> Jason.decode!()
      assert kept["status"] == "open"
      assert Workspace.blocking_correction_in_workspace?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "rescue keeps lowercase focused recovery validation command correction open" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-focused-validation-rescue-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-focused-validation-rescue",
        identifier: "MT-FOCUSED-VALIDATION",
        state: "In Progress",
        title: "Focused validation correction rescue",
        description: "Runtime should redispatch bounded validation rework.",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      {:ok, correction} =
        Workspace.create_correction_in_workspace(workspace, issue, %{
          source: "runtime-dispatch-preflight",
          source_status: "failed",
          summary: "COD-215 dirty handoff validation failed",
          findings: [
            "Focused recovery validation command failed: pnpm exec vitest run tests/unit/lib/providers tests/integration/provider-runtime-contract.test.ts. Failures: expected resolveAiProviderMode('workers-ai') to return 'workers-ai' but got null."
          ],
          required_corrections: [
            "Complete the in-scope provider/env/auth contract work before handoff."
          ],
          next_action: "block"
        })

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      refute_receive {:memory_tracker_comment, "issue-focused-validation-rescue", _body}, 50

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      kept = correction_path |> File.read!() |> Jason.decode!()
      assert kept["status"] == "open"
      assert Workspace.blocking_correction_in_workspace?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "rescue resolves safe exact test search permission correction" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-exact-test-search-permission-rescue-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-exact-test-search-permission-rescue",
        identifier: "MT-EXACT-TEST-SEARCH",
        state: "Rework",
        title: "Exact test search permission rescue",
        description: "Runtime should resolve safe exact test file rg permissions.",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      cards_test = Path.join(workspace, "tests/integration/cards-route.test.ts")
      rework_test = Path.join(workspace, "tests/unit/cod-205-review-rework.test.ts")
      analytics_test = Path.join(workspace, "tests/integration/analytics-instrumentation.test.ts")

      File.mkdir_p!(Path.dirname(cards_test))
      File.mkdir_p!(Path.dirname(rework_test))
      File.mkdir_p!(Path.dirname(analytics_test))
      File.write!(cards_test, "test('cards route', () => expect(true).toBe(true));\n")
      File.write!(rework_test, "test('review rework', () => expect(true).toBe(true));\n")
      File.write!(analytics_test, "test('analytics', () => expect(true).toBe(true));\n")

      {:ok, correction} =
        Workspace.create_correction_in_workspace(workspace, issue, %{
          source: "symphony.runtime.permission",
          source_status: "blocked",
          summary: "Symphony stopped because the Codex worker requested approval.",
          findings: [
            "2026-05-25T14:28:03Z event=forbidden_command command=/bin/zsh -lc 'rg -n start_clicked tests/integration/cards-route.test.ts tests/unit/cod-205-review-rework.test.ts tests/integration/analytics-instrumentation.test.ts'",
            "Guard reason: forbidden rg command"
          ],
          required_corrections: ["Review the requested approval/input."],
          next_action: "block"
        })

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      assert_receive {:memory_tracker_comment, "issue-exact-test-search-permission-rescue", body}
      assert body =~ "safe read-only permission correction"
      assert body =~ "bounded `rg -n`/`grep -n`"

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      resolved = correction_path |> File.read!() |> Jason.decode!()
      assert resolved["status"] == "resolved"

      assert resolved["resolution_summary"] =~
               "permission_guard_resolved_by_exact_test_search_policy"

      refute Workspace.blocking_correction_in_workspace?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "rescue resolves exact test/spec candidate search permission correction" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-exact-test-candidate-search-permission-rescue-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-exact-test-candidate-search-permission-rescue",
        identifier: "MT-EXACT-TEST-CANDIDATE-SEARCH",
        state: "Rework",
        title: "Exact test candidate search permission rescue",
        description: "Runtime should resolve safe exact test/spec candidate rg permissions.",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      {:ok, correction} =
        Workspace.create_correction_in_workspace(workspace, issue, %{
          source: "symphony.runtime.permission",
          source_status: "blocked",
          summary: "Symphony stopped because the Codex worker requested approval.",
          findings: [
            ~S|2026-05-25T16:29:37Z event=forbidden_command command=/bin/zsh -lc 'rg -n "handleCardsRequest" src/app/api/cards/handler.test.ts src/app/api/cards/route.test.ts src/app/api/cards/route.spec.ts tests/api/cards.test.ts'|,
            "Guard reason: forbidden rg command"
          ],
          required_corrections: ["Review the requested approval/input."],
          next_action: "block"
        })

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state

      assert_receive {:memory_tracker_comment, "issue-exact-test-candidate-search-permission-rescue", body}

      assert body =~ "safe read-only permission correction"
      assert body =~ "exact test/spec file paths"

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      resolved = correction_path |> File.read!() |> Jason.decode!()
      assert resolved["status"] == "resolved"

      assert resolved["resolution_summary"] =~
               "permission_guard_resolved_by_exact_test_search_policy"

      refute Workspace.blocking_correction_in_workspace?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "rescue resolves worker PR review polling permission correction" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-polling-permission-rescue-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-review-polling-permission-rescue",
        identifier: "MT-REVIEW-POLLING",
        state: "Rework",
        title: "Review polling permission rescue",
        description: "Runtime should resolve worker review polling permission corrections.",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      {:ok, correction} =
        Workspace.create_correction_in_workspace(workspace, issue, %{
          source: "symphony.runtime.permission",
          source_status: "blocked",
          summary: "Symphony stopped because the Codex worker requested approval.",
          findings: [
            ~S|2026-05-25T14:49:03Z event=forbidden_command command=/bin/zsh -lc "gh api graphql -f query='query($id:ID!){ node(id:$id){ ... on PullRequest { reviewThreads(first:50){ nodes { isResolved isOutdated comments(first:10){ nodes { author { login } body createdAt url path line originalLine diffHunk commit { oid } } } } } } } }' -F id=PR_kw123"|,
            "Guard reason: forbidden gh api command"
          ],
          required_corrections: ["Review the requested approval/input."],
          next_action: "block"
        })

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      rescued = Orchestrator.rescue_open_corrections_for_test([issue], state)

      assert rescued == state
      assert_receive {:memory_tracker_comment, "issue-review-polling-permission-rescue", body}
      assert body =~ "PR review polling permission correction"

      assert body =~
               "orchestration/review-monitor owns request, wait, feedback, and clean-review transitions"

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      resolved = correction_path |> File.read!() |> Jason.decode!()
      assert resolved["status"] == "resolved"

      assert resolved["resolution_summary"] =~
               "permission_guard_resolved_by_orchestration_review_polling_policy"

      refute Workspace.blocking_correction_in_workspace?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "normally completed worker with no-progress telemetry parks correction before retry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-normal-no-progress-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 30_000,
        codex_durable_progress_min_tokens: 15_000,
        codex_durable_progress_first_event_max_tokens: 120_000
      )

      issue_id = "issue-normal-no-progress"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-NORMAL-NO-PROGRESS",
        state: "In Progress",
        title: "Normal no-progress worker",
        description: "A worker can finish normally while still doing no durable work.",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      session_id = "thread-normal-no-progress-turn-normal-no-progress"
      started_at = DateTime.utc_now() |> DateTime.add(-20, :second) |> DateTime.truncate(:second)
      ended_at = DateTime.utc_now() |> DateTime.truncate(:second)

      workers_dir = Path.join(workspace, ".orocsy/delivery/token-telemetry")
      File.mkdir_p!(workers_dir)

      File.write!(
        Path.join(workers_dir, "workers.jsonl"),
        Jason.encode!(%{
          "schema_version" => 1,
          "issue" => issue.identifier,
          "linear_issue_id" => issue.id,
          "worker_session_id" => session_id,
          "thread_id" => "thread-normal-no-progress",
          "turn_id" => "turn-normal-no-progress",
          "turn" => 1,
          "started_at" => DateTime.to_iso8601(started_at),
          "ended_at" => DateTime.to_iso8601(ended_at),
          "status" => "blocked_no_durable_progress",
          "total_tokens" => 42_451,
          "input_tokens" => 41_706,
          "cached_input_tokens" => 22_272,
          "output_tokens" => 745,
          "counted_guard_tokens" => 19_434,
          "durable_progress_events" => [],
          "dirty_files" => [],
          "new_commits" => [],
          "top_phases" => [
            %{"phase" => "handoff", "total_tokens" => 22_061},
            %{"phase" => "command", "total_tokens" => 20_390}
          ],
          "loop_signatures" => ["no_durable_progress", "handoff_loop"]
        }) <> "\n"
      )

      ref = make_ref()

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: nil,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            started_at: started_at,
            workspace_path: workspace,
            session_id: session_id,
            codex_total_tokens: 42_451,
            codex_cached_input_tokens: 22_272
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      assert {:noreply, state} =
               Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      assert state.retry_attempts == %{}

      assert [correction] = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert correction["source"] == "symphony.runtime.no-durable-progress"
      assert correction["source_status"] == "blocked"
      assert correction["next_action"] == "block"
      assert correction["guard"]["total_tokens"] == 42_451
      assert correction["guard"]["durable_progress_guard_tokens"] == 19_434
    after
      File.rm_rf(test_root)
    end
  end

  test "normally completed worker preserves validation blocker before first-event block" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-normal-validation-before-first-event-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 30_000,
        codex_durable_progress_min_tokens: 100_000,
        codex_durable_progress_first_event_max_tokens: 1_000
      )

      issue_id = "issue-normal-validation-before-first-event"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-NORMAL-VALIDATION-FIRST-EVENT",
        state: "In Progress",
        title: "Normal validation failure before first-event block",
        description: "Validation failure should remain the actionable runtime correction.",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      session_id = "thread-validation-first-event-turn"
      started_at = DateTime.utc_now() |> DateTime.add(-20, :second) |> DateTime.truncate(:second)
      failed_at = DateTime.add(started_at, 8, :second)
      ended_at = DateTime.add(started_at, 18, :second)

      workers_dir = Path.join(workspace, ".orocsy/delivery/token-telemetry")
      File.mkdir_p!(workers_dir)

      File.write!(
        Path.join(workers_dir, "workers.jsonl"),
        Jason.encode!(%{
          "schema_version" => 1,
          "issue" => issue.identifier,
          "linear_issue_id" => issue.id,
          "worker_session_id" => session_id,
          "thread_id" => "thread-validation-first-event",
          "turn_id" => "turn-validation-first-event",
          "turn" => 1,
          "started_at" => DateTime.to_iso8601(started_at),
          "ended_at" => DateTime.to_iso8601(ended_at),
          "status" => "blocked_no_durable_progress",
          "total_tokens" => 2_500,
          "input_tokens" => 2_350,
          "cached_input_tokens" => 0,
          "output_tokens" => 150,
          "counted_guard_tokens" => 500,
          "durable_progress_events" => [],
          "dirty_files" => [],
          "new_commits" => [],
          "top_phases" => [%{"phase" => "validation", "total_tokens" => 2_500}],
          "loop_signatures" => ["no_durable_progress", "validation_loop"]
        }) <> "\n"
      )

      ref = make_ref()

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: nil,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            started_at: started_at,
            workspace_path: workspace,
            session_id: session_id,
            codex_total_tokens: 2_500,
            codex_cached_input_tokens: 0,
            last_validation_failure_at: failed_at,
            last_validation_failure_command: "pnpm test -- tests/unit/cards.test.ts",
            last_validation_failure_evidence: "expected allergies to stay bounded"
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      assert {:noreply, state} =
               Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      assert state.retry_attempts == %{}

      assert [correction] = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert correction["source"] == "symphony.runtime.validation-blocker"
      assert correction["source_status"] == "retryable"
      assert correction["next_action"] == "retry"
      assert correction["guard"]["command"] == "pnpm test -- tests/unit/cards.test.ts"
      assert correction["guard"]["total_tokens"] == 2_500
      assert correction["guard"]["durable_progress_guard_tokens"] == 500
      refute correction["source"] == "symphony.runtime.missing-first-durable-event"
    after
      File.rm_rf(test_root)
    end
  end

  test "normally completed worker parks no-progress correction when session id update is missing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-normal-no-progress-missing-session-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 30_000,
        codex_durable_progress_min_tokens: 15_000,
        codex_durable_progress_first_event_max_tokens: 120_000
      )

      issue_id = "issue-normal-no-progress-missing-session"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-NORMAL-NO-PROGRESS-MISSING-SESSION",
        state: "In Progress",
        title: "Normal no-progress worker missing session",
        description: "A session update can race normal worker completion.",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      running_started_at =
        DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:second)

      stale_started_at = DateTime.add(running_started_at, -120, :second)
      started_at = DateTime.add(running_started_at, 8, :second)
      ended_at = DateTime.add(started_at, 16, :second)

      workers_dir = Path.join(workspace, ".orocsy/delivery/token-telemetry")
      File.mkdir_p!(workers_dir)

      stale_summary =
        Jason.encode!(%{
          "schema_version" => 1,
          "issue" => issue.identifier,
          "linear_issue_id" => issue.id,
          "worker_session_id" => "old-thread-old-turn",
          "started_at" => DateTime.to_iso8601(stale_started_at),
          "ended_at" => DateTime.to_iso8601(DateTime.add(stale_started_at, 10, :second)),
          "status" => "blocked_no_durable_progress",
          "total_tokens" => 99_999,
          "cached_input_tokens" => 0,
          "counted_guard_tokens" => 99_999,
          "durable_progress_events" => [],
          "dirty_files" => [],
          "new_commits" => []
        })

      current_summary =
        Jason.encode!(%{
          "schema_version" => 1,
          "issue" => issue.identifier,
          "linear_issue_id" => issue.id,
          "worker_session_id" => "current-thread-current-turn",
          "thread_id" => "current-thread",
          "turn_id" => "current-turn",
          "turn" => 1,
          "started_at" => DateTime.to_iso8601(started_at),
          "ended_at" => DateTime.to_iso8601(ended_at),
          "status" => "blocked_no_durable_progress",
          "total_tokens" => 43_117,
          "input_tokens" => 42_079,
          "cached_input_tokens" => 39_680,
          "output_tokens" => 1_038,
          "counted_guard_tokens" => 2_399,
          "durable_progress_events" => [],
          "dirty_files" => [],
          "new_commits" => [],
          "top_phases" => [
            %{"phase" => "code_read", "total_tokens" => 22_352},
            %{"phase" => "command", "total_tokens" => 20_765}
          ],
          "loop_signatures" => ["no_durable_progress", "read_loop"]
        })

      File.write!(
        Path.join(workers_dir, "workers.jsonl"),
        stale_summary <> "\n" <> current_summary <> "\n"
      )

      ref = make_ref()

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: nil,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            started_at: running_started_at,
            workspace_path: workspace,
            session_id: nil,
            codex_total_tokens: 43_117,
            codex_cached_input_tokens: 39_680
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      assert {:noreply, state} =
               Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      assert state.retry_attempts == %{}

      assert [correction] = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert correction["source"] == "symphony.runtime.no-durable-progress"
      assert correction["next_action"] == "block"
      assert correction["guard"]["total_tokens"] == 43_117
      assert correction["guard"]["durable_progress_guard_tokens"] == 43_117
      assert correction["guard"]["cached_input_tokens"] == 39_680
    after
      File.rm_rf(test_root)
    end
  end

  test "normally completed worker uses newer issue summary when stored session is stale" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-normal-no-progress-stale-session-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 30_000,
        codex_durable_progress_min_tokens: 15_000,
        codex_durable_progress_first_event_max_tokens: 120_000
      )

      issue_id = "issue-normal-no-progress-stale-session"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-NORMAL-NO-PROGRESS-STALE-SESSION",
        state: "In Progress",
        title: "Normal no-progress worker with stale session",
        description: "A stored session id can point at a prior turn while the latest issue summary is blocked.",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      running_started_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      old_started_at = DateTime.add(running_started_at, 5, :second)
      old_ended_at = DateTime.add(old_started_at, 10, :second)
      current_started_at = DateTime.add(old_ended_at, 5, :second)
      current_ended_at = DateTime.add(current_started_at, 18, :second)

      workers_dir = Path.join(workspace, ".orocsy/delivery/token-telemetry")
      File.mkdir_p!(workers_dir)

      old_summary =
        Jason.encode!(%{
          "schema_version" => 1,
          "issue" => issue.identifier,
          "linear_issue_id" => issue.id,
          "worker_session_id" => "thread-stale-turn-old",
          "thread_id" => "thread-stale",
          "turn_id" => "turn-old",
          "turn" => 1,
          "started_at" => DateTime.to_iso8601(old_started_at),
          "ended_at" => DateTime.to_iso8601(old_ended_at),
          "status" => "completed",
          "total_tokens" => 1_200,
          "cached_input_tokens" => 0,
          "counted_guard_tokens" => 1_200,
          "durable_progress_events" => ["tool.finished"],
          "dirty_files" => [],
          "new_commits" => []
        })

      current_summary =
        Jason.encode!(%{
          "schema_version" => 1,
          "issue" => issue.identifier,
          "linear_issue_id" => issue.id,
          "worker_session_id" => "thread-stale-turn-current",
          "thread_id" => "thread-stale",
          "turn_id" => "turn-current",
          "turn" => 2,
          "started_at" => DateTime.to_iso8601(current_started_at),
          "ended_at" => DateTime.to_iso8601(current_ended_at),
          "status" => "blocked_no_durable_progress",
          "total_tokens" => 20_512,
          "input_tokens" => 20_088,
          "cached_input_tokens" => 2_432,
          "output_tokens" => 424,
          "counted_guard_tokens" => 17_656,
          "durable_progress_events" => [],
          "dirty_files" => [],
          "new_commits" => [],
          "top_phases" => [
            %{"phase" => "command", "total_tokens" => 20_512}
          ],
          "loop_signatures" => ["no_durable_progress"]
        })

      File.write!(
        Path.join(workers_dir, "workers.jsonl"),
        old_summary <> "\n" <> current_summary <> "\n"
      )

      ref = make_ref()

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: nil,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            started_at: running_started_at,
            workspace_path: workspace,
            session_id: "thread-stale-turn-old",
            codex_total_tokens: 20_512,
            codex_cached_input_tokens: 2_432
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      assert {:noreply, state} =
               Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      assert state.retry_attempts == %{}

      assert [correction] = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert correction["source"] == "symphony.runtime.no-durable-progress"
      assert correction["next_action"] == "block"
      assert correction["guard"]["total_tokens"] == 20_512
      assert correction["guard"]["durable_progress_guard_tokens"] == 17_656
    after
      File.rm_rf(test_root)
    end
  end

  test "normally completed worker uses issue summary when stale session timestamp ties latest issue telemetry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-normal-no-progress-stale-session-tie-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 30_000,
        codex_durable_progress_min_tokens: 15_000,
        codex_durable_progress_first_event_max_tokens: 120_000
      )

      issue_id = "issue-normal-no-progress-stale-session-tie"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-NORMAL-NO-PROGRESS-STALE-SESSION-TIE",
        state: "In Progress",
        title: "Normal no-progress stale session timestamp tie",
        description: "Second-granularity telemetry ties should prefer the latest issue entry.",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      running_started_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      shared_started_at = DateTime.add(running_started_at, 5, :second)
      shared_ended_at = DateTime.add(shared_started_at, 10, :second)

      workers_dir = Path.join(workspace, ".orocsy/delivery/token-telemetry")
      File.mkdir_p!(workers_dir)

      old_summary =
        Jason.encode!(%{
          "schema_version" => 1,
          "issue" => issue.identifier,
          "linear_issue_id" => issue.id,
          "worker_session_id" => "thread-tie-turn-old",
          "thread_id" => "thread-tie",
          "turn_id" => "turn-old",
          "turn" => 1,
          "started_at" => DateTime.to_iso8601(shared_started_at),
          "ended_at" => DateTime.to_iso8601(shared_ended_at),
          "status" => "completed",
          "total_tokens" => 1_200,
          "cached_input_tokens" => 0,
          "counted_guard_tokens" => 1_200,
          "durable_progress_events" => ["tool.finished"],
          "dirty_files" => [],
          "new_commits" => []
        })

      current_summary =
        Jason.encode!(%{
          "schema_version" => 1,
          "issue" => issue.identifier,
          "linear_issue_id" => issue.id,
          "worker_session_id" => "thread-tie-turn-current",
          "thread_id" => "thread-tie",
          "turn_id" => "turn-current",
          "turn" => 2,
          "started_at" => DateTime.to_iso8601(shared_started_at),
          "ended_at" => DateTime.to_iso8601(shared_ended_at),
          "status" => "blocked_no_durable_progress",
          "total_tokens" => 20_512,
          "input_tokens" => 20_088,
          "cached_input_tokens" => 2_432,
          "output_tokens" => 424,
          "counted_guard_tokens" => 17_656,
          "durable_progress_events" => [],
          "dirty_files" => [],
          "new_commits" => [],
          "top_phases" => [
            %{"phase" => "command", "total_tokens" => 20_512}
          ],
          "loop_signatures" => ["no_durable_progress"]
        })

      File.write!(
        Path.join(workers_dir, "workers.jsonl"),
        old_summary <> "\n" <> current_summary <> "\n"
      )

      ref = make_ref()

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: nil,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            started_at: running_started_at,
            workspace_path: workspace,
            session_id: "thread-tie-turn-old",
            codex_total_tokens: 20_512,
            codex_cached_input_tokens: 2_432
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      assert {:noreply, state} =
               Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      assert state.retry_attempts == %{}

      assert [correction] = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert correction["source"] == "symphony.runtime.no-durable-progress"
      assert correction["next_action"] == "block"
      assert correction["guard"]["total_tokens"] == 20_512
      assert correction["guard"]["durable_progress_guard_tokens"] == 17_656
    after
      File.rm_rf(test_root)
    end
  end

  test "normally completed worker with retryable correction parks repeated no-progress attempt" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-normal-no-progress-open-retry-correction-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 30_000,
        codex_durable_progress_min_tokens: 15_000,
        codex_durable_progress_first_event_max_tokens: 120_000
      )

      issue_id = "issue-normal-no-progress-open-retry-correction"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-NORMAL-NO-PROGRESS-OPEN-RETRY",
        state: "Rework",
        title: "Normal no-progress worker with open retry correction",
        description: "A retryable product correction should not hide a stuck worker loop.",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, product_correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "controller-pr103-codex-review",
                 source_status: "failed",
                 summary: "Fix src/features/swipe/SwipeExperience.tsx so guest preferences are not sent to /api/cards.",
                 findings: [
                   "Current review feedback requires a scoped edit in src/features/swipe/SwipeExperience.tsx."
                 ],
                 required_corrections: [
                   "Edit src/features/swipe/SwipeExperience.tsx and run tests/unit/swipe-experience-request.test.ts."
                 ],
                 next_action: "retry"
               })

      running_started_at =
        DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:second)

      started_at = DateTime.add(running_started_at, 8, :second)
      ended_at = DateTime.add(started_at, 16, :second)

      workers_dir = Path.join(workspace, ".orocsy/delivery/token-telemetry")
      File.mkdir_p!(workers_dir)

      File.write!(
        Path.join(workers_dir, "workers.jsonl"),
        Jason.encode!(%{
          "schema_version" => 1,
          "issue" => issue.identifier,
          "linear_issue_id" => issue.id,
          "worker_session_id" => "retry-thread-retry-turn",
          "thread_id" => "retry-thread",
          "turn_id" => "retry-turn",
          "turn" => 1,
          "started_at" => DateTime.to_iso8601(started_at),
          "ended_at" => DateTime.to_iso8601(ended_at),
          "status" => "blocked_no_durable_progress",
          "total_tokens" => 42_249,
          "input_tokens" => 41_686,
          "cached_input_tokens" => 22_272,
          "output_tokens" => 563,
          "counted_guard_tokens" => 19_414,
          "durable_progress_events" => [],
          "dirty_files" => [],
          "new_commits" => [],
          "top_phases" => [
            %{"phase" => "handoff", "total_tokens" => 21_880},
            %{"phase" => "command", "total_tokens" => 20_369}
          ],
          "loop_signatures" => ["no_durable_progress", "handoff_loop"]
        }) <> "\n"
      )

      ref = make_ref()

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: nil,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            started_at: running_started_at,
            workspace_path: workspace,
            session_id: nil,
            codex_total_tokens: 42_249,
            codex_cached_input_tokens: 22_272
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      assert {:noreply, state} =
               Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      assert state.retry_attempts == %{}

      open_corrections = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert length(open_corrections) == 2

      assert Enum.any?(
               open_corrections,
               &(&1["correction_id"] == product_correction["correction_id"] and
                   &1["next_action"] == "retry")
             )

      runtime_correction =
        Enum.find(open_corrections, &(&1["source"] == "symphony.runtime.no-durable-progress"))

      assert runtime_correction
      assert runtime_correction["source_status"] == "blocked"
      assert runtime_correction["next_action"] == "block"
      assert runtime_correction["guard"]["total_tokens"] == 42_249
      assert runtime_correction["guard"]["durable_progress_guard_tokens"] == 19_414
    after
      File.rm_rf(test_root)
    end
  end

  test "quiet high-token worker with fresh dirty progress creates handoff retry correction" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dirty-handoff-retry-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100
      )

      issue_id = "issue-dirty-handoff-retry"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-DIRTYHANDOFF",
        state: "In Progress",
        title: "Dirty handoff retry",
        description: "Worker should recover dirty handoff progress instead of a dead-end block",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      started_at = DateTime.add(DateTime.utc_now(), -180, :second)

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      progress_path = Path.join(workspace, "progress.txt")
      File.write!(progress_path, "dirty handoff work\n")

      progress_time =
        DateTime.utc_now()
        |> DateTime.add(-120, :second)
        |> DateTime.to_naive()
        |> NaiveDateTime.to_erl()

      File.touch!(progress_path, progress_time)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            started_at: started_at,
            workspace_path: workspace,
            codex_total_tokens: 500
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.no-durable-progress-handoff"
      assert correction["source_status"] == "retryable"
      assert correction["next_action"] == "retry"
      assert correction["summary"] =~ "fresh local handoff progress"
    after
      File.rm_rf(test_root)
    end
  end

  test "quiet high-token worker cannot use an uncertified pushed review gate as completion" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pushed-review-gate-no-correction-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100,
        codex_durable_progress_first_event_max_tokens: 1_000
      )

      issue_id = "issue-pushed-review-gate"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-PUSHED-GATE",
        state: "Rework",
        title: "Pushed review gate",
        description: "Worker should stop once review request handoff is recorded",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      old_time = DateTime.utc_now() |> DateTime.add(-180, :second)
      old_iso = DateTime.to_iso8601(old_time)
      old_file_time = old_time |> DateTime.to_naive() |> NaiveDateTime.to_erl()
      started_at = DateTime.utc_now() |> DateTime.add(-240, :second)

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      commit_env = [
        {"GIT_AUTHOR_DATE", old_iso},
        {"GIT_COMMITTER_DATE", old_iso}
      ]

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 env: commit_env,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["switch", "-c", "orocsy/mt-pushed-gate"], cd: workspace)

      File.write!(Path.join(workspace, "baseline.txt"), "baseline\nready\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Add pushed checkpoint"],
                 cd: workspace,
                 env: commit_env,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd("git", ["remote", "add", "origin", "https://example.org/repo.git"], cd: workspace)

      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["update-ref", "refs/remotes/origin/orocsy/mt-pushed-gate", "HEAD"],
                 cd: workspace
               )

      assert {_output, 0} =
               System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-pushed-gate"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(state_dir)
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{"mode" => "review_rework", "issue" => issue.identifier})
      )

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        [
          ~s({"event":"gate.post-miu","status":"passed","step":"focused validation passed","ts":"#{old_iso}"}\n),
          ~s({"event":"tool.finished","tool":"codex-review-requested","status":"passed","ts":"#{old_iso}"}\n)
        ]
      )

      workspace
      |> Path.join(".git/logs/**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.each(&File.touch!(&1, old_file_time))

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            started_at: started_at,
            workspace_path: workspace,
            codex_total_tokens: 50_000
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute MapSet.member?(state.completed, issue_id)

      assert [_correction] =
               Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "open correction blocks pushed review gate no-progress shortcut" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pushed-review-gate-open-correction-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100,
        codex_durable_progress_first_event_max_tokens: 1_000
      )

      issue_id = "issue-pushed-review-gate-open-correction"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-PUSHED-GATE-CORRECTION",
        state: "Rework",
        title: "Pushed review gate with open correction",
        description: "Open review correction must override pushed handoff checkpoint",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      old_time = DateTime.utc_now() |> DateTime.add(-180, :second)
      old_iso = DateTime.to_iso8601(old_time)
      old_file_time = old_time |> DateTime.to_naive() |> NaiveDateTime.to_erl()
      started_at = DateTime.utc_now() |> DateTime.add(-240, :second)

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "DESIGN.md"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "DESIGN.md"], cd: workspace)

      commit_env = [
        {"GIT_AUTHOR_DATE", old_iso},
        {"GIT_COMMITTER_DATE", old_iso}
      ]

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 env: commit_env,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["switch", "-c", "orocsy/mt-pushed-gate-correction"], cd: workspace)

      File.write!(Path.join(workspace, "DESIGN.md"), "baseline\nready\n")
      assert {_output, 0} = System.cmd("git", ["add", "DESIGN.md"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Add pushed checkpoint"],
                 cd: workspace,
                 env: commit_env,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd("git", ["remote", "add", "origin", "https://example.org/repo.git"], cd: workspace)

      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["update-ref", "refs/remotes/origin/orocsy/mt-pushed-gate-correction", "HEAD"],
                 cd: workspace
               )

      assert {_output, 0} =
               System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-pushed-gate-correction"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      inbox_dir = Path.join(workspace, ".orocsy/delivery/inbox")
      File.mkdir_p!(state_dir)
      File.mkdir_p!(event_dir)
      File.mkdir_p!(inbox_dir)

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{"mode" => "review_rework", "issue" => issue.identifier})
      )

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        [
          ~s({"event":"gate.post-miu","status":"passed","step":"focused validation passed","ts":"#{old_iso}"}\n),
          ~s({"event":"tool.finished","tool":"codex-review-requested","status":"passed","ts":"#{old_iso}"}\n)
        ]
      )

      File.write!(
        Path.join(inbox_dir, "correction_open.json"),
        Jason.encode!(%{
          "correction_id" => "correction_open",
          "status" => "open",
          "next_action" => "retry",
          "resolved_at" => nil,
          "summary" => "Edit DESIGN.md to address current Codex review feedback.",
          "required_corrections" => ["Update DESIGN.md and run validation."]
        })
      )

      workspace
      |> Path.join(".git/logs/**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.each(&File.touch!(&1, old_file_time))

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            started_at: started_at,
            workspace_path: workspace,
            codex_total_tokens: 50_000
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.completed, issue_id)
      refute [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "quiet high-token worker with stale local handoff checkpoint creates handoff retry correction" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stale-dirty-handoff-retry-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100
      )

      issue_id = "issue-stale-dirty-handoff-retry"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-STALEDIRTYHANDOFF",
        state: "Rework",
        title: "Stale dirty handoff retry",
        description: "Existing dirty handoff work should retry through handoff recovery",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      progress_path = Path.join(workspace, "src/features/swipe/SwipeDeck.tsx")
      File.mkdir_p!(Path.dirname(progress_path))
      File.write!(progress_path, "baseline swipe deck\n")

      assert {_output, 0} =
               System.cmd("git", ["add", "baseline.txt", "src/features/swipe/SwipeDeck.tsx"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.write!(progress_path, "dirty handoff work from an earlier turn\n")

      stale_progress_time =
        DateTime.utc_now()
        |> DateTime.add(-240, :second)
        |> DateTime.to_naive()
        |> NaiveDateTime.to_erl()

      File.touch!(progress_path, stale_progress_time)
      started_at = DateTime.add(DateTime.utc_now(), -180, :second)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            started_at: started_at,
            workspace_path: workspace,
            codex_total_tokens: 500
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.no-durable-progress-handoff"
      assert correction["source_status"] == "retryable"
      assert correction["next_action"] == "retry"
      assert correction["summary"] =~ "handoff progress"
    after
      File.rm_rf(test_root)
    end
  end

  test "quiet high-token worker with already retried stale handoff checkpoint creates blocking correction" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stale-dirty-handoff-repeat-block-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100
      )

      issue_id = "issue-stale-dirty-handoff-repeat-block"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-STALEDIRTYREPEAT",
        state: "Rework",
        title: "Stale dirty handoff repeat",
        description: "Existing dirty handoff work should only get one retry without fresh progress",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      progress_path = Path.join(workspace, "src/features/swipe/SwipeDeck.tsx")
      File.mkdir_p!(Path.dirname(progress_path))
      File.write!(progress_path, "baseline swipe deck\n")

      assert {_output, 0} =
               System.cmd("git", ["add", "baseline.txt", "src/features/swipe/SwipeDeck.tsx"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.write!(progress_path, "dirty handoff work from an earlier turn\n")

      stale_progress_time =
        DateTime.utc_now()
        |> DateTime.add(-240, :second)
        |> DateTime.to_naive()
        |> NaiveDateTime.to_erl()

      File.touch!(progress_path, stale_progress_time)

      assert {:ok, _prior_retry} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "symphony.runtime.no-durable-progress-handoff",
                 source_status: "retryable",
                 summary: "Prior retry for stale local handoff progress.",
                 findings: ["no-durable-progress"],
                 next_action: "retry"
               })

      assert :ok =
               Workspace.resolve_blocking_corrections_in_workspace(
                 workspace,
                 "review_rework_needed: PR #4 has current-head review feedback."
               )

      workspace
      |> Path.join(".orocsy/delivery/inbox/correction_*.*")
      |> Path.wildcard()
      |> Enum.each(&File.touch!(&1, stale_progress_time))

      [
        ".orocsy",
        ".orocsy/delivery",
        ".orocsy/delivery/inbox"
      ]
      |> Enum.map(&Path.join(workspace, &1))
      |> Enum.each(&File.touch!(&1, stale_progress_time))

      started_at = DateTime.add(DateTime.utc_now(), -180, :second)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            started_at: started_at,
            workspace_path: workspace,
            codex_total_tokens: 500
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)

      open_corrections = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert [correction] = open_corrections
      assert correction["source"] == "symphony.runtime.no-durable-progress-repeat"
      assert correction["source_status"] == "blocked"
      assert correction["next_action"] == "escalate"
      refute correction["summary"] =~ "handoff progress"
    after
      File.rm_rf(test_root)
    end
  end

  test "fresh issue branch creation counts as early durable progress" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-branch-progress-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-branch-progress"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-BRANCHPROGRESS",
        state: "In Progress",
        title: "Branch progress",
        description: "Worker should not park after creating an issue branch",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} = System.cmd("git", ["branch", "-M", "main"], cd: workspace)

      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["switch", "-c", "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      started_at = DateTime.utc_now()
      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      orchestrator_name = Module.concat(__MODULE__, :BranchDurableProgressOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(worker_pid) do
          Process.exit(worker_pid, :kill)
        end

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: worker_pid,
        ref: nil,
        identifier: issue.identifier,
        issue: issue,
        started_at: started_at,
        workspace_path: workspace,
        codex_total_tokens: 500
      }

      assert Orchestrator.durable_progress_quiet_ms_for_test(running_entry, DateTime.utc_now()) <
               60_000

      state =
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Orchestrator.reconcile_no_durable_progress_for_test()

      assert Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.claimed, issue_id)
      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "stale issue branch creation does not create no durable progress handoff retry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-branch-no-handoff-retry-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100
      )

      issue_id = "issue-branch-no-handoff-retry"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-BRANCHNOHANDOFF",
        state: "In Progress",
        title: "Branch without handoff progress",
        description: "Branch creation alone should park instead of retrying dirty handoff recovery",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      started_at = DateTime.add(DateTime.utc_now(), -180, :second)

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} = System.cmd("git", ["branch", "-M", "main"], cd: workspace)

      branch_name = "orocsy/cod-157-bridge-contract"

      assert {_output, 0} =
               System.cmd("git", ["switch", "-c", branch_name],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      stale_branch_time =
        DateTime.utc_now()
        |> DateTime.add(-120, :second)
        |> DateTime.to_naive()
        |> NaiveDateTime.to_erl()

      workspace
      |> Path.join(".git/logs/refs/heads/#{branch_name}")
      |> File.touch!(stale_branch_time)

      running_entry = %{
        pid: nil,
        ref: nil,
        identifier: issue.identifier,
        issue: issue,
        started_at: started_at,
        workspace_path: workspace,
        codex_total_tokens: 500
      }

      assert Orchestrator.durable_progress_quiet_ms_for_test(running_entry, DateTime.utc_now()) >=
               60_000

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{issue_id => running_entry},
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      assert state.retry_attempts == %{}

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.no-durable-progress"
      assert correction["source_status"] == "blocked"
      assert correction["next_action"] == "block"
      refute correction["summary"] =~ "handoff progress"
    after
      File.rm_rf(test_root)
    end
  end

  test "issue branch alone does not bypass first durable event token budget" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-branch-first-event-budget-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100,
        codex_durable_progress_first_event_max_tokens: 1_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-branch-without-first-event"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-BRANCHNOEVENT",
        state: "In Progress",
        title: "Branch without first event",
        description: "Branch creation should not allow unlimited context burn",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      started_at = DateTime.add(DateTime.utc_now(), -2, :second)

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} = System.cmd("git", ["branch", "-M", "main"], cd: workspace)

      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["switch", "-c", "orocsy/cod-152-miu-4-swipe-feed-ui-and-mutation-flow"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      orchestrator_name = Module.concat(__MODULE__, :BranchNoFirstEventBudgetOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(worker_pid) do
          Process.exit(worker_pid, :kill)
        end

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: worker_pid,
        ref: nil,
        identifier: issue.identifier,
        issue: issue,
        started_at: started_at,
        workspace_path: workspace,
        codex_total_tokens: 1_500
      }

      state =
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Orchestrator.reconcile_no_durable_progress_for_test()

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.missing-first-durable-event"
      assert correction["source_status"] == "blocked"
      assert correction["next_action"] == "block"
      assert correction["guard"]["first_event_max_tokens"] == 1_000
      assert correction["summary"] =~ "first durable Orocsy progress event"
    after
      File.rm_rf(test_root)
    end
  end

  test "dirty file progress bypasses first durable event token budget" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dirty-first-event-budget-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100,
        codex_durable_progress_first_event_max_tokens: 1_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-dirty-first-event"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-DIRTYFIRST",
        state: "In Progress",
        title: "Dirty first progress",
        description: "Dirty scoped work should count as first substantive progress",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      started_at = DateTime.add(DateTime.utc_now(), -2, :second)

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} = System.cmd("git", ["branch", "-M", "main"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["switch", "-c", "worker"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.write!(Path.join(workspace, "progress.txt"), "dirty work proves first progress\n")

      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn ->
        if Process.alive?(worker_pid) do
          Process.exit(worker_pid, :kill)
        end
      end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: worker_pid,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            started_at: started_at,
            workspace_path: workspace,
            codex_total_tokens: 1_500
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      assert Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.claimed, issue_id)
      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "generated runtime files do not bypass first durable event token budget" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-generated-first-event-budget-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100,
        codex_durable_progress_first_event_max_tokens: 1_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-generated-first-event"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-GENERATEDFIRST",
        state: "In Progress",
        title: "Generated first progress",
        description: "Generated runtime files should not count as first substantive progress",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      started_at = DateTime.add(DateTime.utc_now(), -2, :second)

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert {_output, 0} = System.cmd("git", ["branch", "-M", "main"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["switch", "-c", "worker"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      runtime_state = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(runtime_state)
      File.write!(Path.join(runtime_state, "dispatch-preflight.json"), "{}\n")

      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn ->
        if Process.alive?(worker_pid) do
          Process.exit(worker_pid, :kill)
        end
      end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: worker_pid,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            started_at: started_at,
            workspace_path: workspace,
            codex_total_tokens: 1_500
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)

      [_correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "local handoff recovery checkpoint bypasses first durable event token budget" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dirty-handoff-first-event-budget-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100,
        codex_durable_progress_first_event_max_tokens: 1_000
      )

      issue_id = "issue-dirty-handoff-first-event"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-DIRTYHANDOFFFIRST",
        state: "Rework",
        title: "Dirty handoff first progress",
        description: "Existing dirty handoff work should not be killed by the first-event guard",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)

      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      File.write!(
        Path.join(workspace, "progress.txt"),
        "dirty handoff work from a previous turn\n"
      )

      started_at = DateTime.utc_now()

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            started_at: started_at,
            workspace_path: workspace,
            codex_total_tokens: 1_500
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      assert Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.claimed, issue_id)
      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "first-turn MIU handoff event does not bypass first durable event token budget" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-first-turn-handoff-budget-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100,
        codex_durable_progress_first_event_max_tokens: 1_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-first-turn-handoff-only"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-HANDOFFONLY",
        state: "In Progress",
        title: "First-turn handoff only",
        description: "Worker alive event should not count as durable progress",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      started_at = DateTime.add(DateTime.utc_now(), -2, :second)
      event_ts = DateTime.utc_now() |> DateTime.to_iso8601()

      events_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(events_dir)

      File.write!(
        Path.join(events_dir, "events.jsonl"),
        Jason.encode!(%{
          "event" => "tool.finished",
          "status" => "passed",
          "tool" => "first-turn-miu-handoff",
          "ts" => event_ts
        }) <> "\n"
      )

      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn ->
        if Process.alive?(worker_pid) do
          Process.exit(worker_pid, :kill)
        end
      end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: worker_pid,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            started_at: started_at,
            workspace_path: workspace,
            codex_total_tokens: 1_500
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.missing-first-durable-event"

      assert correction["summary"] =~
               "first-turn-miu-handoff/technical-miu-trace/review-feedback-classified only proves the worker is alive"
    after
      File.rm_rf(test_root)
    end
  end

  test "technical MIU trace event alone does not bypass first durable event token budget" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-technical-trace-only-budget-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100,
        codex_durable_progress_first_event_max_tokens: 1_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-technical-trace-only"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-TRACEONLY",
        state: "In Progress",
        title: "Technical trace only",
        description: "Technical MIU trace without file progress should not count as durable progress",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      started_at = DateTime.add(DateTime.utc_now(), -2, :second)
      event_ts = DateTime.utc_now() |> DateTime.to_iso8601()

      events_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(events_dir)

      File.write!(
        Path.join(events_dir, "events.jsonl"),
        Jason.encode!(%{
          "event" => "tool.finished",
          "status" => "passed",
          "tool" => "technical-miu-trace",
          "ts" => event_ts
        }) <> "\n"
      )

      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn ->
        if Process.alive?(worker_pid) do
          Process.exit(worker_pid, :kill)
        end
      end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: worker_pid,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            started_at: started_at,
            workspace_path: workspace,
            codex_total_tokens: 1_500
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.missing-first-durable-event"

      assert correction["summary"] =~
               "first-turn-miu-handoff/technical-miu-trace/review-feedback-classified only proves the worker is alive"
    after
      File.rm_rf(test_root)
    end
  end

  test "review feedback classification event alone does not bypass first durable event token budget" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-classification-progress-budget-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100,
        codex_durable_progress_first_event_max_tokens: 1_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-review-classification-only"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-REVIEWCLASSIFYONLY",
        state: "Rework",
        title: "Review classification only",
        description: "Review feedback classification is the designed first checkpoint for review rework",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      started_at = DateTime.add(DateTime.utc_now(), -2, :second)
      event_ts = DateTime.utc_now() |> DateTime.to_iso8601()

      events_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(events_dir)

      File.write!(
        Path.join(events_dir, "events.jsonl"),
        Jason.encode!(%{
          "event" => "tool.finished",
          "status" => "passed",
          "tool" => "review-feedback-classified",
          "ts" => event_ts
        }) <> "\n"
      )

      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn ->
        if Process.alive?(worker_pid) do
          Process.exit(worker_pid, :kill)
        end
      end)

      state = %Orchestrator.State{
        max_concurrent_agents: 1,
        running: %{
          issue_id => %{
            pid: worker_pid,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            started_at: started_at,
            workspace_path: workspace,
            codex_total_tokens: 1_500
          }
        },
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      state = Orchestrator.reconcile_no_durable_progress_for_test(state)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)

      [correction_path] =
        Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))

      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.missing-first-durable-event"

      assert correction["summary"] =~
               "first-turn-miu-handoff/technical-miu-trace/review-feedback-classified only proves the worker is alive"
    after
      File.rm_rf(test_root)
    end
  end

  test "dynamic eval events count as durable progress for high-token workers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-eval-progress-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_stall_timeout_ms: 0,
        codex_durable_progress_timeout_ms: 60_000,
        codex_durable_progress_min_tokens: 100
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue_id = "issue-eval-progress"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-EVALPROGRESS",
        state: "In Progress",
        title: "Eval progress",
        description: "Worker should not park after dynamic eval proof",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      started_at = DateTime.add(DateTime.utc_now(), -10, :second)

      events_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(events_dir)

      File.write!(
        Path.join(events_dir, "events.jsonl"),
        Jason.encode!(%{
          "event" => "eval.miu-quality",
          "phase" => "eval",
          "rubric" => "miu-quality",
          "status" => "passed",
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
        }) <> "\n"
      )

      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      orchestrator_name = Module.concat(__MODULE__, :EvalDurableProgressOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(worker_pid) do
          Process.exit(worker_pid, :kill)
        end

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: worker_pid,
        ref: nil,
        identifier: issue.identifier,
        issue: issue,
        started_at: started_at,
        workspace_path: workspace,
        codex_total_tokens: 500
      }

      assert Orchestrator.durable_progress_quiet_ms_for_test(running_entry, DateTime.utc_now()) <
               60_000

      state =
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Orchestrator.reconcile_no_durable_progress_for_test()

      assert Map.has_key?(state.running, issue_id)
      assert MapSet.member?(state.claimed, issue_id)
      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "abnormal worker exit increments retry attempt progressively" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    sent_at_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, sent_at_ms, 39_500, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    sent_at_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, sent_at_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token

    assert {:noreply, ^coalesced_state} =
             Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  defp assert_due_in_range(due_at_ms, sent_at_ms, min_delay_ms, max_delay_ms) do
    now_ms = System.monotonic_time(:millisecond)

    assert due_at_ms >= sent_at_ms + min_delay_ms - 250
    assert due_at_ms <= now_ms + max_delay_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #3"
    assert prompt =~ "handoff-recovery mode"
    assert prompt =~ "validation comes before more code changes"
    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok =
             Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on a Linear ticket `MT-616`"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "This is an unattended orchestration session."
    assert prompt =~ "Only stop early for a true blocker"
    assert prompt =~ "Do not include \"next steps for user\""
    assert prompt =~ "open and follow `.codex/skills/land/SKILL.md`"
    assert prompt =~ "Do not call `gh pr merge` directly"
    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #2"
  end

  test "prompt builder prepends continuation guidance for retry templates that omit it" do
    workflow_prompt = "Ticket {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #2"
    assert prompt =~ "Resume from the current workspace state"
    assert prompt =~ "handoff-recovery mode"
    assert prompt =~ "validation comes before more code changes"
    assert prompt =~ "Ticket MT-201"
  end

  test "prompt builder prepends issue technical brief reference when present" do
    workflow_prompt = "Ticket {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-brief-#{System.unique_integer([:positive])}"
      )

    try do
      brief_dir = Path.join(workspace, ".codex/agentic/issue-briefs")
      File.mkdir_p!(brief_dir)

      File.write!(
        Path.join(brief_dir, "MT-202.md"),
        "Current paths: src/lib/session.ts\nTarget shape: resolveGuestSession()\n"
      )

      issue = %Issue{
        identifier: "MT-202",
        title: "Use issue brief",
        description: "Prompt should include local issue brief",
        state: "In Progress",
        url: "https://example.org/issues/MT-202",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, workspace: workspace)

      assert String.starts_with?(prompt, "Issue technical brief is available on disk.")
      assert prompt =~ ".codex/agentic/issue-briefs/MT-202.md"
      assert prompt =~ "Size:"
      refute prompt =~ "Current paths: src/lib/session.ts"
      refute prompt =~ "Target shape: resolveGuestSession()"
      assert prompt =~ "Ticket MT-202"
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder assigns structured MIU validation to the runtime controller" do
    workflow_prompt = "Ticket {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-controller-validation-prompt-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)

      issue = %Issue{
        identifier: "MT-CONTROLLER-VALIDATION",
        title: "Controller-owned validation",
        state: "In Progress",
        description: """
        ## Runtime Contract

        ```yaml
        schema_version: 1
        ticket_type: test-spec
        base_branch: main
        integration_branch: orocsy/controller-validation
        dependencies: []
        mius:
          - id: MT-CONTROLLER-VALIDATION-MIU-1
            write_scope:
              - tests/e2e/example.spec.ts
            validations:
              - pnpm exec playwright test tests/e2e/example.spec.ts
        final_validations:
          - pnpm exec playwright test tests/e2e/example.spec.ts
        review:
          authority: github_codex
          require_current_head: true
        ```
        """
      }

      prompt = PromptBuilder.build_prompt(issue, workspace: workspace)

      assert String.starts_with?(prompt, "Runtime Contract execution gate:")
      assert prompt =~ "Do not run contract-declared validation inside the Codex worker sandbox"
      assert prompt =~ "validation controller runs it authoritatively"
      assert prompt =~ "miu.completion_requested"
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder caps long Linear descriptions in rendered prompts" do
    workflow_prompt = """
    Ticket {{ issue.identifier }}
    Description:
    {{ issue.description }}
    """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    long_description = String.duplicate("large-context ", 1_000) <> "END_OF_LONG_DESCRIPTION"

    issue = %Issue{
      identifier: "MT-205",
      title: "Keep prompt bounded",
      description: long_description,
      state: "In Progress",
      url: "https://example.org/issues/MT-205",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-205"
    assert prompt =~ "[Linear issue description truncated by Symphony prompt builder."
    refute prompt =~ "END_OF_LONG_DESCRIPTION"
    assert byte_size(prompt) < byte_size(long_description)
  end

  test "prompt builder compacts oversized workflow prompts" do
    workflow_prompt = """
    Ticket {{ issue.identifier }}
    Description:
    {{ issue.description }}

    #{String.duplicate("workflow-policy-noise ", 1_200)}

    FULL_WORKFLOW_TAIL_SHOULD_NOT_INLINE
    """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      id: "issue-207",
      identifier: "MT-207",
      title: "Keep first turn lean",
      description: "Current files: src/app/page.tsx\nTarget behavior: bounded prompt.",
      state: "In Progress",
      branch_name: "orocsy/mt-207-lean-prompt",
      url: "https://example.org/issues/MT-207",
      labels: ["runtime"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Symphony compacted the workflow instructions"
    assert prompt =~ "Workflow reference:"
    assert prompt =~ "Issue snapshot:"
    assert prompt =~ "MT-207"
    assert prompt =~ "orocsy/mt-207-lean-prompt"
    assert prompt =~ "first-turn-miu-handoff"
    assert prompt =~ "review-feedback-classified"
    assert prompt =~ "technical-miu-trace"
    assert prompt =~ "Never merge automatically"
    refute prompt =~ "FULL_WORKFLOW_TAIL_SHOULD_NOT_INLINE"
    assert byte_size(prompt) < 8_000
  end

  test "prompt builder does not duplicate issue brief already embedded in rendered issue description" do
    workflow_prompt =
      """
      Issue description:
      {{ issue.description }}
      """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-brief-dedupe-#{System.unique_integer([:positive])}"
      )

    try do
      brief_dir = Path.join(workspace, ".codex/agentic/issue-briefs")
      File.mkdir_p!(brief_dir)

      brief =
        """
        # MT-202 Technical MIU Brief - Guest Session

        Current paths: src/lib/session.ts
        Target shape: resolveGuestSession()
        """
        |> String.trim()

      File.write!(Path.join(brief_dir, "MT-202.md"), brief)

      issue = %Issue{
        identifier: "MT-202",
        title: "Use issue brief",
        description: "Primary MIUs\n\n#{brief}",
        state: "In Progress",
        url: "https://example.org/issues/MT-202",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, workspace: workspace)

      refute String.starts_with?(prompt, "Issue technical brief:")
      assert prompt =~ "Primary MIUs"
      assert prompt =~ "Current paths: src/lib/session.ts"
      assert prompt |> String.split("MT-202 Technical MIU Brief") |> length() == 2
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder prepends dirty validated handoff checkpoint for retry workspaces" do
    workflow_prompt = "Ticket {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dirty-validated-handoff-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
      File.mkdir_p!(Path.join(workspace, "src"))
      File.write!(Path.join(workspace, "src/app.ts"), "export const ready = true;\n")

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "guest continue regression passed", "ts": "2026-05-11T14:38:47Z"}\n)
      )

      issue = %Issue{
        identifier: "MT-203",
        title: "Finish handoff",
        description: "Retry flow",
        state: "In Progress",
        url: "https://example.org/issues/MT-203",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, attempt: 2, workspace: workspace)

      assert String.starts_with?(prompt, "Dirty validated handoff checkpoint:")
      assert prompt =~ "guest continue regression passed"
      assert prompt =~ "First action: inspect the focused diff with `git diff -- <dirty-file>`"
      assert prompt =~ "Commit and push only after focused validation passes"
      assert prompt =~ "Do not run file-discovery commands such as `git ls-files`"
      assert prompt =~ "Do not query broad Linear/GitHub context"
      assert prompt =~ "Active issue: `MT-203`"
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder keeps dirty validated handoff when later blocker is harness-only" do
    workflow_prompt = "Ticket {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dirty-validated-handoff-harness-blocker-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.mkdir_p!(Path.join(workspace, "tests/e2e"))

      File.write!(
        Path.join(workspace, "tests/e2e/ui-state-matrix.spec.ts"),
        "test('matrix placeholder', () => {});\n"
      )

      {_output, 0} =
        System.cmd("git", ["add", "tests/e2e/ui-state-matrix.spec.ts"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial matrix spec"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["branch", "-M", "main"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd(
          "git",
          ["switch", "-c", "orocsy/cod-261-ui-state-e2e-tdd-route-interaction-matrix"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(
        Path.join(workspace, "tests/e2e/ui-state-matrix.spec.ts"),
        "test('matrix validates shell states', () => {});\n"
      )

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        """
        {"event":"tool.finished","status":"passed","tool":"codex-controller-validation","command":"pnpm lint; pnpm typecheck; pnpm exec playwright test tests/e2e/ui-state-matrix.spec.ts","ts":"2026-06-26T04:26:37Z"}
        {"event":"gate.required-evidence","status":"passed","gate":"required-evidence","ts":"2026-06-26T04:31:04Z"}
        {"event":"gate.declared-scope","status":"passed","gate":"declared-scope","ts":"2026-06-26T04:31:04Z"}
        {"event":"symphony.generated.cleanup","status":"failed","blocked":[{"path":".next","reason":"path is not in the generated-clean allowlist"}],"ts":"2026-06-26T07:19:57Z"}
        {"event":"blocker.correction","status":"blocked","command":"pnpm exec playwright test tests/e2e/ui-state-matrix.spec.ts -> blocked before spec execution: config.webServer next build failed with TurbopackInternalError: Symlink [project]/node_modules is invalid, it points out of the filesystem root.","ts":"2026-06-26T07:23:32Z"}
        """
      )

      issue = %Issue{
        identifier: "COD-261",
        title: "UI State E2E TDD: Route Interaction Matrix",
        description: "Retry flow",
        state: "Backlog",
        url: "https://example.org/issues/COD-261",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, attempt: 2, workspace: workspace)

      assert String.starts_with?(prompt, "Dirty validated handoff checkpoint:")
      assert prompt =~ "codex-controller-validation"
      assert prompt =~ "do not rerun the same validation command"
      refute prompt =~ "Local handoff recovery checkpoint:"
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder prepends local handoff checkpoint when local work lacks validation proof" do
    workflow_prompt = "Ticket {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-local-handoff-no-validation-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["branch", "-M", "main"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-203"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nReview fix.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Fix review feedback"],
          cd: workspace,
          stderr_to_stdout: true
        )

      issue = %Issue{
        identifier: "MT-203",
        title: "Recover local handoff",
        description: "Retry flow",
        state: "In Progress",
        url: "https://example.org/issues/MT-203",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, attempt: 2, workspace: workspace)

      assert String.starts_with?(prompt, "Local handoff recovery checkpoint:")
      assert prompt =~ "no recent passed Orocsy validation/gate evidence"
      assert prompt =~ "run the smallest validation needed for the changed files listed above"
      assert prompt =~ "Local commits ahead of `main` (runtime-provided; do not run `git log`)"
      assert prompt =~ "Fix review feedback"
      assert prompt =~ "Diffstat versus `main` (runtime-provided; do not run `git diff`)"

      assert prompt =~
               "Run bounded `git log` only when the runtime command policy explicitly advertises it"

      refute prompt =~ "inspect the focused local diff and local commits"
      assert prompt =~ "Do not restart or broaden implementation"
      assert prompt =~ "focused validation names exact in-scope files/assertions"
      assert prompt =~ "Ticket MT-203"
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder preserves local handoff checkpoint in review rework preflight prompts" do
    workflow_prompt = "Ticket {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-local-handoff-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["branch", "-M", "main"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-203"],
          cd: workspace,
          stderr_to_stdout: true
        )

      feedback_path = Path.join(workspace, "src/features/swipe/SwipeDeck.tsx")
      File.mkdir_p!(Path.dirname(feedback_path))
      File.write!(feedback_path, "export const reviewFix = true;\n")

      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "review_rework",
          "branch" => "orocsy/mt-203",
          "checkpoint_event" => "review-feedback-classified",
          "first_task" => "Fix current-head feedback.",
          "issue" => "MT-203",
          "review" => %{
            "pr_number" => 4,
            "pr_url" => "https://github.com/acme/nutribuddy/pull/4",
            "head_sha" => "abcdef123456",
            "feedback" => [
              %{
                "path" => "src/features/swipe/SwipeDeck.tsx",
                "line" => 81,
                "body" => "Open the recipe flow on accepted right swipes.",
                "url" => "https://github.com/acme/nutribuddy/pull/4#discussion"
              }
            ]
          }
        })
      )

      issue = %Issue{
        identifier: "MT-203",
        title: "Recover review rework handoff",
        description: "Retry flow",
        state: "Rework",
        url: "https://example.org/issues/MT-203",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, attempt: 2, workspace: workspace)

      assert String.starts_with?(prompt, "Local handoff recovery checkpoint:")
      assert prompt =~ "Runtime dispatch preflight:"
      assert prompt =~ "Runtime command policy (enforced by the Symphony command guard):"

      assert prompt =~
               "`git log -N --oneline [--decorate|--no-decorate]` with `N` from 1 through 20"

      assert prompt =~
               "Run bounded `git log` only when the runtime command policy explicitly advertises it"

      assert prompt =~ "If a dirty/local handoff checkpoint appears above"
      assert prompt =~ "src/features/swipe/SwipeDeck.tsx"
      refute prompt =~ "Ticket MT-203"
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder uses review preflight base branch for runtime git context" do
    workflow_prompt = "Ticket {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-base-context-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")
      {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["branch", "-M", "main"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: workspace)

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nDevelop base.\n")
      {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Develop base"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["update-ref", "refs/remotes/origin/develop", "HEAD"], cd: workspace)

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-207"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nDevelop base.\n\nReview fix.\n")
      {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Fix review feedback"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "README.md"), "# Test\n\nDevelop base.\n\nReview fix.\n\nPending handoff.\n")

      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "review_rework",
          "branch" => "orocsy/mt-207",
          "issue" => "MT-207",
          "requirements" => %{"base_branch" => "develop"}
        })
      )

      issue = %Issue{
        identifier: "MT-207",
        title: "Review rework base context",
        description: "Retry flow",
        state: "Rework",
        url: "https://example.org/issues/MT-207",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, attempt: 2, workspace: workspace)

      assert prompt =~ "Local commits ahead of `origin/develop` (runtime-provided; do not run `git log`)"
      assert prompt =~ "Diffstat versus `origin/develop` (runtime-provided; do not run `git diff`)"
      refute prompt =~ "Local commits ahead of `origin/main`"
      refute prompt =~ "Diffstat versus `origin/main`"
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder enforces open correction mode in review rework preflight prompts" do
    workflow_prompt = "Ticket {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace_root = Path.join(System.tmp_dir!(), "symphony_workspaces")

    workspace =
      Path.join(
        workspace_root,
        "review-rework-open-correction-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["branch", "-M", "main"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-204"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nCorrection fix.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Correction scoped fix"],
          cd: workspace,
          stderr_to_stdout: true
        )

      inbox = Path.join(workspace, ".orocsy/delivery/inbox")
      File.mkdir_p!(inbox)

      File.write!(
        Path.join(inbox, "correction_20260703000000_1.json"),
        Jason.encode!(%{
          "correction_id" => "correction_20260703000000_1",
          "status" => "open",
          "next_action" => "retry",
          "resolved_at" => nil,
          "created_at" => "2026-07-03T00:00:00Z",
          "summary" => "Fix the cards preference leakage.",
          "findings" => ["requestCards must not send guest preferences."],
          "required_corrections" => ["Remove guest preferences from requestCards."]
        })
      )

      File.write!(
        Path.join(inbox, "correction_20260704000000_2.json"),
        Jason.encode!(%{
          "correction_id" => "correction_20260704000000_2",
          "status" => "open",
          "next_action" => "retry",
          "resolved_at" => nil,
          "created_at" => "2026-07-04T00:00:00Z",
          "summary" => "Fix the newest chat state contract.",
          "findings" => ["DESIGN.md must include rejected feedback state."],
          "required_corrections" => ["Update DESIGN.md chat contract."]
        })
      )

      brief_dir = Path.join(workspace, ".codex/agentic/issue-briefs")
      File.mkdir_p!(brief_dir)

      File.write!(
        Path.join(brief_dir, "MT-204.md"),
        "# MT-204 Brief\n\nRemove the no-op cards preference header.\n"
      )

      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "review_rework",
          "branch" => "orocsy/mt-204",
          "checkpoint_event" => "correction-scoped-fix",
          "first_task" => "Resolve the open Orocsy correction before the review shortcut.",
          "issue" => "MT-204",
          "requirements" => %{
            "issue_brief" => %{
              "path" => ".codex/agentic/issue-briefs/MT-204.md",
              "bytes" => 60
            }
          },
          "review" => %{
            "pr_number" => 5,
            "pr_url" => "https://github.com/acme/nutribuddy/pull/5",
            "head_sha" => "abcdef123456",
            "feedback" => [
              %{
                "path" => "src/features/swipe/SwipeExperience.tsx",
                "line" => 32,
                "body" => "Remove the no-op cards preference header.",
                "url" => "https://github.com/acme/nutribuddy/pull/5#discussion"
              }
            ]
          }
        })
      )

      issue = %Issue{
        identifier: "MT-204",
        title: "Resolve open correction",
        description: "Correction flow",
        state: "Rework",
        url: "https://example.org/issues/MT-204",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, attempt: 2, workspace: workspace)

      assert String.starts_with?(prompt, "Open correction mode (runtime enforced):")
      assert prompt =~ "correction-scoped-fix"
      assert prompt =~ "`git status --short --branch` (runtime-provided)"
      refute prompt =~ "Local commits ahead of `main` (runtime-provided; do not run `git log`)"
      refute prompt =~ "Correction scoped fix"
      assert prompt =~ "Runtime command policy (enforced by the Symphony command guard):"

      assert prompt =~
               "`git log -N --oneline [--decorate|--no-decorate]` with `N` from 1 through 20"

      assert prompt =~ "all other denied git history/diff commands"

      assert prompt =~
               "Issue brief (`.codex/agentic/issue-briefs/MT-204.md`), inlined by the runtime"

      assert prompt =~ "Remove the no-op cards preference header."
      assert prompt =~ "Open correction execution contract:"
      assert prompt =~ "Runtime correction dispatch preflight:"
      assert prompt =~ "Fix the newest chat state contract."
      assert prompt =~ "DESIGN.md must include rejected feedback state."
      assert prompt =~ "Update DESIGN.md chat contract."
      assert prompt =~ "Fix the cards preference leakage."
      assert prompt =~ "Remove guest preferences from requestCards."
      assert prompt =~ "requestCards must not send guest preferences."

      assert :binary.match(prompt, "Fix the newest chat state contract.") <
               :binary.match(prompt, "Fix the cards preference leakage.")

      assert prompt =~ "Do not read test files first"
      refute prompt =~ "Runtime dispatch preflight:"
      refute prompt =~ "Current-head review feedback:"
      refute prompt =~ "Target feedback file(s):"
      refute prompt =~ "Review rework limits:"
      refute prompt =~ "Local handoff recovery checkpoint:"

      refute prompt =~
               "If a dirty/local handoff checkpoint appears above, follow that checkpoint first"

      refute prompt =~ "inspect the focused local diff and local commits"
    after
      File.rm_rf(workspace)
    end
  end

  test "controller review validation correction keeps validation in the runtime" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-controller-review-validation-prompt-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(workspace))

    try do
      inbox = Path.join(workspace, ".orocsy/delivery/inbox")
      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(inbox)
      File.mkdir_p!(state_dir)

      correction = %{
        "correction_id" => "correction_controller_review_validation",
        "source" => "symphony.runtime.validation-controller",
        "status" => "open",
        "next_action" => "retry",
        "created_at" => "2026-07-16T12:00:00Z",
        "resolved_at" => nil,
        "summary" => "Review-rework authoritative validation failed",
        "findings" => ["Declared write scope: src/example.ts"],
        "required_corrections" => ["Fix src/example.ts and request controller handoff."],
        "guard" => %{"miu_id" => "__review_rework__"}
      }

      File.write!(
        Path.join(inbox, "correction_controller_review_validation.json"),
        Jason.encode!(correction)
      )

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-205",
          "open_corrections" => [correction]
        })
      )

      issue = %Issue{
        identifier: "MT-205",
        title: "Retry controller review validation",
        description: "Structured review correction",
        state: "Rework",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, attempt: 2, workspace: workspace)

      assert prompt =~ "Controller-owned review validation correction contract:"
      assert prompt =~ "Do not rerun controller-owned validation inside the Codex worker"
      assert prompt =~ "append the exact `handoff.requested` event"
      refute prompt =~ "run focused validation, record the evidence, resolve the correction"
    after
      File.rm_rf(workspace)
    end
  end

  test "review rework command policy covers design document correction paths" do
    workflow_prompt = "Ticket {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-design-path-guard-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      File.mkdir_p!(Path.join(workspace, "design"))
      File.write!(Path.join(workspace, "DESIGN.md"), "# Design\n")
      File.write!(Path.join(workspace, "design/Mobile Top Area.html"), "<main></main>\n")
      File.write!(Path.join(workspace, "design/state.svg"), "<svg></svg>\n")
      File.write!(Path.join(workspace, "design/export.png"), "png-bytes\n")

      inbox = Path.join(workspace, ".orocsy/delivery/inbox")
      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(inbox)
      File.mkdir_p!(state_dir)

      File.write!(
        Path.join(inbox, "correction_20260703000000_design.json"),
        Jason.encode!(%{
          "correction_id" => "correction_20260703000000_design",
          "status" => "open",
          "next_action" => "retry",
          "resolved_at" => nil,
          "summary" => "Update DESIGN.md and design/Mobile Top Area.html.",
          "required_corrections" => [
            "Check `DESIGN.md`, `design/Mobile Top Area.html`, `design/state.svg`, and `design/export.png`."
          ]
        })
      )

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{"mode" => "review_rework", "issue" => "MT-DESIGN"})
      )

      patterns = AppServer.effective_forbidden_command_patterns_for(workspace)
      rendered = Enum.join(patterns, "\n")

      assert rendered =~ "git\\s+log"
      assert rendered =~ "git\\s+diff\\s+--stat"
      assert rendered =~ "git_diff_base_branch_without_path_scope"
      assert rendered =~ "command_chain_operator_outside_quotes"
      assert rendered =~ "DESIGN\\.md"
      assert rendered =~ "design/Mobile\\ Top\\ Area\\.html"
      assert rendered =~ "design/state\\.svg"
      assert rendered =~ "design/export\\.png"
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder prepends runtime policy violation interrupt when recovering a denied command" do
    workflow_prompt = "Ticket {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-206",
      title: "Policy violation recovery",
      description: "Recovery flow",
      state: "Rework",
      url: "https://example.org/issues/MT-206",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(issue,
        policy_violation: %{
          command: "/bin/zsh -lc 'git log --oneline origin/main..HEAD'",
          pattern: "(^|\\s|[\"'])git\\s+log(\\s|$)",
          attempt: 1,
          max_attempts: 2,
          scope_access: %{
            "operation" => "read",
            "paths" => ["src/features/landing/GuestStartScreen.tsx"],
            "decision" => "block",
            "reason_class" => "read_context_controller_not_enabled"
          }
        }
      )

    assert String.starts_with?(
             prompt,
             "Runtime command policy interrupt (recovery attempt 1 of 2):"
           )

    assert prompt =~ "Denied command: `/bin/zsh -lc 'git log --oneline origin/main..HEAD'`"

    assert prompt =~
             "Requested scope access: read src/features/landing/GuestStartScreen.tsx; decision block (read_context_controller_not_enabled)"

    assert prompt =~ "Do not run that command again"
    assert prompt =~ "Ticket MT-206"
  end

  test "policy violation recovery finalizes a dirty validated handoff without rereading" do
    workflow_prompt = "Ticket {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-207",
      title: "Finalize validated handoff",
      description: "Recovery flow",
      state: "Rework",
      url: "https://example.org/issues/MT-207",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(issue,
        policy_violation: %{
          command: "sed -n '48,102p' src/components/ui/bottom-sheet.tsx",
          pattern: "dirty_validated_handoff_recheck_before_commit",
          attempt: 1,
          max_attempts: 2
        }
      )

    assert prompt =~ "The dirty diff already has current validation evidence"
    assert prompt =~ "do not read source/test files or rerun validation"
    assert prompt =~ "then stage the runtime-listed dirty files, commit, push"

    refute prompt =~
             "Continue directly with the smallest in-scope fix for the open correction or current task"
  end

  test "allow-once recovery tells workers to split a denied compound read" do
    issue = %Issue{
      identifier: "MT-208",
      title: "Split bounded read recovery",
      description: "Recovery flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-208",
      labels: []
    }

    denied_command =
      "grep -nE 'test|describe' tests/e2e/ui-state-matrix.spec.ts && " <>
        "sed -n '1,160p' tests/e2e/ui-state-matrix.spec.ts"

    prompt =
      PromptBuilder.build_prompt(issue,
        policy_violation: %{
          command: denied_command,
          pattern: "(^|\\s|[\"'])grep(\\s|$)",
          attempt: 1,
          max_attempts: 2,
          scope_access: %{
            "operation" => "search",
            "paths" => ["tests/e2e/ui-state-matrix.spec.ts"],
            "decision" => "allow_once",
            "reason_class" => "safe_read_context"
          }
        }
      )

    assert prompt =~ "Do not repeat the denied command verbatim"
    assert prompt =~ "run each operation as a separate single-purpose command"
    assert prompt =~ "do not use `&&`, `||`, `;`, or pipes"
    refute prompt =~ "rerun that exact bounded read/search once"
  end

  test "agent runner allows one denied command recovery for strict implementation review rework" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-strict-review-rework-recovery-budget-#{System.unique_integer([:positive])}"
      )

    try do
      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "review_rework",
          "requirements" => %{
            "ticket_type" => "Implementation",
            "write_scope" => ["src/features/swipe/SwipeExperience.tsx"]
          }
        })
      )

      assert AgentRunner.policy_violation_recovery_budget_for_test(workspace) == 1

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "review_rework",
          "requirements" => %{"ticket_type" => "test_spec"}
        })
      )

      assert AgentRunner.policy_violation_recovery_budget_for_test(workspace) == 2
    after
      File.rm_rf(workspace)
    end
  end

  test "agent runner does not retry worker commands reserved for the runtime controller" do
    issue = %Issue{
      id: "issue-controller-handoff",
      identifier: "MT-CONTROLLER-HANDOFF",
      title: "Controller handoff",
      state: "Rework",
      labels: []
    }

    assert {:parked, nil} =
             AgentRunner.policy_violation_recovery_action_for_test(
               System.tmp_dir!(),
               issue,
               "pnpm exec playwright test tests/e2e/desktop-guest-setup.spec.ts --workers=1",
               "playwright_browser_correction_requires_runtime_controller_handoff",
               0,
               2
             )

    assert {:parked, nil} =
             AgentRunner.policy_violation_recovery_action_for_test(
               System.tmp_dir!(),
               issue,
               "pnpm exec playwright test tests/e2e/desktop-guest-setup.spec.ts --workers=1",
               "playwright_browser_correction_requires_runtime_controller_handoff",
               2,
               2,
               "worker-a"
             )
  end

  test "safe direct import read writes read-context policy patch and retries once" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-scope-access-auto-unblock-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "MT-SCOPE-ACCESS")
      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      events_dir = Path.join(workspace, ".orocsy/delivery/events")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        codex_forbidden_command_patterns: ["(^|\\s|[\"'])rg(\\s|$)"],
        max_turns: 1
      )

      File.mkdir_p!(Path.join(workspace, "src/features/swipe"))
      File.mkdir_p!(Path.join(workspace, "src/features/landing"))
      File.mkdir_p!(Path.join(workspace, "tests/unit"))
      File.mkdir_p!(state_dir)
      File.mkdir_p!(events_dir)

      File.write!(Path.join(workspace, "src/features/swipe/SwipeExperience.tsx"), """
      import { GuestPreferenceDraft } from "../landing/GuestStartScreen";

      export function useSwipeDraft(draft: GuestPreferenceDraft) {
        return draft;
      }
      """)

      File.write!(
        Path.join(workspace, "src/features/landing/GuestStartScreen.tsx"),
        "export type GuestPreferenceDraft = { adults: number };\n"
      )

      File.write!(Path.join(workspace, "tests/unit/swipe-experience.test.ts"), "test(\"draft\", () => {});\n")

      scope_bundle =
        SymphonyElixir.IssueRequirements.refresh_scope_bundle_hash(%{
          "issue" => "MT-SCOPE-ACCESS",
          "write_scope" => [
            %{
              "path" => "src/features/swipe/SwipeExperience.tsx",
              "source" => "test.write_scope",
              "operation" => "write",
              "expires" => "branch"
            }
          ],
          "read_context" => [],
          "conflict_scope" => [],
          "denied_scope" => []
        })

      base_preflight = %{
        "mode" => "review_rework",
        "issue" => "MT-SCOPE-ACCESS",
        "branch" => "orocsy/mt-scope-access",
        "requirements" => %{
          "ticket_type" => "Implementation",
          "write_scope" => ["src/features/swipe/SwipeExperience.tsx"],
          "validation" => %{
            "commands" => ["pnpm exec vitest run tests/unit/swipe-experience.test.ts"],
            "files" => []
          },
          "scope_bundle" => scope_bundle
        }
      }

      File.write!(Path.join(state_dir, "dispatch-preflight.json"), Jason.encode!(base_preflight))

      issue = %Issue{
        id: "issue-scope-access",
        identifier: "MT-SCOPE-ACCESS",
        title: "Scope access auto unblock",
        description: """
        ## Ticket Type

        Implementation

        ## Write Scope

        - `src/features/swipe/SwipeExperience.tsx`

        ## Validation

        ```bash
        pnpm exec vitest run tests/unit/swipe-experience.test.ts
        ```
        """,
        state: "Rework",
        branch_name: "orocsy/mt-scope-access",
        url: "https://example.org/issues/MT-SCOPE-ACCESS",
        labels: []
      }

      command = ~s(rg -n "GuestPreferenceDraft" src/features/landing/GuestStartScreen.tsx)
      pattern = "(^|\\s|[\"'])rg(\\s|$)"

      assert {:error, ^command, ^pattern} =
               AppServer.command_policy_violation_for_test(workspace, command)

      assert {:retry, 1, scope_access} =
               AgentRunner.policy_violation_recovery_action_for_test(
                 workspace,
                 issue,
                 command,
                 pattern,
                 0,
                 1
               )

      assert scope_access["decision"] == "allow_once"
      assert scope_access["reason_class"] == "safe_read_context"

      patch_files = Path.wildcard(Path.join(workspace, ".orocsy/delivery/policy-patches/*.json"))
      assert length(patch_files) == 1

      patch = patch_files |> hd() |> File.read!() |> Jason.decode!()
      assert patch["decision"] == "allow_once"
      assert get_in(patch, ["entries", Access.at(0), "path"]) == "src/features/landing/GuestStartScreen.tsx"
      assert get_in(patch, ["entries", Access.at(0), "source"]) == "scope_access.auto.direct_import"

      tampered_patch =
        put_in(
          patch,
          ["entries"],
          [
            %{
              "path" => "src/server/private-secrets.ts",
              "source" => "scope_access.auto.direct_import",
              "operation" => "read",
              "expires" => "turn"
            }
          ]
        )

      File.write!(
        Path.join(workspace, ".orocsy/delivery/policy-patches/tampered.json"),
        Jason.encode!(tampered_patch)
      )

      assert {:ok, preflight} = SymphonyElixir.DispatchPreflight.read(workspace)
      active_patch = patch_files |> hd() |> File.read!() |> Jason.decode!()
      assert active_patch["status"] == "active"

      duplicate_request = SymphonyElixir.ScopeAccess.classify_command(command, preflight)

      assert {:allow_once, duplicate_patch} =
               SymphonyElixir.ScopeAccess.Controller.decide(
                 duplicate_request,
                 preflight,
                 workspace
               )

      assert duplicate_patch["patch_id"] == active_patch["patch_id"]
      assert duplicate_patch["status"] == "active"

      assert Enum.any?(get_in(preflight, ["requirements", "scope_bundle", "read_context"]), fn entry ->
               entry["path"] == "src/features/landing/GuestStartScreen.tsx" and
                 entry["source"] == "scope_access.auto.direct_import"
             end)

      refute Enum.any?(get_in(preflight, ["requirements", "scope_bundle", "read_context"]), fn entry ->
               entry["path"] == "src/server/private-secrets.ts"
             end)

      File.write!(Path.join(state_dir, "dispatch-preflight.json"), Jason.encode!(preflight))

      assert :ok =
               AppServer.command_policy_violation_for_test(
                 workspace,
                 ~s(rg -n "GuestPreferenceDraft" src/features/landing/GuestStartScreen.tsx)
               )

      assert :ok = SymphonyElixir.DispatchPreflight.consume_turn_policy_patches(workspace)
      consumed_patch = patch_files |> hd() |> File.read!() |> Jason.decode!()
      assert consumed_patch["status"] == "consumed"
      assert SymphonyElixir.ControllerEvidence.valid?(consumed_patch)

      assert {:ok, expired_preflight} = SymphonyElixir.DispatchPreflight.read(workspace)

      refute Enum.any?(get_in(expired_preflight, ["requirements", "scope_bundle", "read_context"]), fn entry ->
               entry["path"] == "src/features/landing/GuestStartScreen.tsx" and
                 entry["source"] == "scope_access.auto.direct_import"
             end)

      assert {:error, ^command, ^pattern} =
               AppServer.command_policy_violation_for_test(workspace, command)

      assert {:retry, 1, renewed_scope_access} =
               AgentRunner.policy_violation_recovery_action_for_test(
                 workspace,
                 issue,
                 command,
                 pattern,
                 0,
                 1
               )

      assert renewed_scope_access["decision"] == "allow_once"
      assert renewed_scope_access["reason_class"] == "safe_read_context"

      renewed_patch = patch_files |> hd() |> File.read!() |> Jason.decode!()
      assert renewed_patch["status"] == "active"
    after
      File.rm_rf(test_root)
    end
  end

  test "safe nearest caller read is allowed read-only and never promoted to write scope" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-scope-access-nearest-caller-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "MT-SCOPE-CALLER")
      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      events_dir = Path.join(workspace, ".orocsy/delivery/events")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        codex_forbidden_command_patterns: ["(^|\\s|[\"'])sed\\s+-n(\\s|$)"],
        max_turns: 1
      )

      File.mkdir_p!(Path.join(workspace, "src/features/swipe"))
      File.mkdir_p!(Path.join(workspace, "src/features/landing"))
      File.mkdir_p!(state_dir)
      File.mkdir_p!(events_dir)

      File.write!(
        Path.join(workspace, "src/features/swipe/SwipeExperience.tsx"),
        "export function SwipeExperience() { return null; }\n"
      )

      File.write!(Path.join(workspace, "src/features/landing/GuestStartScreen.tsx"), """
      import { SwipeExperience } from "../swipe/SwipeExperience";

      export function GuestStartScreen() {
        return <SwipeExperience />;
      }
      """)

      scope_bundle =
        SymphonyElixir.IssueRequirements.refresh_scope_bundle_hash(%{
          "issue" => "MT-SCOPE-CALLER",
          "write_scope" => [
            %{
              "path" => "src/features/swipe/SwipeExperience.tsx",
              "source" => "test.write_scope",
              "operation" => "write",
              "expires" => "branch"
            }
          ],
          "read_context" => [],
          "conflict_scope" => [],
          "denied_scope" => []
        })

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-SCOPE-CALLER",
          "branch" => "orocsy/mt-scope-caller",
          "requirements" => %{
            "ticket_type" => "Implementation",
            "write_scope" => ["src/features/swipe/SwipeExperience.tsx"],
            "scope_bundle" => scope_bundle
          }
        })
      )

      issue = %Issue{
        id: "issue-scope-caller",
        identifier: "MT-SCOPE-CALLER",
        title: "Scope caller read",
        description: "Allow the nearest caller as read-only context",
        state: "Rework",
        branch_name: "orocsy/mt-scope-caller",
        labels: []
      }

      command = "sed -n 1,80p src/features/landing/GuestStartScreen.tsx"

      assert {:error, ^command, pattern} =
               AppServer.command_policy_violation_for_test(workspace, command)

      assert {:retry, 1, scope_access} =
               AgentRunner.policy_violation_recovery_action_for_test(
                 workspace,
                 issue,
                 command,
                 pattern,
                 0,
                 1
               )

      assert scope_access["decision"] == "allow_once"
      assert scope_access["reason_class"] == "safe_read_context"

      assert {:ok, preflight} = SymphonyElixir.DispatchPreflight.read(workspace)

      read_context = get_in(preflight, ["requirements", "scope_bundle", "read_context"])
      write_scope = get_in(preflight, ["requirements", "scope_bundle", "write_scope"])

      assert Enum.any?(read_context, fn entry ->
               entry["path"] == "src/features/landing/GuestStartScreen.tsx" and
                 entry["source"] == "scope_access.auto.nearest_caller" and
                 entry["operation"] == "read"
             end)

      refute Enum.any?(write_scope, fn entry ->
               entry["path"] == "src/features/landing/GuestStartScreen.tsx"
             end)

      assert :ok = AppServer.command_policy_violation_for_test(workspace, command)
    after
      File.rm_rf(test_root)
    end
  end

  test "handoff recovery accepts split reads for exact contract context but rejects the compound form" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-handoff-recovery-split-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "MT-HANDOFF-SPLIT-READ")
      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      test_path = "tests/e2e/ui-state-matrix.spec.ts"

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        codex_forbidden_command_patterns: [
          "(^|\\s|[\"'])grep(\\s|$)",
          "(^|\\s|[\"'])sed\\s+-n(\\s|$)"
        ]
      )

      File.mkdir_p!(Path.join(workspace, "tests/e2e"))
      File.mkdir_p!(Path.join(workspace, "tests/e2e/declared-dir"))
      File.mkdir_p!(Path.join(workspace, "config"))
      File.mkdir_p!(Path.join(workspace, "priv"))
      File.mkdir_p!(Path.join(workspace, ".github/workflows"))
      File.mkdir_p!(state_dir)

      File.write!(
        Path.join(workspace, test_path),
        "import './derived-helper';\ntest('discover', () => {});\n"
      )

      File.write!(Path.join(workspace, "tests/e2e/derived-helper.ts"), "export {};\n")
      File.write!(Path.join(workspace, "tests/e2e/knowledge-helper.ts"), "export {};\n")
      File.write!(Path.join(workspace, "tests/e2e/declared-dir/child.ts"), "export {};\n")
      File.write!(Path.join(workspace, "config/config.exs"), "import Config\n")
      File.write!(Path.join(workspace, "priv/data.json"), "{}\n")
      File.write!(Path.join(workspace, ".github/workflows/ci.yml"), "name: ci\n")
      File.write!(Path.join(workspace, "123"), "undeclared\n")
      File.ln_s!("/etc/passwd", Path.join(workspace, "tests/e2e/declared-symlink.spec.ts"))

      scope_bundle =
        SymphonyElixir.IssueRequirements.refresh_scope_bundle_hash(%{
          "issue" => "MT-HANDOFF-SPLIT-READ",
          "write_scope" => [
            %{
              "path" => "tests/e2e/desktop-discover.spec.ts",
              "source" => "runtime_contract.miu:MT-HANDOFF-SPLIT-READ",
              "operation" => "write",
              "expires" => "branch"
            }
          ],
          "read_context" => [
            %{
              "path" => test_path,
              "source" => "runtime_contract.miu:MT-HANDOFF-SPLIT-READ",
              "operation" => "read",
              "expires" => "turn"
            },
            %{
              "path" => "tests/e2e/declared-symlink.spec.ts",
              "source" => "runtime_contract.miu:MT-HANDOFF-SPLIT-READ",
              "operation" => "read",
              "expires" => "turn"
            },
            %{
              "path" => "tests/e2e/*.spec.ts",
              "source" => "runtime_contract.miu:MT-HANDOFF-SPLIT-READ",
              "operation" => "read",
              "expires" => "turn"
            },
            %{
              "path" => "tests/e2e/knowledge-helper.ts",
              "source" => "knowledge_ledger.shared_context",
              "operation" => "read",
              "expires" => "turn"
            },
            %{
              "path" => "tests/e2e/declared-dir",
              "source" => "runtime_contract.miu:MT-HANDOFF-SPLIT-READ",
              "operation" => "read",
              "expires" => "turn"
            },
            %{
              "path" => "config/config.exs",
              "source" => "runtime_contract.miu:MT-HANDOFF-SPLIT-READ",
              "operation" => "read",
              "expires" => "turn"
            },
            %{
              "path" => "priv/data.json",
              "source" => "runtime_contract.miu:MT-HANDOFF-SPLIT-READ",
              "operation" => "read",
              "expires" => "turn"
            },
            %{
              "path" => ".github/workflows/ci.yml",
              "source" => "runtime_contract.miu:MT-HANDOFF-SPLIT-READ",
              "operation" => "read",
              "expires" => "turn"
            }
          ],
          "conflict_scope" => [],
          "denied_scope" => []
        })

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "handoff_recovery",
          "issue" => "MT-HANDOFF-SPLIT-READ",
          "branch" => "orocsy/mt-handoff-split-read",
          "requirements" => %{
            "ticket_type" => "test-spec",
            "runtime_contract_status" => "structured",
            "write_scope" => ["tests/e2e/desktop-discover.spec.ts"],
            "scope_bundle" => scope_bundle
          }
        })
      )

      issue = %Issue{
        id: "issue-handoff-split-read",
        identifier: "MT-HANDOFF-SPLIT-READ",
        title: "Recover a bounded compound read",
        description: "Split an exact read chain after the command guard denies its compound form.",
        state: "Rework",
        branch_name: "orocsy/mt-handoff-split-read",
        labels: []
      }

      grep_command = ~s(grep -nE 'test|describe' #{test_path})
      sed_command = ~s(sed -n '1,160p' #{test_path})
      compound_command = grep_command <> " && " <> sed_command
      wrapped_grep_command = ~s(/bin/zsh -lc "#{grep_command}")
      wrapped_sed_command = ~s(/bin/zsh -lc "#{sed_command}")
      wrapped_compound_command = ~s(/bin/zsh -lc "#{compound_command}")
      bash_wrapped_compound = ~s(/bin/bash -lc "#{compound_command}")
      sh_wrapped_compound = ~s(sh -lc "#{compound_command}")
      quoted_bash_grep = ~s(/bin/bash -lc "grep -n \\"test|describe\\" #{test_path}")

      forbidden_patterns = [
        "(^|\\s|[\"'])grep(\\s|$)",
        "(^|\\s|[\"'])sed\\s+-n(\\s|$)"
      ]

      assert :ok = AppServer.command_policy_violation_for_test(workspace, grep_command, [])
      assert :ok = AppServer.command_policy_violation_for_test(workspace, sed_command, [])
      assert :ok = AppServer.command_policy_violation_for_test(workspace, wrapped_grep_command, [])
      assert :ok = AppServer.command_policy_violation_for_test(workspace, wrapped_sed_command, [])
      assert :ok = AppServer.command_policy_violation_for_test(workspace, quoted_bash_grep, [])

      assert {:error, ^compound_command, compound_pattern} =
               AppServer.command_policy_violation_for_test(workspace, compound_command, [])

      assert {:ok, preflight} = SymphonyElixir.DispatchPreflight.read(workspace)
      compound_request = SymphonyElixir.ScopeAccess.classify_command(compound_command, preflight)

      assert compound_request["operation"] == "read"
      assert compound_request["command_class"] == "bounded_read_chain"
      assert compound_request["paths"] == [test_path]
      refute compound_request["broad"]

      wrapped_request =
        SymphonyElixir.ScopeAccess.classify_command(wrapped_compound_command, preflight)

      assert wrapped_request["command_class"] == "bounded_read_chain"
      assert wrapped_request["paths"] == [test_path]
      refute wrapped_request["broad"]

      assert {:retry, 1, compound_scope_access} =
               AgentRunner.policy_violation_recovery_action_for_test(
                 workspace,
                 issue,
                 compound_command,
                 compound_pattern,
                 0,
                 1
               )

      assert compound_scope_access["decision"] == "allow_once"
      assert compound_scope_access["reason_class"] == "safe_read_context"

      cross_root_chain =
        "cat config/config.exs && sed -n '1,20p' priv/data.json && cat .github/workflows/ci.yml"

      cross_root_request = SymphonyElixir.ScopeAccess.classify_command(cross_root_chain, preflight)

      assert cross_root_request["command_class"] == "bounded_read_chain"

      assert cross_root_request["paths"] == [
               "config/config.exs",
               "priv/data.json",
               ".github/workflows/ci.yml"
             ]

      refute cross_root_request["broad"]

      suffixed_count_chain =
        "head -q -c 1K config/config.exs && tail -v --bytes=1MiB config/config.exs"

      suffixed_count_request =
        SymphonyElixir.ScopeAccess.classify_command(suffixed_count_chain, preflight)

      assert suffixed_count_request["command_class"] == "bounded_read_chain"
      assert suffixed_count_request["paths"] == ["config/config.exs"]
      refute suffixed_count_request["broad"]

      stdin_read_chain = "head - config/config.exs && cat config/config.exs"
      stdin_read_request = SymphonyElixir.ScopeAccess.classify_command(stdin_read_chain, preflight)

      assert stdin_read_request["command_class"] == "shell_chain"
      assert stdin_read_request["broad"]

      abbreviated_follow_chain =
        "tail --fol config/config.exs && cat config/config.exs"

      abbreviated_follow_request =
        SymphonyElixir.ScopeAccess.classify_command(abbreviated_follow_chain, preflight)

      assert abbreviated_follow_request["command_class"] == "shell_chain"
      assert abbreviated_follow_request["broad"]

      normalized_reader_chain =
        "/bin/cat config/config.exs && env head -n 5 config/config.exs"

      normalized_reader_request =
        SymphonyElixir.ScopeAccess.classify_command(normalized_reader_chain, preflight)

      assert normalized_reader_request["command_class"] == "bounded_read_chain"
      assert normalized_reader_request["paths"] == ["config/config.exs"]
      refute normalized_reader_request["broad"]

      sed_write_chain =
        "sed -n '1w /tmp/leak' config/config.exs && cat config/config.exs"

      sed_write_request = SymphonyElixir.ScopeAccess.classify_command(sed_write_chain, preflight)

      assert sed_write_request["operation"] == "unknown"
      assert sed_write_request["command_class"] == "shell_chain"
      assert sed_write_request["broad"]

      mixed_chain = grep_command <> " && rm -f #{test_path}"
      mixed_request = SymphonyElixir.ScopeAccess.classify_command(mixed_chain, preflight)

      assert mixed_request["operation"] == "unknown"
      assert mixed_request["command_class"] == "shell_chain"
      assert mixed_request["broad"]

      assert {:block, mixed_correction} =
               SymphonyElixir.ScopeAccess.Controller.decide(mixed_request, preflight, workspace)

      assert get_in(mixed_correction, [:guard, "reason_class"]) == "unclassified_scope_request"

      assert {:error, ^wrapped_compound_command, _pattern} =
               AppServer.command_policy_violation_for_test(workspace, wrapped_compound_command, [])

      assert {:error, ^bash_wrapped_compound, _pattern} =
               AppServer.command_policy_violation_for_test(workspace, bash_wrapped_compound, [])

      assert {:error, ^sh_wrapped_compound, _pattern} =
               AppServer.command_policy_violation_for_test(workspace, sh_wrapped_compound, [])

      unscoped_test_search = "grep -n test tests/e2e/unrelated.spec.ts"
      unclassified_operand_search = grep_command <> " /etc/passwd"
      derived_context_search = "grep -n test tests/e2e/derived-helper.ts"
      unsafe_option_search = "grep -n -f /etc/passwd #{test_path}"
      option_pattern_unclassified_search = "grep -n -eSECRET /etc/passwd #{test_path}"
      option_pattern_scoped_search = "grep -n -eSECRET #{test_path}"
      symlink_search = "grep -n test tests/e2e/declared-symlink.spec.ts"
      glob_search = "grep -n test tests/e2e/*.spec.ts"
      disguised_mutation = "rm -f grep cat #{test_path} /tmp/sentinel"
      knowledge_context_search = "grep -n test tests/e2e/knowledge-helper.ts"

      assert {:error, ^unscoped_test_search, _pattern} =
               AppServer.command_policy_violation_for_test(workspace, unscoped_test_search, [])

      assert {:error, ^unclassified_operand_search, _pattern} =
               AppServer.command_policy_violation_for_test(workspace, unclassified_operand_search, [])

      assert {:error, ^derived_context_search, _pattern} =
               AppServer.command_policy_violation_for_test(workspace, derived_context_search, [])

      assert {:error, ^unsafe_option_search, _pattern} =
               AppServer.command_policy_violation_for_test(workspace, unsafe_option_search, [])

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, option_pattern_scoped_search, [])

      assert {:error, ^option_pattern_unclassified_search, _pattern} =
               AppServer.command_policy_violation_for_test(
                 workspace,
                 option_pattern_unclassified_search,
                 []
               )

      assert {:error, ^symlink_search, _pattern} =
               AppServer.command_policy_violation_for_test(workspace, symlink_search, [])

      assert {:error, ^glob_search, _pattern} =
               AppServer.command_policy_violation_for_test(workspace, glob_search, [])

      assert {:error, ^disguised_mutation, _pattern} =
               AppServer.command_policy_violation_for_test(workspace, disguised_mutation, [])

      assert {:error, ^knowledge_context_search, _pattern} =
               AppServer.command_policy_violation_for_test(workspace, knowledge_context_search, [])

      assert {:error, ^grep_command, _pattern} =
               AppServer.command_policy_violation_for_test(workspace, grep_command, forbidden_patterns)

      rg_encoding_command = "rg -n -E utf-8 test #{test_path}"
      rg_follow_command = "rg -nL test #{test_path}"
      rg_command = "rg -n test #{test_path}"
      configured_rg_pattern = "(^|\\s|[\"'])rg(\\s|$)"

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, rg_encoding_command, [])

      assert {:error, ^rg_follow_command, _pattern} =
               AppServer.command_policy_violation_for_test(workspace, rg_follow_command, [])

      assert {:error, ^rg_command, ^configured_rg_pattern} =
               AppServer.command_policy_violation_for_test(
                 workspace,
                 rg_command,
                 [configured_rg_pattern]
               )

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, "cat config/config.exs", [])

      undeclared_cat = "cat /etc/passwd"
      path_qualified_cat = "/bin/cat /etc/passwd"
      workspace_named_cat = "./cat config/config.exs"
      temporary_named_cat = "/tmp/cat config/config.exs"
      env_wrapped_cat = "env cat /etc/passwd"
      path_qualified_scoped_cat = "/bin/cat config/config.exs"
      env_wrapped_scoped_cat = "env cat config/config.exs"
      env_path_wrapped_rg = "env PATH=. rg -n test config/config.exs"
      env_chdir_wrapped_cat = "env -C /tmp cat /etc/passwd"
      env_split_wrapped_cat = "env -S 'cat /etc/passwd'"
      numeric_cat = "cat config/config.exs 123"
      numeric_nl = "nl config/config.exs 123"
      stdin_cat = "cat - config/config.exs"
      stdin_nl = "nl - config/config.exs"
      stdin_head = "head - config/config.exs"
      stdin_tail = "tail - config/config.exs"
      directory_rg = "rg -n test tests/e2e/declared-dir"
      mutating_chain = sed_command <> " && rm -f #{test_path}"
      ansi_c_chain = "/bin/bash -lc $'cat config/config.exs\\nrm -f config/config.exs'"
      ansi_c_non_login_chain = "/bin/bash -c $'cat config/config.exs\\nrm -f config/config.exs'"

      ansi_c_long_login_chain =
        "/bin/bash --login -c $'cat config/config.exs\\nrm -f config/config.exs'"

      ansi_c_clustered_login_chain =
        "/bin/bash -cl $'cat config/config.exs\\nrm -f config/config.exs'"

      quoted_shell_chain_with_argv =
        "/bin/bash -c 'cat config/config.exs; rm -f config/config.exs' worker-zero"

      env_wrapped_shell_read = "env bash -c 'cat /etc/passwd'"
      command_wrapped_shell_read = "command bash -c 'cat /etc/passwd'"
      generic_wrapped_shell_read = "nice -n 5 bash -c 'cat /etc/passwd'"
      delimited_wrapped_shell_read = "nice -- bash -c 'cat /etc/passwd'"
      composed_wrapped_shell_read = "env nice bash -c 'cat /etc/passwd'"
      alternate_shell_read = "/usr/bin/dash -c 'cat /etc/passwd'"
      single_quote_escape_chain = "cat 'config/config.exs\\' ; rm -f target"
      wrapped_git_status = "/bin/bash -lc 'git status --short --branch'"
      wrapped_git_add = "/bin/bash -lc 'git add diff'"
      wrapped_git_commit = "/bin/bash -lc 'git commit -m log'"
      wrapped_git_commit_reuse = "/bin/bash -lc 'git commit -c cat'"
      wrapped_git_commit_file = "/bin/bash -lc 'git commit -F /etc/passwd'"
      untrusted_wrapped_git_status = "/tmp/bash -lc 'git status --short --branch'"

      wrapped_git_status_with_shell_option =
        "/bin/bash -o pipefail -lc 'git status --short --branch'"

      shell_exec_cat = "/bin/bash -lc 'exec cat /etc/passwd'"
      shell_newline_cat = "/bin/bash -lc 'echo ok\ncat /etc/passwd'"
      zsh_process_substitution = "/bin/zsh -lc 'git status =(rm -rf target)'"
      shell_delimiter_script = "/bin/bash -- -c 'git status'"
      assigned_cat = "FOO=1 cat /etc/passwd"
      exec_named_cat = "exec -a harmless cat /etc/passwd"
      legacy_nice_cat = "nice -5 cat /etc/passwd"

      tail_follow = "tail -f config/config.exs"
      tail_retry_follow = "tail -F config/config.exs"
      tail_clustered_follow = "tail -fq config/config.exs"
      tail_clustered_retry_follow = "tail -Fq config/config.exs"
      tail_abbreviated_follow = "tail --fol config/config.exs"
      finite_tail = "tail -n 5 config/config.exs"
      finite_flagged_head = "head -q -n 5 config/config.exs"
      finite_flagged_tail = "tail -v --lines 5 config/config.exs"
      finite_suffixed_head = "head -c 1K config/config.exs"
      finite_suffixed_tail = "tail -v --bytes=1MiB config/config.exs"
      directory_ls = "ls tests/e2e"
      git_diff_read = "git diff -- config/config.exs"
      git_log_read = "git log -- config/config.exs"
      git_global_diff_read = "git --no-pager diff -- /etc/passwd"
      git_global_log_read = "git -P log -p -- /etc/passwd"

      git_global_scoped_diff =
        "git --no-pager diff --no-ext-diff --no-textconv -- config/config.exs"

      git_global_scoped_log =
        "git -P log --no-ext-diff --no-textconv -- config/config.exs"

      git_paginated_scoped_diff =
        "git -p diff --no-ext-diff --no-textconv -- config/config.exs"

      git_paginated_scoped_log =
        "git --paginate log --no-ext-diff --no-textconv -- config/config.exs"

      git_signed_scoped_log =
        "git log --show-signature --no-ext-diff --no-textconv -- config/config.exs"

      git_diff_order_file =
        "git diff -O /etc/passwd --no-ext-diff --no-textconv -- config/config.exs"

      git_no_index_read =
        "git diff --no-ext-diff --no-textconv --no-index /etc/passwd -- config/config.exs"

      git_ls_files_exclude_file = "git ls-files -X /etc/passwd -- config/config.exs"

      git_ls_files_per_directory =
        "git ls-files --exclude-per-directory=/etc/passwd -- config/config.exs"

      quoted_git_diff_order_file =
        "git diff '-O/etc/passwd' --no-ext-diff --no-textconv -- config/config.exs"

      quoted_git_ls_files_exclude_file =
        "git ls-files '-X/etc/passwd' -- config/config.exs"

      abbreviated_git_exclude_file =
        "git ls-files --exclude-f=/etc/passwd -- config/config.exs"

      git_no_replace_commit = "git --no-replace-objects commit -m log"
      git_attr_source_log = "git --attr-source HEAD log -- /etc/passwd"

      safe_abbreviated_git_diff =
        "git diff --no-in --no-ext-diff --no-textconv -- config/config.exs"

      sed_write = "sed -n '1w /tmp/leak' config/config.exs"

      assert {:error, ^undeclared_cat, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, undeclared_cat, [])

      assert {:error, ^path_qualified_cat, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, path_qualified_cat, [])

      assert {:error, ^workspace_named_cat, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, workspace_named_cat, [])

      assert {:error, ^temporary_named_cat, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, temporary_named_cat, [])

      assert {:error, ^env_wrapped_cat, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, env_wrapped_cat, [])

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, path_qualified_scoped_cat, [])

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, env_wrapped_scoped_cat, [])

      assert {:error, ^env_path_wrapped_rg, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, env_path_wrapped_rg, [])

      assert {:error, ^env_chdir_wrapped_cat, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, env_chdir_wrapped_cat, [])

      assert {:error, ^env_split_wrapped_cat, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, env_split_wrapped_cat, [])

      assert {:error, ^numeric_cat, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, numeric_cat, [])

      assert {:error, ^numeric_nl, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, numeric_nl, [])

      assert {:error, ^stdin_cat, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, stdin_cat, [])

      assert {:error, ^stdin_nl, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, stdin_nl, [])

      assert {:error, ^stdin_head, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, stdin_head, [])

      assert {:error, ^stdin_tail, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, stdin_tail, [])

      assert {:error, ^directory_rg, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, directory_rg, [])

      assert {:error, ^mutating_chain, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, mutating_chain, [])

      assert {:error, ^ansi_c_chain, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, ansi_c_chain, [])

      assert {:error, ^ansi_c_non_login_chain, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, ansi_c_non_login_chain, [])

      assert {:error, ^ansi_c_long_login_chain, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, ansi_c_long_login_chain, [])

      assert {:error, ^ansi_c_clustered_login_chain, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, ansi_c_clustered_login_chain, [])

      assert {:error, ^quoted_shell_chain_with_argv, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, quoted_shell_chain_with_argv, [])

      assert {:error, ^env_wrapped_shell_read, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, env_wrapped_shell_read, [])

      assert {:error, ^command_wrapped_shell_read, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, command_wrapped_shell_read, [])

      assert {:error, ^generic_wrapped_shell_read, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, generic_wrapped_shell_read, [])

      assert {:error, ^delimited_wrapped_shell_read, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, delimited_wrapped_shell_read, [])

      assert {:error, ^composed_wrapped_shell_read, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, composed_wrapped_shell_read, [])

      assert {:error, ^alternate_shell_read, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, alternate_shell_read, [])

      assert {:error, ^single_quote_escape_chain, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, single_quote_escape_chain, [])

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, wrapped_git_status, [])

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, wrapped_git_add, [])

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, wrapped_git_commit, [])

      assert {:error, ^wrapped_git_commit_reuse, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, wrapped_git_commit_reuse, [])

      assert {:error, ^wrapped_git_commit_file, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, wrapped_git_commit_file, [])

      assert {:error, ^untrusted_wrapped_git_status, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, untrusted_wrapped_git_status, [])

      assert :ok =
               AppServer.command_policy_violation_for_test(
                 workspace,
                 wrapped_git_status_with_shell_option,
                 []
               )

      assert {:error, ^shell_exec_cat, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, shell_exec_cat, [])

      assert {:error, ^shell_newline_cat, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, shell_newline_cat, [])

      assert {:error, ^zsh_process_substitution, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, zsh_process_substitution, [])

      assert {:error, ^shell_delimiter_script, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, shell_delimiter_script, [])

      assert {:error, ^assigned_cat, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, assigned_cat, [])

      assert {:error, ^exec_named_cat, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, exec_named_cat, [])

      assert {:error, ^legacy_nice_cat, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, legacy_nice_cat, [])

      assert {:error, ^tail_follow, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, tail_follow, [])

      assert {:error, ^tail_retry_follow, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, tail_retry_follow, [])

      assert {:error, ^tail_clustered_follow, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, tail_clustered_follow, [])

      assert {:error, ^tail_clustered_retry_follow, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, tail_clustered_retry_follow, [])

      assert {:error, ^tail_abbreviated_follow, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, tail_abbreviated_follow, [])

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, finite_tail, [])

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, finite_flagged_head, [])

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, finite_flagged_tail, [])

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, finite_suffixed_head, [])

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, finite_suffixed_tail, [])

      assert {:error, ^directory_ls, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, directory_ls, [])

      assert {:error, ^git_diff_read, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, git_diff_read, [])

      assert {:error, ^git_log_read, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, git_log_read, [])

      assert {:error, ^git_global_diff_read, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, git_global_diff_read, [])

      assert {:error, ^git_global_log_read, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, git_global_log_read, [])

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, git_global_scoped_diff, [])

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, git_global_scoped_log, [])

      assert {:error, ^git_paginated_scoped_diff, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, git_paginated_scoped_diff, [])

      assert {:error, ^git_paginated_scoped_log, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, git_paginated_scoped_log, [])

      assert {:error, ^git_signed_scoped_log, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, git_signed_scoped_log, [])

      assert {:error, ^git_diff_order_file, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, git_diff_order_file, [])

      assert {:error, ^git_no_index_read, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, git_no_index_read, [])

      assert {:error, ^git_ls_files_exclude_file, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, git_ls_files_exclude_file, [])

      assert {:error, ^git_ls_files_per_directory, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, git_ls_files_per_directory, [])

      assert {:error, ^quoted_git_diff_order_file, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, quoted_git_diff_order_file, [])

      assert {:error, ^quoted_git_ls_files_exclude_file, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(
                 workspace,
                 quoted_git_ls_files_exclude_file,
                 []
               )

      assert {:error, ^abbreviated_git_exclude_file, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(
                 workspace,
                 abbreviated_git_exclude_file,
                 []
               )

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, git_no_replace_commit, [])

      assert {:error, ^git_attr_source_log, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, git_attr_source_log, [])

      assert :ok =
               AppServer.command_policy_violation_for_test(workspace, safe_abbreviated_git_diff, [])

      assert {:error, ^sed_write, "handoff_recovery_exact_read_scope"} =
               AppServer.command_policy_violation_for_test(workspace, sed_write, [])

      preflight_path = Path.join(state_dir, "dispatch-preflight.json")
      review_preflight = preflight_path |> File.read!() |> Jason.decode!() |> Map.put("mode", "review_rework")
      File.write!(preflight_path, Jason.encode!(review_preflight))

      assert :ok =
               AppServer.command_policy_violation_for_test(
                 workspace,
                 rg_command,
                 [configured_rg_pattern]
               )

      piped_read = sed_command <> "|tee tests/e2e/unscoped-output.spec.ts"
      unspaced_chain = sed_command <> ";rm -rf target"

      assert {:error, ^piped_read, _pattern} =
               AppServer.command_policy_violation_for_test(workspace, piped_read, forbidden_patterns)

      assert {:error, ^unspaced_chain, _pattern} =
               AppServer.command_policy_violation_for_test(workspace, unspaced_chain, forbidden_patterns)
    after
      File.rm_rf(test_root)
    end
  end

  test "scope blocker report includes requested path operation policy hash and next action" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-scope-unblock-report-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root)

      issue = %Issue{
        id: "issue-scope-unblock-report",
        identifier: "MT-SCOPE-REPORT",
        title: "Scope unblock report",
        state: "In Progress",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      path = "src/features/landing/GuestStartScreen.tsx"
      policy_hash = "sha256:policy-scope-report"
      head_sha = "f00dbabe"

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(
                 workspace,
                 issue,
                 scope_unblock_correction_attrs(issue,
                   path: path,
                   operation: "read",
                   head_sha: head_sha,
                   policy_hash: policy_hash,
                   next_action: "retry"
                 )
               )

      assert report = correction["unblock_report"]
      assert report["blocker_class"] == "scope_policy_stale"
      assert report["requested_operation"] == "read"
      assert report["requested_paths"] == [path]
      assert report["policy_hash"] == policy_hash
      assert report["head_sha"] == head_sha

      assert report["next_action"] ==
               "add read_context or update Linear write scope, then redispatch"

      markdown = File.read!(Path.join(workspace, correction["artifacts"]["markdown"]))
      assert markdown =~ "## Unblock Report"
      assert markdown =~ "Worker asked for: read #{path}"
      assert markdown =~ "Policy hash: #{policy_hash}"
      assert markdown =~ "Next action: add read_context or update Linear write scope, then redispatch"

      current_state =
        workspace
        |> Path.join(".orocsy/delivery/state/current.json")
        |> File.read!()
        |> Jason.decode!()

      assert get_in(current_state, ["unblock_report", "worker_asked_for"]) == "read #{path}"
    after
      File.rm_rf(test_root)
    end
  end

  test "dashboard distinguishes safe read request from write scope expansion" do
    path = "src/features/landing/GuestStartScreen.tsx"

    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         blocked: [
           %{
             "issue" => "MT-READ",
             "blocker_class" => "safe_read_context_required",
             "worker_asked_for" => "read #{path}",
             "next_action" => "add read_context or update Linear write scope, then redispatch",
             "policy_hash" => "sha256:read-policy",
             "created_at" => "2026-07-09T00:00:00Z"
           },
           %{
             "issue" => "MT-WRITE",
             "blocker_class" => "write_scope_expansion_required",
             "worker_asked_for" => "write #{path}",
             "next_action" => "update Linear write scope or narrow the worker command, then redispatch",
             "policy_hash" => "sha256:write-policy",
             "created_at" => "2026-07-09T00:00:01Z"
           }
         ],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered =~ "Blocked"
    assert rendered =~ "MT-READ"
    assert rendered =~ "safe_read_context_required"
    assert rendered =~ "asked=read #{path}"
    assert rendered =~ "MT-WRITE"
    assert rendered =~ "write_scope_expansion_required"
    assert rendered =~ "asked=write #{path}"
  end

  test "Linear correction comment explains why retry is parked until policy changes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-scope-unblock-comment-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root)

      issue = %Issue{
        id: "issue-scope-unblock-comment",
        identifier: "MT-SCOPE-COMMENT",
        title: "Scope unblock comment",
        state: "In Progress",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      path = "src/features/landing/GuestStartScreen.tsx"

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(
                 workspace,
                 issue,
                 scope_unblock_correction_attrs(issue,
                   path: path,
                   operation: "read",
                   next_action: "retry",
                   policy_hash: "sha256:unchanged-scope-policy"
                 )
               )

      body =
        Orchestrator.runtime_failure_comment_for_test(issue, correction, %{
          kind: "scope_access",
          source_status: "blocked",
          next_action: "retry",
          summary: "Scope access retry is parked until policy changes."
        })

      assert body =~ "Unblock report:"
      assert body =~ "Blocked: scope_policy_stale"
      assert body =~ "Worker asked for: read #{path}"
      assert body =~ "Why no retry: same head and same policy hash"
      assert body =~ "Next action: add read_context or update Linear write scope, then redispatch"
    after
      File.rm_rf(test_root)
    end
  end

  test "unsafe write expansion creates correction and does not retry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-scope-access-write-block-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(test_root)

      File.write!(codex_binary, """
      #!/bin/sh
      set -eu
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-scope-write"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-scope-write"}}}'
            printf '%s\\n' '{"method":"codex/event/response_item","params":{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"apply_patch *** Update File: src/features/landing/GuestStartScreen.tsx\\"}"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_forbidden_command_patterns: ["apply_patch"],
        max_turns: 3
      )

      issue = %Issue{
        id: "issue-scope-write",
        identifier: "MT-SCOPE-WRITE",
        title: "Scope write block",
        description: """
        ## Ticket Type

        Implementation

        ## Write Scope

        - `src/features/swipe/SwipeExperience.tsx`

        ## Validation

        ```bash
        pnpm test
        ```
        """,
        state: "In Progress",
        url: "https://example.org/issues/MT-SCOPE-WRITE",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil)

      trace = File.read!(trace_file)
      assert length(Regex.scan(~r/^RUN$/m, trace)) == 1

      workspace = Path.join(workspace_root, "MT-SCOPE-WRITE")
      corrections = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert [correction] = corrections
      assert correction["source"] == "symphony.runtime.scope-access"
      assert correction["guard"]["reason_class"] == "write_scope_expansion_requires_operator"
      assert correction["guard"]["retry_fingerprint"]["source"] == "symphony.runtime.scope-access"
      assert correction["guard"]["retry_fingerprint"]["operation"] == "write"
      assert correction["guard"]["retry_fingerprint"]["paths"] == ["src/features/landing/GuestStartScreen.tsx"]
      assert correction["guard"]["retry_fingerprint"]["policy_hash"] =~ "sha256:"
      assert correction["unblock_report"]["blocker_class"] == "write_scope_expansion_required"

      assert correction["unblock_report"]["next_action"] ==
               "update Linear write scope or narrow the worker command, then redispatch"

      assert Path.wildcard(Path.join(workspace, ".orocsy/delivery/policy-patches/*.json")) == []
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "knowledge ledger loads unchanged read context by git blob" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-knowledge-unchanged-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "MT-KNOWLEDGE")
      path = "src/features/landing/GuestStartScreen.tsx"

      File.mkdir_p!(Path.dirname(Path.join(workspace, path)))
      File.write!(Path.join(workspace, path), "export type GuestPreferenceDraft = { adults: number };\n")
      write_knowledge_preflight!(workspace, "MT-KNOWLEDGE")

      assert {:ok, entry} =
               SymphonyElixir.KnowledgeLedger.append(workspace, %{
                 issue: "MT-KNOWLEDGE",
                 path: path,
                 summary: "Defines GuestPreferenceDraft for the guest setup handoff.",
                 relevant_symbols: ["GuestPreferenceDraft"]
               })

      assert entry["git_blob"] != ""

      assert {:ok, preflight} = SymphonyElixir.DispatchPreflight.read(workspace)

      read_context = get_in(preflight, ["requirements", "scope_bundle", "read_context"])

      assert Enum.any?(read_context, fn entry ->
               entry["path"] == path and
                 entry["source"] == "knowledge_ledger.issue" and
                 entry["operation"] == "read" and
                 entry["expires"] == "file_changes" and
                 entry["summary"] =~ "GuestPreferenceDraft"
             end)

      assert [%{"path" => ^path, "status" => "fresh"}] = get_in(preflight, ["knowledge_ledger", "fresh"])
      assert get_in(preflight, ["knowledge_ledger", "stale"]) == []
    after
      File.rm_rf(test_root)
    end
  end

  test "knowledge ledger marks changed blob stale and permits bounded refresh" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-knowledge-stale-refresh-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "MT-KNOWLEDGE-STALE")
      path = "src/features/landing/GuestStartScreen.tsx"

      File.mkdir_p!(Path.dirname(Path.join(workspace, path)))
      File.write!(Path.join(workspace, path), "export const guestDraftVersion = 1;\n")
      write_knowledge_preflight!(workspace, "MT-KNOWLEDGE-STALE")

      assert {:ok, stored} =
               SymphonyElixir.KnowledgeLedger.append(workspace, %{
                 issue: "MT-KNOWLEDGE-STALE",
                 path: path,
                 summary: "Defines the first guest draft handoff version.",
                 relevant_symbols: ["guestDraftVersion"]
               })

      File.write!(Path.join(workspace, path), "export const guestDraftVersion = 2;\n")

      assert {:ok, preflight} = SymphonyElixir.DispatchPreflight.read(workspace)

      assert [
               %{
                 "path" => ^path,
                 "status" => "stale",
                 "git_blob" => stored_blob,
                 "current_git_blob" => current_blob,
                 "refresh_allowed" => true
               }
             ] = get_in(preflight, ["knowledge_ledger", "stale"])

      assert stored_blob == stored["git_blob"]
      refute current_blob == stored["git_blob"]

      read_context = get_in(preflight, ["requirements", "scope_bundle", "read_context"])

      assert Enum.any?(read_context, fn entry ->
               entry["path"] == path and
                 entry["source"] == "knowledge_ledger.stale_refresh" and
                 entry["operation"] == "read" and
                 entry["expires"] == "turn" and
                 entry["stale_git_blob"] == stored["git_blob"]
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "parent workstream knowledge is read context only and cannot broaden write scope" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-knowledge-parent-read-only-#{System.unique_integer([:positive])}"
      )

    try do
      producer_workspace = Path.join(test_root, "MT-KNOWLEDGE-PRODUCER")
      workspace = Path.join(test_root, "MT-KNOWLEDGE-CHILD")
      parent = "MT-KNOWLEDGE-PARENT"
      path = "src/features/landing/GuestStartScreen.tsx"
      write_path = "src/features/swipe/SwipeExperience.tsx"

      File.mkdir_p!(Path.dirname(Path.join(producer_workspace, path)))
      File.mkdir_p!(Path.dirname(Path.join(workspace, path)))
      File.mkdir_p!(Path.dirname(Path.join(workspace, write_path)))
      File.write!(Path.join(producer_workspace, path), "export function GuestStartScreen() { return null; }\n")
      File.write!(Path.join(workspace, path), "export function GuestStartScreen() { return null; }\n")
      File.write!(Path.join(workspace, write_path), "export function SwipeExperience() { return null; }\n")
      write_knowledge_preflight!(workspace, "MT-KNOWLEDGE-CHILD", parent, [write_path])

      assert {:ok, _entry} =
               SymphonyElixir.KnowledgeLedger.append(producer_workspace, %{
                 scope: "parent",
                 parent: parent,
                 path: path,
                 operation: "write",
                 summary: "GuestStartScreen owns the parent handoff entry point.",
                 relevant_symbols: ["GuestStartScreen"]
               })

      assert {:ok, preflight} = SymphonyElixir.DispatchPreflight.read(workspace)

      read_context = get_in(preflight, ["requirements", "scope_bundle", "read_context"])
      write_scope = get_in(preflight, ["requirements", "scope_bundle", "write_scope"])

      assert Enum.any?(read_context, fn entry ->
               entry["path"] == path and
                 entry["source"] == "knowledge_ledger.parent" and
                 entry["operation"] == "read"
             end)

      refute Enum.any?(write_scope, fn entry -> entry["path"] == path end)
      assert Enum.any?(write_scope, fn entry -> entry["path"] == write_path and entry["operation"] == "write" end)
    after
      File.rm_rf(test_root)
    end
  end

  test "prompt builder suppresses pushed handoff checkpoint in review rework preflight prompts" do
    workflow_prompt = "Ticket {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-pushed-handoff-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-205"],
          cd: workspace,
          stderr_to_stdout: true
        )

      feedback_path = Path.join(workspace, "tests/integration/cards-route.test.ts")
      File.mkdir_p!(Path.dirname(feedback_path))
      File.write!(feedback_path, "test('cards route', () => expect(true).toBe(true));\n")

      {_output, 0} =
        System.cmd("git", ["add", "tests/integration/cards-route.test.ts"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Add cards route test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://example.org/repo.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-205", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-205"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "focused validation passed", "ts": "2026-05-15T09:51:00Z"}\n)
      )

      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "review_rework",
          "branch" => "orocsy/mt-205",
          "checkpoint_event" => "review-feedback-classified",
          "first_task" => "Fix current-head feedback.",
          "issue" => "MT-205",
          "review" => %{
            "pr_number" => 56,
            "pr_url" => "https://github.com/acme/nutribuddy/pull/56",
            "head_sha" => "d7b8da54ba28448585f347bb9af9337cb42a62cd",
            "feedback" => [
              %{
                "path" => "tests/integration/cards-route.test.ts",
                "line" => 13,
                "body" => "Import handleCardsRequest from src/app/api/cards/handler.ts instead of the route.",
                "url" => "https://github.com/acme/nutribuddy/pull/56#discussion"
              }
            ]
          }
        })
      )

      issue = %Issue{
        identifier: "MT-205",
        title: "Fix current review feedback",
        description: "Retry flow",
        state: "Rework",
        url: "https://example.org/issues/MT-205",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, attempt: 2, workspace: workspace)

      assert String.starts_with?(prompt, "Runtime dispatch preflight:")
      assert prompt =~ "- Mode: review rework"
      assert prompt =~ "tests/integration/cards-route.test.ts"
      assert prompt =~ "Import handleCardsRequest"
      assert prompt =~ "Review rework execution contract:"
      refute prompt =~ "Pushed validated handoff checkpoint:"
      refute prompt =~ "Minimal review handoff mode:"
      refute prompt =~ "Ticket MT-205"
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder suppresses clean ahead local checkpoint in review rework prompts" do
    workflow_prompt = "Ticket {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-clean-ahead-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["branch", "-M", "main"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://example.org/repo.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/cod-246-review-rework"],
          cd: workspace,
          stderr_to_stdout: true
        )

      feedback_path = Path.join(workspace, "src/features/swipe/SwipeExperience.tsx")
      File.mkdir_p!(Path.dirname(feedback_path))
      File.write!(feedback_path, "export const cardsRequest = true;\n")

      {_output, 0} =
        System.cmd("git", ["add", "src/features/swipe/SwipeExperience.tsx"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Apply prior COD-246 work"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["branch", "--set-upstream-to", "origin/main"],
          cd: workspace,
          stderr_to_stdout: true
        )

      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "review_rework",
          "branch" => "orocsy/cod-246-review-rework",
          "checkpoint_event" => "review-feedback-classified",
          "first_task" => "Fix current-head feedback.",
          "issue" => "COD-246",
          "review" => %{
            "pr_number" => 103,
            "pr_url" => "https://github.com/acme/nutribuddy/pull/103",
            "head_sha" => "61f167a782",
            "feedback" => [
              %{
                "path" => "src/features/swipe/SwipeExperience.tsx",
                "line" => 105,
                "body" => "Apply guest safety preferences before loading cards.",
                "url" => "https://github.com/acme/nutribuddy/pull/103#discussion"
              }
            ]
          }
        })
      )

      issue = %Issue{
        identifier: "COD-246",
        title: "Fix current review feedback",
        description: "Retry flow",
        state: "Rework",
        url: "https://example.org/issues/COD-246",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, attempt: 2, workspace: workspace)

      assert String.starts_with?(prompt, "Runtime dispatch preflight:")
      assert prompt =~ "Apply guest safety preferences before loading cards."
      refute prompt =~ "Local handoff recovery checkpoint:"
      refute prompt =~ "Local commits ahead of `origin/main`"
      refute prompt =~ "Ticket COD-246"
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder uses minimal handoff prompt for dirty validated review rework" do
    workflow_prompt = """
    You must read AGENTS.md, load every project doc, and inspect historical delivery logs.
    Ticket {{ issue.identifier }}
    """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-dirty-validated-handoff-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/cod-266-review-rework"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://example.org/repo.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          ["update-ref", "refs/remotes/origin/orocsy/cod-266-review-rework", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          ["branch", "--set-upstream-to", "origin/orocsy/cod-266-review-rework"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      source_path = Path.join(workspace, "src/features/swipe/SwipeExperience.tsx")
      test_path = Path.join(workspace, "tests/unit/swipe-experience-request.test.ts")
      File.mkdir_p!(Path.dirname(source_path))
      File.mkdir_p!(Path.dirname(test_path))
      File.write!(source_path, "export const requestCards = false;\n")
      File.write!(test_path, "test('request cards', () => false);\n")

      {_output, 0} =
        System.cmd("git", ["add", "src/features/swipe/SwipeExperience.tsx", "tests/unit/swipe-experience-request.test.ts"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Add swipe request files"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(source_path, "export const requestCards = true;\n")
      File.write!(test_path, "test('request cards', () => true);\n")

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(event_dir)
      File.mkdir_p!(state_dir)
      validated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event":"validation","status":"passed","command":"pnpm exec vitest run --configLoader runner tests/unit/swipe-experience-request.test.ts","step":"Focused SwipeExperience request validation passed","tool":"vitest","ts":"#{validated_at}"}\n)
      )

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "review_rework",
          "branch" => "orocsy/cod-266-review-rework",
          "checkpoint_event" => "review-feedback-classified",
          "first_task" => "Finish dirty validated handoff.",
          "issue" => "COD-266",
          "review" => %{
            "pr_number" => 103,
            "pr_url" => "https://github.com/acme/nutribuddy/pull/103",
            "head_sha" => "d47b2d36d6",
            "feedback" => [
              %{
                "path" => "src/features/swipe/SwipeExperience.tsx",
                "line" => 105,
                "body" => "Apply guest safety preferences before loading cards.",
                "url" => "https://github.com/acme/nutribuddy/pull/103#discussion"
              }
            ]
          }
        })
      )

      issue = %Issue{
        identifier: "COD-266",
        title: "Send bounded guest safety draft",
        description: "Retry flow",
        state: "Rework",
        url: "https://example.org/issues/COD-266",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, attempt: 2, workspace: workspace)

      assert String.starts_with?(prompt, "Dirty validated handoff checkpoint:")
      assert prompt =~ "Dirty validated review-rework handoff contract:"
      assert prompt =~ "do not rerun the same validation command"
      assert prompt =~ "Stage only the intended dirty product/test files"
      assert prompt =~ "Runtime dispatch preflight:"
      assert prompt =~ "Apply guest safety preferences before loading cards."
      refute prompt =~ "Review rework execution contract:"
      refute prompt =~ "You must read AGENTS.md"
      refute prompt =~ "Ticket COD-266"
    after
      File.rm_rf(workspace)
    end
  end

  test "review rework command policy blocks dirty validated handoff rechecks before commit" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-dirty-validated-policy-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      source_path = Path.join(workspace, "src/features/swipe/SwipeExperience.tsx")
      test_path = Path.join(workspace, "tests/unit/swipe-experience-request.test.ts")
      File.mkdir_p!(Path.dirname(source_path))
      File.mkdir_p!(Path.dirname(test_path))
      File.write!(source_path, "export const requestCards = false;\n")
      File.write!(test_path, "test('request cards', () => false);\n")

      {_output, 0} =
        System.cmd("git", ["add", "src/features/swipe/SwipeExperience.tsx", "tests/unit/swipe-experience-request.test.ts"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Add swipe request files"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(source_path, "export const requestCards = true;\n")
      File.write!(test_path, "test('request cards', () => true);\n")

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(event_dir)
      File.mkdir_p!(state_dir)
      validated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event":"validation","status":"passed","command":"pnpm exec vitest run --configLoader runner tests/unit/swipe-experience-request.test.ts","step":"Focused SwipeExperience request validation passed","tool":"vitest","ts":"#{validated_at}"}\n)
      )

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "review_rework",
          "branch" => "orocsy/cod-266-review-rework",
          "checkpoint_event" => "review-feedback-classified",
          "first_task" => "Finish dirty validated handoff.",
          "issue" => "COD-266",
          "requirements" => %{
            "ticket_type" => "Implementation",
            "write_scope" => ["src/features/swipe/SwipeExperience.tsx"],
            "validation" => %{
              "commands" => ["pnpm exec vitest run --configLoader runner tests/unit/swipe-experience-request.test.ts"],
              "files" => ["tests/unit/swipe-experience-request.test.ts"]
            }
          },
          "review" => %{
            "feedback" => [
              %{
                "path" => "src/features/swipe/SwipeExperience.tsx",
                "line" => 105,
                "body" => "Apply guest safety preferences before loading cards."
              }
            ]
          }
        })
      )

      assert {:error, _command, "dirty_validated_handoff_recheck_before_commit"} =
               AppServer.command_policy_violation_for_test(
                 workspace,
                 "git diff -- src/features/swipe/SwipeExperience.tsx"
               )

      assert {:error, _command, "dirty_validated_handoff_recheck_before_commit"} =
               AppServer.command_policy_violation_for_test(
                 workspace,
                 "sed -n '1,220p' tests/unit/swipe-experience-request.test.ts"
               )

      assert {:error, _command, "dirty_validated_handoff_recheck_before_commit"} =
               AppServer.command_policy_violation_for_test(
                 workspace,
                 "pnpm exec vitest run --configLoader runner tests/unit/swipe-experience-request.test.ts"
               )

      assert :ok = AppServer.command_policy_violation_for_test(workspace, "git status --short --branch")

      assert :ok =
               AppServer.command_policy_violation_for_test(
                 workspace,
                 "git add src/features/swipe/SwipeExperience.tsx tests/unit/swipe-experience-request.test.ts"
               )

      assert :ok =
               AppServer.command_policy_violation_for_test(
                 workspace,
                 "git commit -m 'COD-266: send guest safety draft to cards request'"
               )

      assert :ok =
               AppServer.command_policy_violation_for_test(
                 workspace,
                 ~s(PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . event append --type tool.finished --status passed --tool "pnpm typecheck")
               )

      assert :ok = AppServer.command_policy_violation_for_test(workspace, "git push")
    after
      File.rm_rf(workspace)
    end
  end

  test "review rework command policy allows revalidation when dirty files changed after evidence" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-stale-dirty-validation-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      source_path = Path.join(workspace, "src/features/swipe/SwipeExperience.tsx")
      test_path = Path.join(workspace, "tests/unit/swipe-experience-request.test.ts")
      File.mkdir_p!(Path.dirname(source_path))
      File.mkdir_p!(Path.dirname(test_path))
      File.write!(source_path, "export const requestCards = false;\n")
      File.write!(test_path, "test('request cards', () => false);\n")

      {_output, 0} =
        System.cmd("git", ["add", "src/features/swipe/SwipeExperience.tsx", "tests/unit/swipe-experience-request.test.ts"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Add swipe request files"],
          cd: workspace,
          stderr_to_stdout: true
        )

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(event_dir)
      File.mkdir_p!(state_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event":"validation","status":"passed","command":"pnpm exec vitest run --configLoader runner tests/unit/swipe-experience-request.test.ts","step":"Focused SwipeExperience request validation passed","tool":"vitest","ts":"2026-01-01T00:00:00Z"}\n)
      )

      File.write!(source_path, "export const requestCards = true;\n")
      File.write!(test_path, "test('request cards', () => true);\n")

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "review_rework",
          "branch" => "orocsy/cod-266-review-rework",
          "first_task" => "Finish dirty validated handoff.",
          "issue" => "COD-266"
        })
      )

      assert :ok =
               AppServer.command_policy_violation_for_test(
                 workspace,
                 "pnpm exec vitest run --configLoader runner tests/unit/swipe-experience-request.test.ts"
               )

      assert :ok =
               AppServer.command_policy_violation_for_test(
                 workspace,
                 "git diff -- src/features/swipe/SwipeExperience.tsx"
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder preserves local handoff checkpoint in integration check preflight prompts" do
    workflow_prompt = "Ticket {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-integration-local-handoff-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["branch", "-M", "main"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/feature-analytics-observability-integration"],
          cd: workspace,
          stderr_to_stdout: true
        )

      feedback_path = Path.join(workspace, "tests/unit/recipe-chat-page-view.test.ts")
      File.mkdir_p!(Path.dirname(feedback_path))
      File.write!(feedback_path, "export const integrationFix = false;\n")

      {_output, 0} =
        System.cmd("git", ["add", "tests/unit/recipe-chat-page-view.test.ts"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Add integration test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(feedback_path, "export const integrationFix = true;\n")

      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{
          "mode" => "integration_check",
          "branch" => "orocsy/feature-analytics-observability-integration",
          "checkpoint_event" => "technical-miu-trace",
          "first_task" => "Validate the dirty integration handoff.",
          "issue" => "COD-208"
        })
      )

      issue = %Issue{
        identifier: "COD-208",
        title: "Recover integration handoff",
        description: "Retry flow",
        state: "Rework",
        url: "https://example.org/issues/COD-208",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, attempt: 2, workspace: workspace)

      assert String.starts_with?(prompt, "Local handoff recovery checkpoint:")
      assert prompt =~ "Runtime dispatch preflight:"
      assert prompt =~ "If a dirty/local handoff checkpoint appears above"
      assert prompt =~ "tests/unit/recipe-chat-page-view.test.ts"
      assert prompt =~ "Ticket COD-208"
      assert length(String.split(prompt, "Local handoff recovery checkpoint:")) == 2
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder ignores generic gates on clean tracked branches without a handoff certificate" do
    workflow_prompt = """
    You must read AGENTS.md, load every project doc, and inspect historical delivery logs.
    Ticket {{ issue.identifier }}
    """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pushed-validated-handoff-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-204"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nReady.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Add ready state"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://example.org/repo.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-204", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-204"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "handoff-ready validation passed", "ts": "2026-05-12T05:00:49Z"}\n)
      )

      issue = %Issue{
        identifier: "MT-204",
        title: "Finish pushed handoff",
        description: "Retry flow",
        state: "In Progress",
        url: "https://example.org/issues/MT-204",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, attempt: 2, workspace: workspace)

      refute String.starts_with?(prompt, "Pushed validated handoff checkpoint:")
      refute prompt =~ "Minimal review handoff mode:"
      refute prompt =~ "handoff-ready validation passed"
      assert prompt =~ "You must read AGENTS.md"
      assert prompt =~ "Ticket MT-204"
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder continues clean in-progress implementation branches instead of handoff mode" do
    workflow_prompt = """
    Continue normal worker prompt.
    Ticket {{ issue.identifier }}
    """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-in-progress-implementation-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/cod-213-runtime-foundation"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nCheckpoint.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Add checkpoint"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://example.org/repo.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          ["update-ref", "refs/remotes/origin/orocsy/cod-213-runtime-foundation", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          ["branch", "--set-upstream-to", "origin/orocsy/cod-213-runtime-foundation"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "first implementation checkpoint", "ts": "2026-05-12T05:00:49Z"}\n)
      )

      issue = %Issue{
        identifier: "COD-213",
        title: "Cloudflare Runtime Foundation Implementation",
        description:
          "## Ticket Type\n\nimplementation\n\n## Runtime Problem\n\nContinue the remaining runtime foundation implementation.\n\n## Write Scope\n\n- `package.json`\n\n## Validation\n\n```bash\npnpm lint\n```\n",
        state: "In Progress",
        url: "https://example.org/issues/COD-213",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, attempt: 2, workspace: workspace)

      refute String.starts_with?(prompt, "Pushed validated handoff checkpoint:")
      refute prompt =~ "Minimal review handoff mode:"
      assert prompt =~ "Continue normal worker prompt."
      assert prompt =~ "Ticket COD-213"
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder does not treat a pushed branch as validated when a later validation blocker exists" do
    workflow_prompt = """
    Continue normal worker prompt.
    Ticket {{ issue.identifier }}
    """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pushed-handoff-validation-blocked-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-205"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nReview fix.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Fix review feedback"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://example.org/repo.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-205", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-205"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        """
        {"event":"tool.finished","status":"passed","tool":"review-feedback-classified","ts":"2026-05-12T05:00:49Z"}
        {"event":"validation.blocker","status":"blocked","tool":"pnpm test","ts":"2026-05-12T05:01:49Z"}
        {"event":"tool.finished","status":"passed","tool":"technical-miu-trace","step":"validation-only handoff checkpoint: validation=pnpm test","ts":"2026-05-12T05:02:49Z"}
        """
      )

      issue = %Issue{
        identifier: "MT-205",
        title: "Continue validation rework",
        description: "Retry flow",
        state: "Rework",
        url: "https://example.org/issues/MT-205",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, attempt: 2, workspace: workspace)

      refute String.starts_with?(prompt, "Pushed validated handoff checkpoint:")
      refute prompt =~ "Minimal review handoff mode:"
      assert prompt =~ "Continue normal worker prompt."
      assert prompt =~ "Ticket MT-205"
    after
      File.rm_rf(workspace)
    end
  end

  test "orchestrator skips pushed review handoff inspection when monitor is disabled" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-disabled-direct-pushed-handoff-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_enabled: false,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-disabled-direct-handoff",
        identifier: "MT-204",
        title: "Leave disabled monitor handoff alone",
        description: "Review monitor is disabled for this deployment.",
        state: "Rework",
        url: "https://linear.example/MT-204",
        branch_name: "orocsy/mt-204",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-204"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nReady.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Add ready handoff"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-204", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-204"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "focused validation passed", "ts": "2026-05-12T05:00:49Z"}\n)
      )

      parent = self()

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        send(parent, {:unexpected_review_inspection, endpoint})
        {:error, {:unexpected_endpoint, endpoint}}
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, variables ->
        send(parent, {:unexpected_review_graphql_inspection, variables})
        {:error, {:unexpected_graphql_variables, variables}}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert :not_ready = Orchestrator.complete_pushed_handoff_for_test(issue)

      refute_receive {:memory_tracker_state_update, "issue-disabled-direct-handoff", "Human Review"},
                     50

      refute_receive {:memory_tracker_comment, "issue-disabled-direct-handoff", _body}, 50
      refute_receive {:unexpected_review_inspection, _endpoint}, 50
      refute_receive {:unexpected_review_graphql_inspection, _variables}, 50
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator automatically merges a certified In Progress exact-head handoff" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-direct-pushed-handoff-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue =
        runtime_handoff_issue(
          %Issue{
            id: "issue-direct-handoff",
            identifier: "MT-205",
            title: "Finish pushed handoff",
            description: "Only PR review handoff remains.",
            state: "In Progress",
            url: "https://linear.example/MT-205",
            branch_name: "orocsy/mt-205",
            labels: []
          },
          automatic_merge: true
        )

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-205"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nReady.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Add ready handoff"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-205", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-205"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {handoff_sha, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      handoff_sha = String.trim(handoff_sha)
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "focused validation passed", "ts": "2026-05-12T05:00:49Z"}\n)
      )

      issue_runtime_handoff_certificate!(workspace, issue)
      issue = %{issue | branch_name: "orocsy/stale-linear-branch"}

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            query = endpoint |> String.split("?", parts: 2) |> List.last() |> URI.decode_query()
            send(self(), {:direct_handoff_pull_lookup, query["head"]})

            {:ok,
             [
               %{
                 "number" => 3,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/3",
                 "head" => %{"sha" => handoff_sha, "ref" => "orocsy/mt-205"}
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/3" ->
            {:ok,
             %{
               "number" => 3,
               "state" => "open",
               "html_url" => "https://github.com/acme/nutribuddy/pull/3",
               "head" => %{"sha" => handoff_sha, "ref" => "orocsy/mt-205"},
               "base" => %{"ref" => "main"},
               "mergeable" => true,
               "mergeable_state" => "clean",
               "head_committed_at" => "2026-05-12T05:00:50Z"
             }}

          endpoint == "repos/acme/nutribuddy/pulls/3/comments" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/3/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/3/comments?") ->
            {:ok,
             [
               %{
                 "body" => "@codex review\n\nFinal review requested after #{handoff_sha}.",
                 "created_at" => "2026-05-12T05:01:00Z",
                 "html_url" => "https://github.com/acme/nutribuddy/pull/3#issuecomment-review-request"
               },
               %{
                 "body" => "Codex Review: Didn't find any major issues. Bravo.",
                 "created_at" => "2026-05-12T05:05:00Z",
                 "html_url" => "https://github.com/acme/nutribuddy/pull/3#issuecomment-clean-review",
                 "user" => %{"login" => "chatgpt-codex-connector[bot]", "type" => "Bot"}
               }
             ]}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/commits/#{handoff_sha}/check-runs?") ->
            {:ok,
             %{
               "check_runs" => [
                 %{"name" => "test", "status" => "completed", "conclusion" => "success"}
               ]
             }}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => handoff_sha,
                 "reviewThreads" => %{
                   "nodes" => [
                     %{
                       "isResolved" => true,
                       "isOutdated" => false,
                       "comments" => %{
                         "nodes" => [
                           %{
                             "body" => "Already resolved current-head feedback.",
                             "path" => "README.md",
                             "line" => 3,
                             "url" => "https://github.com/acme/nutribuddy/pull/3#discussion"
                           }
                         ]
                       }
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      Application.put_env(:symphony_elixir, :github_merge_runner, fn endpoint, fields ->
        send(self(), {:github_merge, endpoint, fields})
        {:ok, %{"merged" => true, "sha" => "merged-mt-205"}}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
        Application.delete_env(:symphony_elixir, :github_merge_runner)
      end)

      assert {:completed, %{target_state: "Done", pr_number: 3, merge_sha: "merged-mt-205"}} =
               Orchestrator.complete_pushed_handoff_for_test(issue)

      assert_receive {:memory_tracker_state_update, "issue-direct-handoff", "Done"}
      assert_receive {:direct_handoff_pull_lookup, "acme:orocsy/mt-205"}
      assert_receive {:memory_tracker_comment, "issue-direct-handoff", body}
      assert body =~ "automatic exact-head merge"
      assert body =~ "https://github.com/acme/nutribuddy/pull/3"

      events = File.read!(Path.join(event_dir, "events.jsonl"))
      assert events =~ ~s("event":"merge.completed")
      assert events =~ "merged-mt-205"
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator blocks pushed review handoff when live PR head differs from local checkpoint" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-direct-pushed-handoff-stale-head-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue =
        runtime_handoff_issue(%Issue{
          id: "issue-direct-handoff-stale-head",
          identifier: "MT-208",
          title: "Do not complete stale pushed handoff",
          description: "The PR branch advanced after local validation.",
          state: "Rework",
          branch_name: "orocsy/mt-208",
          labels: []
        })

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-208"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nReady locally.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Add local handoff"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-208", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-208"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {local_head, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      local_head = String.trim(local_head)
      live_head = "remote-advanced-head"
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "focused validation passed", "ts": "2026-05-12T05:00:49Z"}\n)
      )

      issue_runtime_handoff_certificate!(workspace, issue)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 3,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/3",
                 "head" => %{"sha" => live_head, "ref" => "orocsy/mt-208"}
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/3/comments" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/3/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/3/comments?") ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => live_head,
                 "reviewThreads" => %{
                   "nodes" => [],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert {:blocked, {:pushed_handoff_head_mismatch, ^local_head, ^live_head}} =
               Orchestrator.complete_pushed_handoff_for_test(issue)

      refute_receive {:memory_tracker_state_update, "issue-direct-handoff-stale-head", "Human Review"},
                     50

      [correction] = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert correction["source"] == "symphony.runtime.handoff-review"
      assert Enum.join(correction["findings"], " ") =~ "pushed_handoff_head_mismatch"
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator leaves pushed handoff to minimal worker when current review feedback remains" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-direct-pushed-handoff-feedback-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue =
        runtime_handoff_issue(%Issue{
          id: "issue-direct-handoff-feedback",
          identifier: "MT-206",
          title: "Resolve feedback",
          description: "Review feedback remains.",
          state: "Rework",
          branch_name: "orocsy/mt-206",
          labels: []
        })

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-206"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nNeeds feedback fix.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Add review state"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-206", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-206"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {handoff_sha, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      handoff_sha = String.trim(handoff_sha)
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "focused validation passed", "ts": "2026-05-12T05:00:49Z"}\n)
      )

      issue_runtime_handoff_certificate!(workspace, issue)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 3,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/3",
                 "head" => %{"sha" => handoff_sha, "ref" => "orocsy/mt-206"}
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/3/comments" ->
            {:ok,
             [
               %{
                 "body" => "Fix the review target.",
                 "commit_id" => handoff_sha,
                 "path" => "README.md",
                 "line" => 3,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/3#discussion"
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/3/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/3/comments?") ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => handoff_sha,
                 "reviewThreads" => %{
                   "nodes" => [
                     %{
                       "isResolved" => false,
                       "isOutdated" => false,
                       "comments" => %{
                         "nodes" => [
                           %{
                             "body" => "Fix the review target.",
                             "path" => "README.md",
                             "line" => 3,
                             "url" => "https://github.com/acme/nutribuddy/pull/3#discussion"
                           }
                         ]
                       }
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert :not_ready = Orchestrator.complete_pushed_handoff_for_test(issue)

      refute_receive {:memory_tracker_state_update, "issue-direct-handoff-feedback", "Human Review"},
                     50
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator directly requests review when pushed handoff is newer than remaining feedback" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-direct-pushed-handoff-request-review-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue =
        runtime_handoff_issue(%Issue{
          id: "issue-direct-handoff-request-review",
          identifier: "MT-206",
          title: "Request review after pushed fix",
          description: "Review feedback was fixed by the pushed handoff commit.",
          state: "Rework",
          branch_name: "orocsy/mt-206",
          labels: []
        })

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-206"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nFeedback fixed.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      commit_env = [
        {"GIT_AUTHOR_DATE", "2026-05-15T09:30:00Z"},
        {"GIT_COMMITTER_DATE", "2026-05-15T09:30:00Z"}
      ]

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Fix pushed feedback"],
          cd: workspace,
          env: commit_env,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-206", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-206"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {handoff_sha, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      handoff_sha = String.trim(handoff_sha)
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "focused validation passed", "ts": "2026-05-15T09:29:00Z"}\n)
      )

      issue_runtime_handoff_certificate!(workspace, issue)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 3,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/3",
                 "head" => %{"sha" => handoff_sha, "ref" => "orocsy/mt-206"}
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/3/comments" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/3/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/3/comments?") ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      parent = self()

      Application.put_env(:symphony_elixir, :github_api_post_runner, fn endpoint, fields ->
        send(parent, {:github_post, endpoint, fields})
        {:ok, %{"id" => 123, "body" => fields["body"]}}
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => handoff_sha,
                 "reviewThreads" => %{
                   "nodes" => [
                     %{
                       "isResolved" => false,
                       "isOutdated" => false,
                       "comments" => %{
                         "nodes" => [
                           %{
                             "body" => "Old feedback fixed by the pushed commit.",
                             "path" => "README.md",
                             "line" => 3,
                             "createdAt" => "2026-05-15T09:20:00Z",
                             "url" => "https://github.com/acme/nutribuddy/pull/3#discussion"
                           }
                         ]
                       }
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_api_post_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert {:blocked, :review_pending} = Orchestrator.complete_pushed_handoff_for_test(issue)

      assert_receive {:github_post, "repos/acme/nutribuddy/issues/3/comments", %{"body" => body}}
      short_sha = String.slice(handoff_sha, 0, 10)
      assert body =~ "@codex review"
      assert body =~ short_sha

      assert_receive {:memory_tracker_comment, "issue-direct-handoff-request-review", tracker_body}

      assert tracker_body =~ "without starting another Codex worker"
      assert tracker_body =~ short_sha

      refute_receive {:memory_tracker_state_update, "issue-direct-handoff-request-review", "Human Review"},
                     50

      events = File.read!(Path.join(event_dir, "events.jsonl"))
      assert events =~ ~s("tool":"codex-review-requested")
      assert events =~ "direct-pushed-review-request"
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestration review guard requests review for clean implementation PR without worker" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-orchestration-review-pending-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-orchestration-review-pending",
        identifier: "COD-205",
        title: "Analytics MIU: Flow Instrumentation",
        description: "Implementation ticket is waiting on the current PR review.",
        state: "Rework",
        branch_name: "orocsy/cod-205-analytics-miu-flow-instrumentation",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/feature-analytics-observability-integration"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nAnalytics ready.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Add analytics handoff"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          [
            "update-ref",
            "refs/remotes/origin/orocsy/feature-analytics-observability-integration",
            "HEAD"
          ],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          [
            "branch",
            "--set-upstream-to",
            "origin/orocsy/feature-analytics-observability-integration"
          ],
          cd: workspace,
          stderr_to_stdout: true
        )

      {handoff_sha, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      handoff_sha = String.trim(handoff_sha)
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      parent = self()

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        decoded = URI.decode(endpoint)

        cond do
          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(
                decoded,
                "head=acme:orocsy/feature-analytics-observability-integration"
              ) ->
            {:ok,
             [
               %{
                 "number" => 56,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/56",
                 "head" => %{
                   "sha" => handoff_sha,
                   "ref" => "orocsy/feature-analytics-observability-integration"
                 }
               }
             ]}

          decoded == "repos/acme/nutribuddy/pulls/56" ->
            {:ok,
             %{
               "number" => 56,
               "html_url" => "https://github.com/acme/nutribuddy/pull/56",
               "head" => %{
                 "sha" => handoff_sha,
                 "ref" => "orocsy/feature-analytics-observability-integration"
               },
               "mergeable" => true,
               "mergeable_state" => "clean"
             }}

          decoded in [
            "repos/acme/nutribuddy/pulls/56/comments",
            "repos/acme/nutribuddy/pulls/56/reviews"
          ] ->
            {:ok, []}

          String.starts_with?(decoded, "repos/acme/nutribuddy/issues/56/comments?") ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      Application.put_env(:symphony_elixir, :github_api_post_runner, fn endpoint, fields ->
        send(parent, {:github_post, endpoint, fields})
        {:ok, %{"id" => 456, "body" => fields["body"]}}
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => handoff_sha,
                 "reviewThreads" => %{
                   "nodes" => [],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_api_post_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert {:blocked, :review_pending} =
               Orchestrator.handle_orchestration_review_pending_for_test(issue)

      assert_receive {:github_post, "repos/acme/nutribuddy/issues/56/comments", %{"body" => body}}
      assert body =~ "@codex review"
      assert body =~ String.slice(handoff_sha, 0, 10)

      assert_receive {:memory_tracker_comment, "issue-orchestration-review-pending", tracker_body}
      assert tracker_body =~ "without starting another Codex worker"
      assert tracker_body =~ "orocsy/feature-analytics-observability-integration"

      events = File.read!(Path.join(workspace, ".orocsy/delivery/events/events.jsonl"))
      assert events =~ ~s("tool":"codex-review-requested")
      assert events =~ "direct-pushed-review-request"

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        decoded = URI.decode(endpoint)

        cond do
          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") and
              String.contains?(
                decoded,
                "head=acme:orocsy/feature-analytics-observability-integration"
              ) ->
            {:ok,
             [
               %{
                 "number" => 56,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/56",
                 "head" => %{
                   "sha" => handoff_sha,
                   "ref" => "orocsy/feature-analytics-observability-integration"
                 }
               }
             ]}

          decoded == "repos/acme/nutribuddy/pulls/56" ->
            {:ok,
             %{
               "number" => 56,
               "state" => "open",
               "html_url" => "https://github.com/acme/nutribuddy/pull/56",
               "head" => %{
                 "sha" => handoff_sha,
                 "ref" => "orocsy/feature-analytics-observability-integration"
               },
               "base" => %{"ref" => "main"},
               "mergeable" => true,
               "mergeable_state" => "clean"
             }}

          decoded in [
            "repos/acme/nutribuddy/pulls/56/comments",
            "repos/acme/nutribuddy/pulls/56/reviews"
          ] ->
            {:ok, []}

          String.starts_with?(decoded, "repos/acme/nutribuddy/issues/56/comments?") ->
            {:ok,
             [
               %{
                 "body" => "@codex review",
                 "created_at" => "2026-07-15T17:44:23Z"
               },
               %{
                 "body" => "Codex Review: Didn't find any major issues.\n\n**Reviewed commit:** `#{String.slice(handoff_sha, 0, 10)}`",
                 "created_at" => "2026-07-15T17:50:50Z",
                 "user" => %{"login" => "chatgpt-codex-connector[bot]", "type" => "Bot"}
               }
             ]}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      assert :not_ready = Orchestrator.handle_orchestration_review_pending_for_test(issue)
      refute File.exists?(Path.join(workspace, ".orocsy/delivery/state/handoff-ready.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestration review guard recertifies a clean reviewed delta without a worker" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-clean-reviewed-delta-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Changes Requested"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Changes Requested"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue =
        runtime_handoff_issue(%Issue{
          id: "issue-clean-reviewed-delta",
          identifier: "COD-273",
          title: "Responsive design source",
          description: "Certify an already-pushed review fix.",
          state: "Changes Requested",
          branch_name: "orocsy/cod-273",
          labels: []
        })

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["config", "user.email", "symphony@example.test"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["config", "user.name", "Symphony Test"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "README.md"), "# Test\n")
      {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["switch", "-c", issue.branch_name], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "README.md"), "# Test\n\nInitial MIU.\n")
      {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Implement MIU"], cd: workspace, stderr_to_stdout: true)

      assert {:ok, _miu} =
               SymphonyElixir.ValidationController.certify_miu(issue, workspace, "COD-273-MIU-1")

      push_workspace_head_to_test_origin!(workspace)
      issue_runtime_handoff_certificate!(workspace, issue)
      prior_handoff_head = git_head!(workspace)

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nInitial MIU.\n\nReviewed correction.\n")
      {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Address review feedback"], cd: workspace, stderr_to_stdout: true)
      push_workspace_head_to_test_origin!(workspace)
      reviewed_head = git_head!(workspace)
      refute reviewed_head == prior_handoff_head

      parent = self()

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        decoded = URI.decode(endpoint)

        cond do
          String.starts_with?(decoded, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 61,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/61",
                 "head" => %{"sha" => reviewed_head, "ref" => issue.branch_name}
               }
             ]}

          decoded == "repos/acme/nutribuddy/pulls/61" ->
            send(parent, :clean_review_pull_inspected)

            {:ok,
             %{
               "number" => 61,
               "state" => "open",
               "html_url" => "https://github.com/acme/nutribuddy/pull/61",
               "head" => %{"sha" => reviewed_head, "ref" => issue.branch_name},
               "base" => %{"ref" => "main"},
               "mergeable" => true,
               "mergeable_state" => "clean"
             }}

          decoded == "repos/acme/nutribuddy/commits/#{reviewed_head}" ->
            {:ok, %{"commit" => %{"committer" => %{"date" => "2026-07-15T20:10:00Z"}}}}

          decoded in [
            "repos/acme/nutribuddy/pulls/61/comments",
            "repos/acme/nutribuddy/pulls/61/reviews"
          ] ->
            {:ok, []}

          String.starts_with?(decoded, "repos/acme/nutribuddy/issues/61/comments?") ->
            {:ok,
             [
               %{"body" => "@codex review", "created_at" => "2026-07-15T20:11:00Z"},
               %{
                 "body" => "Codex Review: Didn't find any major issues.\n\n**Reviewed commit:** `#{String.slice(reviewed_head, 0, 10)}`",
                 "created_at" => "2026-07-15T20:12:00Z",
                 "user" => %{"login" => "chatgpt-codex-connector[bot]", "type" => "Bot"}
               }
             ]}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      Application.put_env(:symphony_elixir, :github_api_post_runner, fn endpoint, fields ->
        send(parent, {:unexpected_github_post, endpoint, fields})
        {:ok, fields}
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => reviewed_head,
                 "reviewThreads" => %{
                   "nodes" => [],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_api_post_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert {:error, :review_delta_recovery_not_authorized} =
               SymphonyElixir.DispatchPreflight.prepare_review_delta_recovery(workspace, issue, %{
                 head_sha: reviewed_head,
                 head_ref: issue.branch_name,
                 feedback: [%{path: "README.md", summary: "New current-head feedback"}]
               })

      assert {:error, :review_delta_recovery_not_authorized} =
               SymphonyElixir.DispatchPreflight.prepare_review_delta_recovery(workspace, issue, %{
                 head_sha: String.duplicate("f", 40),
                 head_ref: issue.branch_name,
                 feedback: []
               })

      assert {:ok, %{"mode" => "review_rework"} = recovery_preflight} =
               SymphonyElixir.DispatchPreflight.prepare_review_delta_recovery(workspace, issue, %{
                 head_sha: reviewed_head,
                 head_ref: issue.branch_name,
                 feedback: []
               })

      assert recovery_preflight["review_delta_base_head"] == prior_handoff_head

      assert {:completed, handoff} =
               Orchestrator.handle_orchestration_review_pending_for_test(issue)

      assert handoff.head_sha == reviewed_head
      assert handoff.target_state == "Human Review"
      assert {:ok, certificate} = SymphonyElixir.HandoffCertificate.current(issue, workspace)
      assert certificate["head_sha"] == reviewed_head

      assert {:ok, %{"mode" => "review_rework"} = preflight} =
               SymphonyElixir.DispatchPreflight.read_authoritative(workspace)

      assert preflight["review_delta_base_head"] == prior_handoff_head
      assert_receive :clean_review_pull_inspected
      assert_receive :clean_review_pull_inspected
      refute_receive {:unexpected_github_post, _endpoint, _fields}, 50
      assert_receive {:memory_tracker_state_update, "issue-clean-reviewed-delta", "Human Review"}
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator directly requests review for no-code review classification handoff" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-classification-request-review-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-review-classification-request",
        identifier: "COD-199",
        title: "Auth Integration Check And Final PR Handoff",
        description: "Review feedback was classified as already resolved.",
        state: "Rework",
        branch_name: "orocsy/feature-auth-migration-integration",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/feature-auth-migration-integration"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nReview feedback already fixed.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Resolve review feedback"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          ["update-ref", "refs/remotes/origin/orocsy/feature-auth-migration-integration", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          ["branch", "--set-upstream-to", "origin/orocsy/feature-auth-migration-integration"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {head_sha, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      head_sha = String.trim(head_sha)
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)

      File.write!(
        Path.join(state_dir, "review-feedback-classified.json"),
        Jason.encode!(
          %{
            "checkpoint" => "review-feedback-classified",
            "issue" => "COD-199",
            "pr" => 54,
            "head" => head_sha,
            "branch" => "orocsy/feature-auth-migration-integration",
            "classification" => "already_resolved_in_current_head",
            "feedback" => [
              %{
                "path" => "src/lib/providers/auth-provider.ts",
                "line" => 69,
                "classification" => "stale_resolved",
                "reason" => "Current head already rejects mismatched fake provider configuration."
              }
            ],
            "code_edit" => "none",
            "validation" => "not_run_no_code_change",
            "push" => "not_run_no_code_change",
            "review_request" => "not_requested_no_code_change"
          },
          pretty: true
        ) <> "\n"
      )

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 54,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/54",
                 "head" => %{
                   "sha" => head_sha,
                   "ref" => "orocsy/feature-auth-migration-integration"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/54/comments" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/54/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/54/comments?") ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      parent = self()

      Application.put_env(:symphony_elixir, :github_api_post_runner, fn endpoint, fields ->
        send(parent, {:github_post, endpoint, fields})
        {:ok, %{"id" => 456, "body" => fields["body"]}}
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => head_sha,
                 "reviewThreads" => %{
                   "nodes" => [
                     %{
                       "isResolved" => false,
                       "isOutdated" => false,
                       "comments" => %{
                         "nodes" => [
                           %{
                             "body" => "Reject mismatched public auth provider in fake mode.",
                             "path" => "src/lib/providers/auth-provider.ts",
                             "line" => 69,
                             "createdAt" => "2026-05-23T19:00:00Z",
                             "url" => "https://github.com/acme/nutribuddy/pull/54#discussion"
                           }
                         ]
                       }
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_api_post_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert {:blocked, :review_pending} =
               Orchestrator.complete_review_classification_handoff_for_test(issue)

      assert_receive {:github_post, "repos/acme/nutribuddy/issues/54/comments", %{"body" => body}}
      assert body =~ "@codex review"
      assert body =~ "classified the current PR feedback as already resolved"
      assert body =~ String.slice(head_sha, 0, 10)

      assert_receive {:memory_tracker_comment, "issue-review-classification-request", tracker_body}

      assert tracker_body =~ "no-code review classification checkpoint"
      assert tracker_body =~ "without starting another product-code worker"

      refute_receive {:memory_tracker_state_update, "issue-review-classification-request", "Human Review"},
                     50

      events = File.read!(Path.join(workspace, ".orocsy/delivery/events/events.jsonl"))
      assert events =~ ~s("tool":"codex-review-requested")
      assert events =~ "direct-review-classification-request"
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator requests clean review for classification handoff despite stale local request event" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-classification-stale-local-request-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-review-classification-stale-local-request",
        identifier: "COD-205",
        title: "Analytics review rework",
        description: "Review feedback was classified as already resolved.",
        state: "Rework",
        branch_name: "orocsy/cod-205-analytics-miu-flow-instrumentation",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])
      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/cod-205-analytics-miu-flow-instrumentation"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nFeedback already resolved.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Resolve feedback"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          [
            "update-ref",
            "refs/remotes/origin/orocsy/cod-205-analytics-miu-flow-instrumentation",
            "HEAD"
          ],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          [
            "branch",
            "--set-upstream-to",
            "origin/orocsy/cod-205-analytics-miu-flow-instrumentation"
          ],
          cd: workspace,
          stderr_to_stdout: true
        )

      {head_sha, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      head_sha = String.trim(head_sha)

      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(state_dir)
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(state_dir, "review-feedback-classified.json"),
        Jason.encode!(
          %{
            "checkpoint" => "review-feedback-classified",
            "issue" => "COD-205",
            "pr" => 55,
            "head" => head_sha,
            "branch" => "orocsy/cod-205-analytics-miu-flow-instrumentation",
            "classification" => "already_resolved_in_current_head",
            "feedback" => [
              %{
                "path" => "src/app/api/swipes/handler.ts",
                "line" => 167,
                "classification" => "stale_resolved",
                "reason" => "The current head already includes the review fix."
              }
            ],
            "code_edit" => "none",
            "validation" => "not_run_no_code_change",
            "push" => "not_run_no_code_change",
            "review_request" => "not_requested_no_code_change"
          },
          pretty: true
        ) <> "\n"
      )

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event":"tool.finished","status":"passed","tool":"codex-review-requested","ts":"2026-05-18T11:22:00Z","mode":"old-request"}\n)
      )

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 55,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/55",
                 "head" => %{
                   "sha" => head_sha,
                   "ref" => "orocsy/cod-205-analytics-miu-flow-instrumentation"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/55/comments" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/55/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/55/comments?") ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      parent = self()

      Application.put_env(:symphony_elixir, :github_api_post_runner, fn endpoint, fields ->
        send(parent, {:github_post, endpoint, fields})
        {:ok, %{"id" => 789, "body" => fields["body"]}}
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => head_sha,
                 "reviewThreads" => %{
                   "nodes" => [],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_api_post_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert {:blocked, :review_pending} =
               Orchestrator.complete_review_classification_handoff_for_test(issue)

      assert_receive {:github_post, "repos/acme/nutribuddy/issues/55/comments", %{"body" => body}}
      assert body =~ "@codex review"
      assert body =~ "classified the current PR feedback as already resolved"
      assert body =~ String.slice(head_sha, 0, 10)

      events = File.read!(Path.join(event_dir, "events.jsonl"))
      assert events =~ "old-request"
      assert events =~ "direct-review-classification-request"
    after
      File.rm_rf(test_root)
    end
  end

  test "no-code review classification handoff does not complete dirty integration PR" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-classification-dirty-integration-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-review-classification-dirty-integration",
        identifier: "COD-208",
        title: "Analytics Integration Check And Final PR Handoff",
        description: """
        ## Ticket Type
        integration-check

        ## Integration Branch
        orocsy/feature-analytics-observability-integration
        """,
        state: "Rework",
        branch_name: "orocsy/feature-analytics-observability-integration",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])
      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/feature-analytics-observability-integration"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(
        Path.join(workspace, "README.md"),
        "# Test\n\nReview feedback already resolved.\n"
      )

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Resolve review feedback"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          [
            "update-ref",
            "refs/remotes/origin/orocsy/feature-analytics-observability-integration",
            "HEAD"
          ],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          [
            "branch",
            "--set-upstream-to",
            "origin/orocsy/feature-analytics-observability-integration"
          ],
          cd: workspace,
          stderr_to_stdout: true
        )

      {head_sha, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      head_sha = String.trim(head_sha)

      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)

      File.write!(
        Path.join(state_dir, "review-feedback-classified.json"),
        Jason.encode!(
          %{
            "checkpoint" => "review-feedback-classified",
            "issue" => "COD-208",
            "pr" => 58,
            "head" => head_sha,
            "branch" => "orocsy/feature-analytics-observability-integration",
            "classification" => "already_resolved_in_current_head",
            "feedback" => [
              %{
                "path" => "src/app/api/cards/route.ts",
                "line" => 44,
                "classification" => "stale_resolved",
                "reason" => "Current head already includes the review fix."
              }
            ],
            "code_edit" => "none",
            "validation" => "not_run_no_code_change",
            "push" => "not_run_no_code_change",
            "review_request" => "not_requested_no_code_change"
          },
          pretty: true
        ) <> "\n"
      )

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 58,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/58",
                 "head" => %{
                   "sha" => head_sha,
                   "ref" => "orocsy/feature-analytics-observability-integration"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/58" ->
            {:ok,
             %{
               "number" => 58,
               "html_url" => "https://github.com/acme/nutribuddy/pull/58",
               "head" => %{
                 "sha" => head_sha,
                 "ref" => "orocsy/feature-analytics-observability-integration"
               },
               "mergeable" => false,
               "mergeable_state" => "dirty"
             }}

          endpoint == "repos/acme/nutribuddy/pulls/58/comments" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/58/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/58/comments?") ->
            {:ok,
             [
               %{
                 "body" => "@codex review",
                 "created_at" => "2026-05-24T05:00:00Z"
               },
               %{
                 "body" => "Codex Review: Didn't find any major issues.",
                 "created_at" => "2026-05-24T05:05:00Z",
                 "user" => %{"login" => "chatgpt-codex-connector[bot]", "type" => "Bot"}
               }
             ]}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => head_sha,
                 "reviewThreads" => %{
                   "nodes" => [],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert :not_ready = Orchestrator.complete_review_classification_handoff_for_test(issue)

      refute_receive {:memory_tracker_state_update, "issue-review-classification-dirty-integration", "Human Review"},
                     50
    after
      File.rm_rf(test_root)
    end
  end

  test "no-code review classification handoff requires current workspace head" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-classification-current-head-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Rework"],
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"],
        review_monitor_rework_state: "Rework"
      )

      issue = %Issue{
        id: "issue-review-classification-current-head",
        identifier: "COD-205",
        title: "Analytics review rework",
        description: "Review feedback was classified as already resolved.",
        state: "Rework",
        branch_name: "orocsy/cod-205-analytics-miu-flow-instrumentation",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])
      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {stale_head, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      stale_head = String.trim(stale_head)

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/cod-205-analytics-miu-flow-instrumentation"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nFresh review feedback arrived.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Advance head"], cd: workspace, stderr_to_stdout: true)

      {current_head, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      current_head = String.trim(current_head)
      assert stale_head != current_head

      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(%{"mode" => "review_rework"}, pretty: true) <> "\n"
      )

      classification_path = Path.join(state_dir, "review-feedback-classified.json")

      stale_classification = %{
        "checkpoint" => "review-feedback-classified",
        "issue" => "COD-205",
        "pr" => 55,
        "head" => stale_head,
        "branch" => "orocsy/cod-205-analytics-miu-flow-instrumentation",
        "classification" => "already_resolved_in_current_head",
        "feedback" => [
          %{
            "path" => "src/app/api/swipes/handler.ts",
            "line" => 167,
            "classification" => "stale_resolved",
            "reason" => "Older feedback was resolved before the current head."
          }
        ],
        "code_edit" => "none",
        "validation" => "not_run_no_code_change",
        "push" => "not_run_no_code_change",
        "review_request" => "not_requested_no_code_change"
      }

      File.write!(classification_path, Jason.encode!(stale_classification, pretty: true) <> "\n")

      refute AgentRunner.review_classification_handoff_stop_for_test(workspace)
      assert :not_ready = Orchestrator.complete_review_classification_handoff_for_test(issue)

      File.write!(
        classification_path,
        Jason.encode!(Map.put(stale_classification, "head", current_head), pretty: true) <> "\n"
      )

      File.write!(Path.join(workspace, "uncommitted-review-fix.txt"), "pending edit\n")

      refute AgentRunner.review_classification_handoff_stop_for_test(workspace)
      assert :not_ready = Orchestrator.complete_review_classification_handoff_for_test(issue)

      File.rm!(Path.join(workspace, "uncommitted-review-fix.txt"))

      assert AgentRunner.review_classification_handoff_stop_for_test(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator pauses pushed handoff when local handoff already requested review" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-direct-pushed-handoff-local-review-request-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue =
        runtime_handoff_issue(%Issue{
          id: "issue-direct-handoff-local-review-request",
          identifier: "MT-254",
          title: "Await locally requested review",
          description: "The worker already pushed and requested a fresh review.",
          state: "Rework",
          branch_name: "orocsy/mt-254",
          labels: []
        })

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-254"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nPushed review fix.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Push review fix"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-254", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-254"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {handoff_sha, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      handoff_sha = String.trim(handoff_sha)
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "tool.finished", "status": "passed", "tool": "github-pr-created-and-codex-review-requested", "ts": "2026-05-18T11:22:00Z"}\n)
      )

      issue_runtime_handoff_certificate!(workspace, issue)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 21,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/21",
                 "head" => %{"sha" => handoff_sha, "ref" => "orocsy/mt-254"}
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/21/comments" ->
            {:ok,
             [
               %{
                 "body" => "Old current-head feedback with no timestamp in REST payload.",
                 "commit_id" => handoff_sha,
                 "path" => "README.md",
                 "line" => 3,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/21#discussion"
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/21/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/21/comments?") ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => handoff_sha,
                 "reviewThreads" => %{
                   "nodes" => [
                     %{
                       "isResolved" => false,
                       "isOutdated" => false,
                       "comments" => %{
                         "nodes" => [
                           %{
                             "body" => "Old current-head feedback with no timestamp in GraphQL payload.",
                             "path" => "README.md",
                             "line" => 3,
                             "url" => "https://github.com/acme/nutribuddy/pull/21#discussion"
                           }
                         ]
                       }
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert {:blocked, :review_pending} = Orchestrator.complete_pushed_handoff_for_test(issue)

      refute_receive {:memory_tracker_state_update, "issue-direct-handoff-local-review-request", "Human Review"},
                     50
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator pauses pushed handoff while fresh Codex review request is pending" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-direct-pushed-handoff-review-pending-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue =
        runtime_handoff_issue(%Issue{
          id: "issue-direct-handoff-review-pending",
          identifier: "MT-207",
          title: "Await fresh review",
          description: "Fresh Codex review was requested after the pushed fix.",
          state: "Rework",
          branch_name: "orocsy/mt-207",
          labels: []
        })

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-207"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nPushed review fix.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Push review fix"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-207", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-207"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {handoff_sha, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      handoff_sha = String.trim(handoff_sha)
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "focused validation passed", "ts": "2026-05-15T09:23:00Z"}\n)
      )

      issue_runtime_handoff_certificate!(workspace, issue)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 3,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/3",
                 "head" => %{"sha" => handoff_sha, "ref" => "orocsy/mt-207"}
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/3/comments" ->
            {:ok,
             [
               %{
                 "body" => "Old current-head feedback before the fresh review request.",
                 "commit_id" => handoff_sha,
                 "path" => "README.md",
                 "line" => 3,
                 "created_at" => "2026-05-15T09:20:00Z",
                 "html_url" => "https://github.com/acme/nutribuddy/pull/3#discussion"
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/3/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/3/comments?") ->
            {:ok,
             [
               %{
                 "body" => "@codex review\n\nFresh review requested after #{handoff_sha}.",
                 "created_at" => "2026-05-15T09:24:37Z",
                 "html_url" => "https://github.com/acme/nutribuddy/pull/3#issuecomment"
               }
             ]}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => handoff_sha,
                 "reviewThreads" => %{
                   "nodes" => [
                     %{
                       "isResolved" => false,
                       "isOutdated" => false,
                       "comments" => %{
                         "nodes" => [
                           %{
                             "body" => "Old current-head feedback before the fresh review request.",
                             "path" => "README.md",
                             "line" => 3,
                             "createdAt" => "2026-05-15T09:20:00Z",
                             "url" => "https://github.com/acme/nutribuddy/pull/3#discussion"
                           }
                         ]
                       }
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert {:blocked, :review_pending} = Orchestrator.complete_pushed_handoff_for_test(issue)

      refute_receive {:memory_tracker_state_update, "issue-direct-handoff-review-pending", "Human Review"},
                     50
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator redispatches dirty integration handoff instead of waiting for review" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-direct-pushed-handoff-dirty-integration-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-direct-handoff-dirty-integration",
        identifier: "COD-199",
        title: "Auth Integration Check And Final PR Handoff",
        description: """
        ## Ticket Type
        integration-check

        ## Integration Branch
        orocsy/feature-auth-migration-integration

        ## Write Scope
        - Merge conflict resolution for the auth integration branch.
        """,
        state: "Rework",
        branch_name: "orocsy/feature-auth-migration-integration",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/feature-auth-migration-integration"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nPushed integration branch.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Push integration branch"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          ["update-ref", "refs/remotes/origin/orocsy/feature-auth-migration-integration", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd(
          "git",
          ["branch", "--set-upstream-to", "origin/orocsy/feature-auth-migration-integration"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {handoff_sha, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      handoff_sha = String.trim(handoff_sha)
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "focused validation passed", "ts": "2026-05-15T09:23:00Z"}\n)
      )

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 54,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/54",
                 "head" => %{
                   "sha" => handoff_sha,
                   "ref" => "orocsy/feature-auth-migration-integration"
                 }
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/54" ->
            {:ok,
             %{
               "number" => 54,
               "html_url" => "https://github.com/acme/nutribuddy/pull/54",
               "head" => %{
                 "sha" => handoff_sha,
                 "ref" => "orocsy/feature-auth-migration-integration"
               },
               "mergeable" => false,
               "mergeable_state" => "dirty"
             }}

          endpoint == "repos/acme/nutribuddy/pulls/54/comments" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/54/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/54/comments?") ->
            {:ok,
             [
               %{
                 "body" => "@codex review\n\nFresh review requested after #{handoff_sha}.",
                 "created_at" => "2026-05-15T09:24:37Z",
                 "html_url" => "https://github.com/acme/nutribuddy/pull/54#issuecomment"
               }
             ]}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => handoff_sha,
                 "reviewThreads" => %{
                   "nodes" => [],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert :not_ready = Orchestrator.complete_pushed_handoff_for_test(issue)

      refute_receive {:memory_tracker_state_update, "issue-direct-handoff-dirty-integration", "Human Review"},
                     50
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator requests review for clean pushed handoff without redispatching a worker" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-direct-pushed-handoff-clean-review-missing-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue =
        runtime_handoff_issue(%Issue{
          id: "issue-direct-clean-handoff-review-missing",
          identifier: "MT-252",
          title: "Require clean review",
          description: "No Codex review request or clean result exists yet.",
          state: "Rework",
          branch_name: "orocsy/mt-252",
          labels: []
        })

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-252"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nPushed clean handoff.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Push clean handoff"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-252", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-252"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {handoff_sha, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      handoff_sha = String.trim(handoff_sha)
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "focused validation passed", "ts": "2026-05-17T23:08:00Z"}\n)
      )

      issue_runtime_handoff_certificate!(workspace, issue)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 18,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/18",
                 "head" => %{"sha" => handoff_sha, "ref" => "orocsy/mt-252"}
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/18/comments" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/18/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/18/comments?") ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      parent = self()

      Application.put_env(:symphony_elixir, :github_api_post_runner, fn endpoint, fields ->
        send(parent, {:github_post, endpoint, fields})
        {:ok, %{"id" => 123, "body" => fields["body"]}}
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => handoff_sha,
                 "reviewThreads" => %{
                   "nodes" => [],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_api_post_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert {:blocked, :review_pending} = Orchestrator.complete_pushed_handoff_for_test(issue)

      assert_receive {:github_post, "repos/acme/nutribuddy/issues/18/comments", %{"body" => body}}
      short_sha = String.slice(handoff_sha, 0, 10)
      assert body =~ "@codex review"
      assert body =~ short_sha

      assert_receive {:memory_tracker_comment, "issue-direct-clean-handoff-review-missing", tracker_body}

      assert tracker_body =~ "without starting another Codex worker"
      assert tracker_body =~ short_sha

      refute_receive {:memory_tracker_state_update, "issue-direct-clean-handoff-review-missing", "Human Review"},
                     50

      events = File.read!(Path.join(event_dir, "events.jsonl"))
      assert events =~ ~s("tool":"codex-review-requested")
      assert events =~ "direct-pushed-review-request"
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator blocks clean pushed handoff when clean review lookup fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-direct-pushed-handoff-clean-review-lookup-fails-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue =
        runtime_handoff_issue(%Issue{
          id: "issue-direct-clean-handoff-review-lookup-fails",
          identifier: "MT-253",
          title: "Block on review lookup error",
          description: "GitHub comments lookup fails while checking clean review.",
          state: "Rework",
          branch_name: "orocsy/mt-253",
          labels: []
        })

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-253"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nPushed clean handoff.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Push clean handoff"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-253", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-253"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {handoff_sha, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      handoff_sha = String.trim(handoff_sha)
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "focused validation passed", "ts": "2026-05-17T23:15:00Z"}\n)
      )

      issue_runtime_handoff_certificate!(workspace, issue)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 19,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/19",
                 "head" => %{"sha" => handoff_sha, "ref" => "orocsy/mt-253"}
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/19/comments" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/19/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/19/comments?") ->
            {:error, :github_comments_unavailable}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => handoff_sha,
                 "reviewThreads" => %{
                   "nodes" => [],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert {:blocked, {:clean_codex_review_lookup_failed, {:error, _reason}}} =
               Orchestrator.complete_pushed_handoff_for_test(issue)

      refute_receive {:memory_tracker_state_update, "issue-direct-clean-handoff-review-lookup-fails", "Human Review"},
                     50
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator pauses clean pushed handoff while Codex review request is pending" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-direct-pushed-handoff-clean-review-pending-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue =
        runtime_handoff_issue(%Issue{
          id: "issue-direct-clean-handoff-review-pending",
          identifier: "MT-251",
          title: "Await clean review",
          description: "Fresh Codex review has no feedback yet.",
          state: "Rework",
          branch_name: "orocsy/mt-251",
          labels: []
        })

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["config", "user.email", "symphony@example.test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["config", "user.name", "Symphony Test"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["switch", "-c", "orocsy/mt-251"],
          cd: workspace,
          stderr_to_stdout: true
        )

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nPushed clean handoff.\n")

      {_output, 0} =
        System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)

      {_output, 0} =
        System.cmd("git", ["commit", "-m", "Push clean handoff"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-251", "HEAD"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {_output, 0} =
        System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-251"],
          cd: workspace,
          stderr_to_stdout: true
        )

      {handoff_sha, 0} =
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

      handoff_sha = String.trim(handoff_sha)
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "focused validation passed", "ts": "2026-05-17T22:52:00Z"}\n)
      )

      issue_runtime_handoff_certificate!(workspace, issue)

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 17,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/17",
                 "head" => %{"sha" => handoff_sha, "ref" => "orocsy/mt-251"}
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/17/comments" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/17/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/17/comments?") ->
            {:ok,
             [
               %{
                 "body" => "@codex review\n\nFresh review requested after #{handoff_sha}.",
                 "created_at" => "2026-05-17T22:52:41Z",
                 "html_url" => "https://github.com/acme/nutribuddy/pull/17#issuecomment"
               }
             ]}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => handoff_sha,
                 "reviewThreads" => %{
                   "nodes" => [],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert {:blocked, :review_pending} = Orchestrator.complete_pushed_handoff_for_test(issue)

      refute_receive {:memory_tracker_state_update, "issue-direct-clean-handoff-review-pending", "Human Review"},
                     50
    after
      File.rm_rf(test_root)
    end
  end

  test "prompt builder does not duplicate template-provided retry continuation guidance" do
    workflow_prompt =
      """
      Retry continuation:
      - This is retry attempt #\{{ attempt }}.
      Ticket {{ issue.identifier }}
      """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-202",
      title: "Continue autonomous ticket once",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-202",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "Retry continuation:"
    assert prompt =~ "retry attempt #2"
    assert prompt =~ "Ticket MT-202"
    refute prompt =~ "Resume from the current workspace state"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
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

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner routes remote review rework to a local preflight-capable worker" do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_api_runner)
      Application.delete_env(:symphony_elixir, :github_graphql_runner)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "~/.symphony-remote-workspaces",
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy",
      worker_ssh_hosts: ["worker-a"]
    )

    issue = %Issue{
      id: "issue-remote-review-preflight",
      identifier: "MT-REMOTE-REWORK",
      title: "Remote review rework needs preflight",
      description: "Current PR feedback should not run remotely without preflight context.",
      state: "Rework",
      branch_name: "orocsy/mt-remote-rework"
    }

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
          {:ok,
           [
             %{
               "number" => 4,
               "html_url" => "https://github.com/acme/nutribuddy/pull/4",
               "head" => %{"sha" => "remote-review-head", "ref" => "orocsy/mt-remote-rework"}
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/4/comments" ->
          {:ok, []}

        endpoint == "repos/acme/nutribuddy/pulls/4/reviews" ->
          {:ok, []}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
      {:ok,
       %{
         "data" => %{
           "repository" => %{
             "pullRequest" => %{
               "headRefOid" => "remote-review-head",
               "reviewThreads" => %{
                 "nodes" => [
                   %{
                     "isResolved" => false,
                     "isOutdated" => false,
                     "comments" => %{
                       "nodes" => [
                         %{
                           "body" => "Fix this before handoff.",
                           "path" => "README.md",
                           "line" => 3,
                           "url" => "https://github.com/acme/nutribuddy/pull/4#discussion"
                         }
                       ]
                     }
                   }
                 ],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }
       }}
    end)

    assert AgentRunner.selected_worker_host_for_test(issue, "worker-a") == nil
  end

  test "agent runner routes structured runtime contracts to local controller-capable worker" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "~/.symphony-remote-workspaces",
      worker_ssh_hosts: ["worker-a"]
    )

    issue = %Issue{
      id: "issue-structured-local-controller",
      identifier: "MT-STRUCTURED-LOCAL",
      title: "Structured local controller",
      state: "In Progress",
      branch_name: "orocsy/generated-child",
      description: """
      ## Runtime Contract

      ```yaml
      schema_version: 1
      ticket_type: implementation
      base_branch: main
      integration_branch: orocsy/structured-integration
      dependencies: []
      mius:
        - id: MT-STRUCTURED-LOCAL-MIU-1
          write_scope:
            - README.md
          validations:
            - mix test
      final_validations:
        - mix test
      review:
        authority: github_codex
        require_current_head: true
      ```
      """
    }

    assert AgentRunner.selected_worker_host_for_test(issue, "worker-a") == nil
  end

  test "agent runner refreshes Linear before processing a pending runtime transition" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-transition-refresh-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/events"))

    File.write!(
      Path.join(workspace, ".orocsy/delivery/events/events.jsonl"),
      Jason.encode!(%{
        "event" => "miu.completion_requested",
        "event_id" => "request-current-contract",
        "status" => "requested"
      }) <> "\n"
    )

    stale_issue = %Issue{
      id: "issue-runtime-transition-refresh",
      identifier: "MT-STRUCTURED-REFRESH",
      title: "Refresh runtime transition",
      state: "In Progress",
      description: "old contract"
    }

    current_issue = %{stale_issue | description: "current contract"}
    test_pid = self()

    fetcher = fn ["issue-runtime-transition-refresh"] ->
      send(test_pid, :runtime_transition_issue_refreshed)
      {:ok, [current_issue]}
    end

    try do
      assert {:ok, ^current_issue} =
               AgentRunner.current_issue_for_runtime_transition_for_test(workspace, stale_issue, fetcher)

      assert_receive :runtime_transition_issue_refreshed
    after
      File.rm_rf(workspace)
    end
  end

  test "agent runner reconciles a pending certified transition before opening another worker" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pending-transition-recovery-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/events"))

    File.write!(
      Path.join(workspace, ".orocsy/delivery/events/events.jsonl"),
      Jason.encode!(%{
        "event" => "miu.completion_requested",
        "event_id" => "request-survived-interruption",
        "status" => "requested"
      }) <> "\n"
    )

    issue = %Issue{
      id: "issue-pending-transition-recovery",
      identifier: "MT-PENDING-TRANSITION",
      title: "Recover pending transition",
      state: "In Progress"
    }

    test_pid = self()

    processor = fn ^workspace, ^issue, issue_state_fetcher ->
      send(test_pid, {:pending_transition_reconciled, issue_state_fetcher})
      {{:ok, %{"event" => "miu.completed"}}, :none}
    end

    try do
      assert {:stop, {{:ok, %{"event" => "miu.completed"}}, :none}} =
               AgentRunner.reconcile_pending_runtime_transition_for_test(
                 workspace,
                 issue,
                 runtime_transition_processor: processor
               )

      assert_receive {:pending_transition_reconciled, issue_state_fetcher}
      assert is_function(issue_state_fetcher, 1)
    after
      File.rm_rf(workspace)
    end
  end

  test "controller-owned browser handoff reconciles its pending request before parking" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-controller-parked-transition-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/events"))

    File.write!(
      Path.join(workspace, ".orocsy/delivery/events/events.jsonl"),
      Jason.encode!(%{
        "event" => "handoff.requested",
        "event_id" => "request-before-browser-park",
        "status" => "requested"
      }) <> "\n"
    )

    issue = %Issue{
      id: "issue-controller-parked-transition",
      identifier: "MT-CONTROLLER-PARK",
      title: "Controller parked transition",
      state: "Rework"
    }

    test_pid = self()

    try do
      assert :ok =
               AgentRunner.reconcile_controller_handoff_after_park_for_test(
                 "playwright_browser_correction_requires_runtime_controller_handoff",
                 workspace,
                 issue,
                 runtime_transition_processor: fn _, _, _ ->
                   send(test_pid, :controller_park_transition_processed)
                   {:none, {:ok, %{"event" => "handoff.ready"}}}
                 end
               )

      assert_receive :controller_park_transition_processed
    after
      File.rm_rf(workspace)
    end
  end

  test "agent runner stops when startup transition controllers error or block" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pending-transition-stop-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/events"))

    File.write!(
      Path.join(workspace, ".orocsy/delivery/events/events.jsonl"),
      Jason.encode!(%{
        "event" => "miu.completion_requested",
        "event_id" => "request-controller-stop",
        "status" => "requested"
      }) <> "\n"
    )

    issue = %Issue{id: "issue-controller-stop", identifier: "MT-CONTROLLER-STOP", state: "In Progress"}

    try do
      error_result = {{:error, :correction_write_failed}, :none}

      assert {:stop, ^error_result} =
               AgentRunner.reconcile_pending_runtime_transition_for_test(
                 workspace,
                 issue,
                 runtime_transition_processor: fn _, _, _ -> error_result end
               )

      blocked_result = {{:blocked, :retry_budget_exhausted}, :none}

      assert {:stop, ^blocked_result} =
               AgentRunner.reconcile_pending_runtime_transition_for_test(
                 workspace,
                 issue,
                 runtime_transition_processor: fn _, _, _ -> blocked_result end
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "agent runner degrades remote review inspection failures to no feedback" do
    write_workflow_file!(Workflow.workflow_file_path(),
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy"
    )

    issue = %Issue{
      id: "issue-remote-review-error",
      identifier: "MT-REMOTE-REVIEW-ERROR",
      title: "Remote review inspection error",
      description: "Remote dispatch should not block on transient GitHub errors.",
      state: "In Progress",
      branch_name: "orocsy/mt-remote-review-error"
    }

    Application.put_env(:symphony_elixir, :github_api_runner, fn _endpoint ->
      {:error, :network_unavailable}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

    assert {:ok, false} = AgentRunner.remote_worker_review_feedback_for_test(issue)
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
      assert Enum.at(turn_texts, 1) =~ "only an external handoff step failed"
      assert Enum.at(turn_texts, 1) =~ "do not redo product code"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops after fresh implementation first checkpoint instead of continuing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-fresh-checkpoint-stop-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fresh-stop"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fresh-stop-1"}}}'
            git init -b main >/dev/null 2>&1
            git config user.email test@example.com
            git config user.name "Test User"
            mkdir -p src/app .orocsy/delivery/events
            printf '%s\\n' 'export default function Page() { return "baseline"; }' > src/app/page.tsx
            git add src/app/page.tsx >/dev/null 2>&1
            git commit -m baseline >/dev/null 2>&1
            git update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1
            printf '%s\\n' 'export default function Page() { return "checkpoint"; }' > src/app/page.tsx
            printf '%s\\n' '{"event":"tool.finished","status":"passed","tool":"technical-miu-trace"}' >> .orocsy/delivery/events/events.jsonl
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fresh-stop-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        send(parent, {:issue_state_fetch, :unexpected})

        {:ok,
         [
           %Issue{
             id: "issue-fresh-stop",
             identifier: "MT-FRESH-STOP",
             title: "Fresh checkpoint stop",
             description: "Still active after first turn",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-fresh-stop",
        identifier: "MT-FRESH-STOP",
        title: "Fresh checkpoint stop",
        description: "Stop after technical-miu-trace",
        state: "In Progress",
        url: "https://example.org/issues/MT-FRESH-STOP",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      refute_receive {:issue_state_fetch, :unexpected}, 100

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      turn_start_count =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.count(&(&1["method"] == "turn/start"))

      assert turn_start_count == 1
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner does not stop for fresh implementation trace without file progress" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-trace-only-no-stop-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      turn_count=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        id="$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')"
        case "$line" in
          *'"method":"initialize"'*)
            printf '{"id":%s,"result":{}}\\n' "$id"
            ;;
          *'"method":"thread/start"'*)
            printf '{"id":%s,"result":{"thread":{"id":"thread-fresh-trace-only"}}}\\n' "$id"
            ;;
          *'"method":"turn/start"'*)
            turn_count=$((turn_count + 1))
            printf '{"id":%s,"result":{"turn":{"id":"turn-fresh-trace-only-%s"}}}\\n' "$id" "$turn_count"
            if [ "$turn_count" -eq 1 ]; then
              mkdir -p .orocsy/delivery/events
              printf '%s\\n' '{"event":"tool.finished","status":"passed","tool":"technical-miu-trace"}' >> .orocsy/delivery/events/events.jsonl
            fi
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      parent = self()
      fetch_count = :counters.new(1, [])

      state_fetcher = fn [_issue_id] ->
        :counters.add(fetch_count, 1, 1)
        count = :counters.get(fetch_count, 1)
        send(parent, {:issue_state_fetch, count})

        state = if count == 1, do: "In Progress", else: "Done"

        {:ok,
         [
           %Issue{
             id: "issue-fresh-trace-only",
             identifier: "MT-FRESH-TRACE-ONLY",
             title: "Fresh trace-only should continue",
             description: "Trace-only event is not a checkpoint",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-fresh-trace-only",
        identifier: "MT-FRESH-TRACE-ONLY",
        title: "Fresh trace-only should continue",
        description: "Do not stop after technical-miu-trace without file progress",
        state: "In Progress",
        url: "https://example.org/issues/MT-FRESH-TRACE-ONLY",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}, 100
      assert_receive {:issue_state_fetch, 2}, 100

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      turn_start_count =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.count(&(&1["method"] == "turn/start"))

      assert turn_start_count == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops after fresh implementation checkpoint on later turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-fresh-checkpoint-late-stop-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      turn_count=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        id="$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')"
        case "$line" in
          *'"method":"initialize"'*)
            printf '{"id":%s,"result":{}}\\n' "$id"
            ;;
          *'"method":"thread/start"'*)
            printf '{"id":%s,"result":{"thread":{"id":"thread-fresh-late-stop"}}}\\n' "$id"
            ;;
          *'"method":"turn/start"'*)
            turn_count=$((turn_count + 1))
            printf '{"id":%s,"result":{"turn":{"id":"turn-fresh-late-stop-%s"}}}\\n' "$id" "$turn_count"
            if [ "$turn_count" -eq 2 ]; then
              git init -b main >/dev/null 2>&1
              git config user.email test@example.com
              git config user.name "Test User"
              mkdir -p src/app .orocsy/delivery/events
              printf '%s\\n' 'export default function Page() { return "baseline"; }' > src/app/page.tsx
              git add src/app/page.tsx >/dev/null 2>&1
              git commit -m baseline >/dev/null 2>&1
              git update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1
              printf '%s\\n' 'export default function Page() { return "checkpoint"; }' > src/app/page.tsx
              printf '%s\\n' '{"event":"tool.finished","status":"passed","tool":"technical-miu-trace"}' >> .orocsy/delivery/events/events.jsonl
            fi
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        send(parent, {:issue_state_fetch, :active})

        {:ok,
         [
           %Issue{
             id: "issue-fresh-late-stop",
             identifier: "MT-FRESH-LATE-STOP",
             title: "Fresh late checkpoint stop",
             description: "Still active after turn",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-fresh-late-stop",
        identifier: "MT-FRESH-LATE-STOP",
        title: "Fresh late checkpoint stop",
        description: "Stop after technical-miu-trace on a later turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-FRESH-LATE-STOP",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, :active}, 100
      refute_receive {:issue_state_fetch, :active}, 100

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      turn_start_count =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.count(&(&1["method"] == "turn/start"))

      assert turn_start_count == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops after worker creates open blocking correction" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-blocking-correction-stop-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-blocking"}}}'
            ;;
          4)
            mkdir -p .orocsy/delivery/inbox
            cat > .orocsy/delivery/inbox/correction_worker_blocked.json <<'JSON'
      {"correction_id":"correction_worker_blocked","status":"open","next_action":"block","resolved_at":null,"summary":"validation blocked"}
      JSON
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-blocking-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-blocking-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        send(parent, {:issue_state_fetch, :unexpected})

        {:ok,
         [
           %Issue{
             id: "issue-blocking-correction-stop",
             identifier: "MT-248",
             title: "Still active",
             description: "Would continue without blocker awareness.",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-blocking-correction-stop",
        identifier: "MT-248",
        title: "Stop after blocker",
        description: "Worker creates an open Orocsy correction.",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      refute_receive {:issue_state_fetch, :unexpected}, 100

      trace = File.read!(trace_file)
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1

      workspace = Path.join(workspace_root, "MT-248")
      assert Workspace.blocking_correction_in_workspace?(workspace)
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner does not stop review rework for an uncertified generic gate" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-handoff-stop-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      origin_repo = Path.join(test_root, "origin.git")
      codex_binary = Path.join(test_root, "fake-codex")
      setup_script = Path.join(test_root, "setup-workspace.sh")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(test_root)
      {_output, 0} = System.cmd("git", ["init", "--bare", origin_repo], stderr_to_stdout: true)

      File.write!(setup_script, """
      #!/bin/sh
      set -eu
      git init -b main
      git config user.email symphony@example.test
      git config user.name "Symphony Test"
      printf '# Test\\n' > README.md
      git add README.md
      git commit -m initial
      git switch -c orocsy/mt-249
      printf '# Test\\n\\nReady.\\n' > README.md
      git add README.md
      git commit -m 'Add review handoff'
      git remote add origin '#{origin_repo}'
      git push -u origin orocsy/mt-249
      printf '.orocsy/\\n' >> .git/info/exclude
      mkdir -p .orocsy/delivery/events
      printf '%s\\n' '{"event": "gate.post-miu", "status": "passed", "step": "focused validation passed", "ts": "2026-05-15T09:51:00Z"}' > .orocsy/delivery/events/events.jsonl
      """)

      File.chmod!(setup_script, 0o755)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-handoff"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-handoff-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn ->
        System.delete_env("SYMP_TEST_CODEx_TRACE")
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: setup_script,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3,
        tracker_active_states: ["Todo", "In Progress", "Rework"],
        review_monitor_enabled: true,
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review", "Rework"]
      )

      pushed_handoff_sha = fn ->
        workspace = Path.join(workspace_root, "MT-249")

        {head_sha, 0} =
          System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)

        String.trim(head_sha)
      end

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            head_sha = pushed_handoff_sha.()

            {:ok,
             [
               %{
                 "number" => 3,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/3",
                 "head" => %{"sha" => head_sha, "ref" => "orocsy/mt-249"}
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/3/comments" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/3/reviews" ->
            {:ok, []}

          String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/3/comments?") ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      Application.put_env(:symphony_elixir, :github_graphql_runner, fn _query, _variables ->
        head_sha = pushed_handoff_sha.()

        {:ok,
         %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => head_sha,
                 "reviewThreads" => %{
                   "nodes" => [
                     %{
                       "isResolved" => false,
                       "isOutdated" => false,
                       "comments" => %{
                         "nodes" => [
                           %{
                             "author" => %{"login" => "codex"},
                             "body" => "Fix current review feedback.",
                             "path" => "README.md",
                             "line" => 3,
                             "originalLine" => 3,
                             "createdAt" => "2026-05-15T09:40:00Z",
                             "outdated" => false,
                             "url" => "https://github.com/acme/nutribuddy/pull/3#discussion"
                           }
                         ]
                       }
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end)

      parent = self()

      state_fetcher = fn [_issue_id] ->
        send(parent, :issue_state_fetch)

        {:ok,
         [
           %Issue{
             id: "issue-review-handoff-stop",
             identifier: "MT-249",
             title: "Stop after pushed review handoff",
             description: "Still active after a review handoff.",
             state: "Rework",
             branch_name: "orocsy/mt-249"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-handoff-stop",
        identifier: "MT-249",
        title: "Stop after pushed review handoff",
        description: "Fix current review feedback.",
        state: "Rework",
        branch_name: "orocsy/mt-249",
        url: "https://example.org/issues/MT-249",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive :issue_state_fetch

      trace = File.read!(trace_file)
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 3
      assert trace =~ "Runtime dispatch preflight:"
      assert trace =~ "Review rework execution contract:"
      assert trace =~ "Fix current review feedback."
      refute trace =~ "Minimal review handoff mode:"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      Application.delete_env(:symphony_elixir, :github_api_runner)
      Application.delete_env(:symphony_elixir, :github_graphql_runner)
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "granular" => %{
                       "sandbox_approval" => true,
                       "rules" => false,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "granular" => %{
                       "sandbox_approval" => true,
                       "rules" => false,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --config 'model=\"gpt-5.5\"' app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--config model=\"gpt-5.5\" app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "pending review correction stays parked while fresh Codex review request is pending" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pending-review-correction-pending-#{System.unique_integer([:positive])}"
      )

    try do
      {issue, workspace, correction} =
        pending_review_correction_fixture(test_root, "issue-pending-review-correction-pending")

      head_sha = "748a56f4221ed839a23b626c1681a9d02f718ac7"
      feedback_at = iso_seconds(-300)
      request_at = iso_seconds(-30)

      install_pending_review_github_fixture(head_sha,
        pull_comments: [review_thread_payload(head_sha, feedback_at)],
        issue_comments: [codex_review_request_payload(request_at)]
      )

      state = empty_orchestrator_state()
      assert Orchestrator.rescue_open_corrections_for_test([issue], state) == state

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      parked = correction_path |> File.read!() |> Jason.decode!()
      assert parked["status"] == "open"
      assert Workspace.blocking_correction_in_workspace?(workspace)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)

      refute_receive {:memory_tracker_state_update, "issue-pending-review-correction-pending", _state},
                     50

      refute_receive {:github_post, _endpoint, _fields}, 50
    after
      File.rm_rf(test_root)
    end
  end

  test "pending review source is not made actionable by incidental fix path prose" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pending-review-incidental-path-#{System.unique_integer([:positive])}"
      )

    try do
      {issue, workspace, correction} =
        pending_review_correction_fixture(
          test_root,
          "issue-pending-review-incidental-path",
          %{
            source: "github-codex-review",
            summary: "Wait for Codex review of the pushed fix in src/features/swipe/SwipeExperience.tsx",
            findings: [
              "The fix in src/features/swipe/SwipeExperience.tsx is pushed and the current-head review is pending."
            ],
            required_corrections: [
              "Wait for the Codex review result for the fix in src/features/swipe/SwipeExperience.tsx."
            ]
          }
        )

      head_sha = "748a56f4221ed839a23b626c1681a9d02f718ac7"
      request_at = iso_seconds(-30)

      install_pending_review_github_fixture(head_sha,
        issue_comments: [codex_review_request_payload(request_at)]
      )

      state = empty_orchestrator_state()
      assert Orchestrator.rescue_open_corrections_for_test([issue], state) == state

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      parked = correction_path |> File.read!() |> Jason.decode!()
      assert parked["status"] == "open"
      assert Workspace.blocking_correction_in_workspace?(workspace)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "continuation review-rework correction stays parked while external review is pending" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-continuation-review-correction-pending-#{System.unique_integer([:positive])}"
      )

    try do
      {issue, workspace, correction} =
        pending_review_correction_fixture(
          test_root,
          "issue-continuation-review-correction-pending",
          %{
            source: "continuation-review-rework",
            summary: "External review result is still pending for pushed clean head",
            findings: [
              "Branch is clean and synced to origin at 6c42573; latest automated review still targets an older commit."
            ],
            required_corrections: [
              "Retry/monitor PR state until external review posts for commit 6c42573; then dispatch only if new current-head feedback exists."
            ]
          }
        )

      head_sha = "6c425739b51d7ffdde65e3469e8d2f38421d1736"
      request_at = iso_seconds(-30)

      install_pending_review_github_fixture(head_sha,
        issue_comments: [codex_review_request_payload(request_at)]
      )

      state = empty_orchestrator_state()
      assert Orchestrator.rescue_open_corrections_for_test([issue], state) == state

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      parked = correction_path |> File.read!() |> Jason.decode!()
      assert parked["status"] == "open"
      assert Workspace.blocking_correction_in_workspace?(workspace)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)

      refute_receive {:memory_tracker_state_update, "issue-continuation-review-correction-pending", _state},
                     50

      refute_receive {:github_post, _endpoint, _fields}, 50
    after
      File.rm_rf(test_root)
    end
  end

  test "review rework continuation correction stays parked while provider result is pending" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-continuation-correction-pending-#{System.unique_integer([:positive])}"
      )

    try do
      {issue, workspace, correction} =
        pending_review_correction_fixture(
          test_root,
          "issue-review-rework-continuation-correction-pending",
          %{
            source: "review-rework-continuation",
            summary: "Provider result pending after pushed fix",
            findings: [
              "Branch is clean and synced to origin at fbd1f7a; latest automated result still targets an older commit."
            ],
            required_corrections: [
              "Wait for provider result for fbd1f7a; retry state inspection later before moving tracker state."
            ]
          }
        )

      head_sha = "fbd1f7ace58e2c60ce89589db38e652c4286834e"
      request_at = iso_seconds(-30)

      install_pending_review_github_fixture(head_sha,
        issue_comments: [codex_review_request_payload(request_at)]
      )

      state = empty_orchestrator_state()
      assert Orchestrator.rescue_open_corrections_for_test([issue], state) == state

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      parked = correction_path |> File.read!() |> Jason.decode!()
      assert parked["status"] == "open"
      assert Workspace.blocking_correction_in_workspace?(workspace)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)

      refute_receive {:memory_tracker_state_update, "issue-review-rework-continuation-correction-pending", _state},
                     50

      refute_receive {:github_post, _endpoint, _fields}, 50
    after
      File.rm_rf(test_root)
    end
  end

  test "pending review correction resolves to rework when fresh current-head feedback arrives" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pending-review-correction-feedback-#{System.unique_integer([:positive])}"
      )

    try do
      {issue, workspace, correction} =
        pending_review_correction_fixture(test_root, "issue-pending-review-correction-feedback")

      head_sha = "748a56f4221ed839a23b626c1681a9d02f718ac7"
      request_at = iso_seconds(-300)
      feedback_at = iso_seconds(-30)

      install_pending_review_github_fixture(head_sha,
        pull_comments: [review_thread_payload(head_sha, feedback_at)],
        issue_comments: [codex_review_request_payload(request_at)]
      )

      state = empty_orchestrator_state()
      assert Orchestrator.rescue_open_corrections_for_test([issue], state) == state

      assert_receive {:memory_tracker_state_update, "issue-pending-review-correction-feedback", "Rework"}

      assert_receive {:memory_tracker_comment, "issue-pending-review-correction-feedback", body}
      assert body =~ "fresh current-head feedback"
      assert body =~ "pull/7"

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      resolved = correction_path |> File.read!() |> Jason.decode!()
      assert resolved["status"] == "resolved"
      assert resolved["resolution_summary"] =~ "review_rework_needed"
      refute Workspace.blocking_correction_in_workspace?(workspace)
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "pending review correction resolves clean review to review handoff state" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pending-review-correction-clean-#{System.unique_integer([:positive])}"
      )

    try do
      {issue, workspace, correction} =
        pending_review_correction_fixture(test_root, "issue-pending-review-correction-clean")

      head_sha = "748a56f4221ed839a23b626c1681a9d02f718ac7"
      request_at = iso_seconds(-300)
      clean_at = iso_seconds(-30)

      install_pending_review_github_fixture(head_sha,
        pull_comments: [],
        issue_comments: [
          codex_review_request_payload(request_at),
          clean_codex_review_payload(clean_at)
        ]
      )

      state = empty_orchestrator_state()
      assert Orchestrator.rescue_open_corrections_for_test([issue], state) == state

      assert_receive {:memory_tracker_state_update, "issue-pending-review-correction-clean", "Human Review"}

      assert_receive {:memory_tracker_comment, "issue-pending-review-correction-clean", body}
      assert body =~ "clean current review"
      assert body =~ "Human Review"

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      resolved = correction_path |> File.read!() |> Jason.decode!()
      assert resolved["status"] == "resolved"
      assert resolved["resolution_summary"] =~ "review_handoff_clean_after_pending_review"
      refute Workspace.blocking_correction_in_workspace?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "pending review correction re-requests stale Codex review without dispatching a worker" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pending-review-correction-stale-#{System.unique_integer([:positive])}"
      )

    try do
      Application.put_env(:symphony_elixir, :codex_review_request_stale_after_ms, 1)

      {issue, workspace, correction} =
        pending_review_correction_fixture(test_root, "issue-pending-review-correction-stale")

      head_sha = "748a56f4221ed839a23b626c1681a9d02f718ac7"
      feedback_at = iso_seconds(-30)
      request_at = iso_seconds(-10)

      install_pending_review_github_fixture(head_sha,
        pull_comments: [review_thread_payload(head_sha, feedback_at)],
        issue_comments: [codex_review_request_payload(request_at)]
      )

      state = empty_orchestrator_state()
      assert Orchestrator.rescue_open_corrections_for_test([issue], state) == state

      assert_receive {:github_post, "repos/acme/nutribuddy/issues/7/comments", %{"body" => "@codex review"}}

      assert_receive {:memory_tracker_comment, "issue-pending-review-correction-stale", body}
      assert body =~ "re-requested Codex review"

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      parked = correction_path |> File.read!() |> Jason.decode!()
      assert parked["status"] == "open"
      assert Workspace.blocking_correction_in_workspace?(workspace)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      Application.delete_env(:symphony_elixir, :codex_review_request_stale_after_ms)
      File.rm_rf(test_root)
    end
  end

  test "design document retry correction is dispatchable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-design-doc-retry-correction-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["In Progress"],
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-design-doc-retry-correction",
        identifier: "COD-273",
        title: "Design Source: Responsive Feature Surface Pack",
        state: "In Progress",
        branch_name: "orocsy/cod-273"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, _correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "controller.audit.incomplete-miu",
                 source_status: "failed",
                 summary: "COD-273 needs a retry because DESIGN.md is missing the state matrix.",
                 findings: [
                   "DESIGN.md lacks the Responsive Interaction State Matrix required by the issue brief."
                 ],
                 required_corrections: [
                   "Edit DESIGN.md and .codex/agentic/issue-briefs/COD-273.md, then run pnpm lint and record gate.post-miu evidence."
                 ],
                 next_action: "retry"
               })

      state = empty_orchestrator_state()

      assert Workspace.blocking_correction_in_workspace?(workspace)
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    after
      File.rm_rf(test_root)
    end
  end

  test "actionable GitHub Codex review correction remains open and dispatchable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-actionable-github-review-correction-#{System.unique_integer([:positive])}"
      )

    try do
      {issue, workspace, correction} =
        pending_review_correction_fixture(
          test_root,
          "issue-actionable-github-review-correction",
          %{
            source: "github-codex-review",
            summary: "Preserve focus when the mobile sheet becomes desktop inline setup",
            findings: [
              "src/components/ui/bottom-sheet.tsx:50 restores focus to a hidden close button."
            ],
            required_corrections: [
              "Add a null guard in src/components/ui/bottom-sheet.tsx."
            ]
          }
        )

      head_sha = "748a56f4221ed839a23b626c1681a9d02f718ac7"
      request_at = iso_seconds(-300)
      feedback_at = iso_seconds(-30)

      install_pending_review_github_fixture(head_sha,
        pull_comments: [review_thread_payload(head_sha, feedback_at)],
        issue_comments: [codex_review_request_payload(request_at)]
      )

      state = empty_orchestrator_state()
      assert Orchestrator.rescue_open_corrections_for_test([issue], state) == state

      correction_path = Path.join(workspace, correction["artifacts"]["json"])
      actionable = correction_path |> File.read!() |> Jason.decode!()
      assert actionable["status"] == "open"
      assert Workspace.blocking_correction_in_workspace?(workspace)
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)

      refute_receive {:memory_tracker_state_update, "issue-actionable-github-review-correction", _state},
                     50
    after
      File.rm_rf(test_root)
    end
  end

  test "all standard standalone code-change verbs are explicit structured requests" do
    for verb <- ["Add", "Delete", "Edit", "Fix", "Change", "Modify", "Remove", "Rename", "Replace", "Update", "Implement"] do
      assert SymphonyElixir.RescueSupervisor.explicit_structured_code_change_request_for_test(%{
               "required_corrections" => [
                 "#{verb} the guard in src/components/ui/bottom-sheet.tsx."
               ]
             })
    end
  end

  test "structured file corrections are actionable without an imperative verb whitelist" do
    for instruction <- [
          "Use a null guard in src/components/ui/bottom-sheet.tsx.",
          "Ensure src/components/ui/bottom-sheet.tsx handles nil.",
          "Guard the access in src/components/ui/bottom-sheet.tsx.",
          "Use the authenticated path in elixir/lib/symphony_elixir/dispatch_preflight.ex."
        ] do
      assert SymphonyElixir.RescueSupervisor.explicit_structured_code_change_request_for_test(%{
               "required_corrections" => [instruction]
             })
    end

    refute SymphonyElixir.RescueSupervisor.explicit_structured_code_change_request_for_test(%{
             "required_corrections" => [
               "Wait for the Codex review response for src/components/ui/bottom-sheet.tsx."
             ]
           })
  end

  test "dirty handoff recovery filters review feedback through implementation scope" do
    in_scope = %{
      type: :thread,
      payload: %{
        "path" => "src/features/swipe/SwipeExperience.tsx",
        "body" => "Fix active card identity."
      }
    }

    protected_out_of_scope = %{
      type: :thread,
      payload: %{
        "path" => "src/features/profile/ProfileScreen.tsx",
        "body" => "Change unrelated profile layout."
      }
    }

    requirements = %{
      "ticket_type" => "implementation",
      "write_scope" => ["src/features/swipe/SwipeExperience.tsx"],
      "shared_files" => [
        "src/features/profile/ProfileScreen.tsx (read-only; owned by the Profile lane)"
      ],
      "out_of_scope" => ["src/features/profile/ProfileScreen.tsx"]
    }

    assert [^in_scope] =
             SymphonyElixir.DispatchPreflight.handoff_recovery_feedback_for_test(
               %{feedback: [in_scope, protected_out_of_scope]},
               requirements
             )
  end

  defp pending_review_correction_fixture(test_root, issue_id, correction_attrs \\ %{}) do
    workspace_root = Path.join(test_root, "workspaces")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Rework"],
      workspace_root: workspace_root,
      review_monitor_enabled: true,
      review_monitor_repo: "acme/nutribuddy",
      review_monitor_states: ["Human Review", "In Review"],
      review_monitor_rework_state: "Rework",
      review_monitor_request_stale_after_ms: 600_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue = %Issue{
      id: issue_id,
      identifier: "COD-205",
      title: "Analytics MIU: Flow Instrumentation",
      state: "Rework",
      branch_name: "orocsy/cod-205"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert {:ok, workspace} = Workspace.create_for_issue(issue)

    assert {:ok, correction} =
             Workspace.create_correction_in_workspace(
               workspace,
               issue,
               Map.merge(
                 %{
                   source: "pr-review-handoff",
                   source_status: "blocked",
                   summary: "Fresh Codex review has not materialized for pushed head 748a56f",
                   findings: [
                     "Branch is clean and pushed; gh pr comment --body '@codex review' succeeded but the latest Codex review is stale."
                   ],
                   required_corrections: [
                     "External Codex review provider or Symphony review monitor must produce/observe a review result for the commit before Linear can leave active review-rework state."
                   ],
                   next_action: "retry"
                 },
                 correction_attrs
               )
             )

    {issue, workspace, correction}
  end

  defp install_pending_review_github_fixture(head_sha, opts) do
    test_pid = self()
    pr_number = Keyword.get(opts, :pr_number, 7)
    branch = Keyword.get(opts, :branch, "orocsy/cod-205")
    head_committed_at = Keyword.get(opts, :head_committed_at, "2026-05-15T09:10:00Z")
    pull_comments = Keyword.get(opts, :pull_comments, [])
    reviews = Keyword.get(opts, :reviews, [])
    issue_comments = Keyword.get(opts, :issue_comments, [])

    Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
      cond do
        String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
          {:ok,
           [
             %{
               "number" => pr_number,
               "html_url" => "https://github.com/acme/nutribuddy/pull/#{pr_number}",
               "head" => %{"sha" => head_sha, "ref" => branch}
             }
           ]}

        endpoint == "repos/acme/nutribuddy/pulls/#{pr_number}" ->
          {:ok,
           %{
             "number" => pr_number,
             "html_url" => "https://github.com/acme/nutribuddy/pull/#{pr_number}",
             "head" => %{"sha" => head_sha, "ref" => branch}
           }}

        endpoint == "repos/acme/nutribuddy/commits/#{head_sha}" ->
          {:ok, %{"commit" => %{"committer" => %{"date" => head_committed_at}}}}

        endpoint == "repos/acme/nutribuddy/pulls/#{pr_number}/comments" ->
          {:ok, pull_comments}

        endpoint == "repos/acme/nutribuddy/pulls/#{pr_number}/reviews" ->
          {:ok, reviews}

        String.starts_with?(endpoint, "repos/acme/nutribuddy/issues/#{pr_number}/comments?") ->
          {:ok, issue_comments}

        true ->
          {:error, {:unexpected_endpoint, endpoint}}
      end
    end)

    Application.put_env(:symphony_elixir, :github_api_post_runner, fn endpoint, fields ->
      send(test_pid, {:github_post, endpoint, fields})
      {:ok, %{"html_url" => "https://github.com/acme/nutribuddy/pull/#{pr_number}#issuecomment"}}
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_api_runner)
      Application.delete_env(:symphony_elixir, :github_api_post_runner)
    end)
  end

  defp review_thread_payload(head_sha, created_at) do
    %{
      "body" => "Keep current-head behavior intact.",
      "commit_id" => head_sha,
      "path" => "README.md",
      "line" => 3,
      "created_at" => created_at,
      "html_url" => "https://github.com/acme/nutribuddy/pull/7#discussion"
    }
  end

  defp codex_review_request_payload(created_at) do
    %{
      "body" => "@codex review",
      "created_at" => created_at,
      "html_url" => "https://github.com/acme/nutribuddy/pull/7#issuecomment"
    }
  end

  defp clean_codex_review_payload(created_at) do
    %{
      "body" => "Codex Review: Didn't find any major issues. What shall we delve into next?",
      "created_at" => created_at,
      "html_url" => "https://github.com/acme/nutribuddy/pull/7#issuecomment-clean",
      "user" => %{"login" => "chatgpt-codex-connector[bot]", "type" => "Bot"}
    }
  end

  defp write_scope_retry_preflight!(workspace, issue_identifier, head_sha, policy_hash, scope_bundle \\ nil) do
    state_dir = Path.join(workspace, ".orocsy/delivery/state")
    File.mkdir_p!(state_dir)

    scope_bundle =
      scope_bundle ||
        %{
          "policy_hash" => policy_hash,
          "write_scope" => [
            %{
              "path" => "src/features/swipe/SwipeExperience.tsx",
              "source" => "test.write_scope",
              "operation" => "write",
              "expires" => "branch"
            }
          ],
          "read_context" => [],
          "conflict_scope" => [],
          "denied_scope" => []
        }

    File.write!(
      Path.join(state_dir, "dispatch-preflight.json"),
      Jason.encode!(%{
        "mode" => "review_rework",
        "issue" => issue_identifier,
        "branch" => "orocsy/#{String.downcase(issue_identifier)}",
        "policy_hash" => policy_hash,
        "review" => %{
          "head_sha" => head_sha,
          "head_ref" => "orocsy/#{String.downcase(issue_identifier)}"
        },
        "requirements" => %{
          "ticket_type" => "Implementation",
          "write_scope" => ["src/features/swipe/SwipeExperience.tsx"],
          "scope_bundle" => scope_bundle
        }
      })
    )
  end

  defp write_scope_retry_correction!(workspace, issue, head_sha, policy_hash) do
    inbox = Path.join(workspace, ".orocsy/delivery/inbox")
    File.mkdir_p!(inbox)

    File.write!(
      Path.join(inbox, "correction_20260709000000_stale_scope.json"),
      Jason.encode!(%{
        "correction_id" => "correction_20260709000000_stale_scope",
        "status" => "open",
        "source" => "symphony.runtime.scope-access",
        "source_status" => "retryable",
        "summary" => "Scope policy stale for src/features/landing/GuestStartScreen.tsx",
        "findings" => [
          "Worker requested read src/features/landing/GuestStartScreen.tsx under unchanged policy #{policy_hash}."
        ],
        "required_corrections" => [
          "Update src/features/swipe/SwipeExperience.tsx or add read context, then rerun focused validation."
        ],
        "next_action" => "retry",
        "guard" => %{
          "scope_access" => %{
            "operation" => "read",
            "paths" => ["src/features/landing/GuestStartScreen.tsx"],
            "command_fingerprint" => "scope-read-guest-start"
          },
          "retry_fingerprint" => %{
            "issue" => issue.identifier,
            "issue_id" => issue.id,
            "source" => "symphony.runtime.scope-access",
            "head_sha" => head_sha,
            "policy_hash" => policy_hash,
            "operation" => "read",
            "paths" => ["src/features/landing/GuestStartScreen.tsx"],
            "command_fingerprint" => "scope-read-guest-start"
          }
        },
        "issue" => issue.identifier,
        "issue_id" => issue.id,
        "created_at" => "2026-07-09T00:00:00Z",
        "resolved_at" => nil,
        "resolution_summary" => ""
      })
    )
  end

  defp scope_unblock_correction_attrs(issue, opts) do
    path = Keyword.fetch!(opts, :path)
    operation = Keyword.get(opts, :operation, "read")
    head_sha = Keyword.get(opts, :head_sha, "abc123")
    policy_hash = Keyword.get(opts, :policy_hash, "sha256:scope-policy")
    next_action = Keyword.get(opts, :next_action, "retry")
    reason_class = Keyword.get(opts, :reason_class, "read_context_controller_not_enabled")

    %{
      source: "symphony.runtime.scope-access",
      source_status: "retryable",
      summary: "Scope policy stale for #{path}",
      findings: [
        "Worker requested #{operation} #{path} under unchanged policy #{policy_hash}."
      ],
      required_corrections: [
        "Update issue scope, add read context, or narrow the worker command before redispatch."
      ],
      next_action: next_action,
      guard: %{
        "scope_access" => %{
          "operation" => operation,
          "paths" => [path],
          "command_fingerprint" => "scope-access-#{operation}"
        },
        "decision" => "block",
        "reason_class" => reason_class,
        "retry_fingerprint" => %{
          "issue" => issue.identifier,
          "issue_id" => issue.id,
          "source" => "symphony.runtime.scope-access",
          "head_sha" => head_sha,
          "policy_hash" => policy_hash,
          "operation" => operation,
          "paths" => [path],
          "command_fingerprint" => "scope-access-#{operation}"
        }
      }
    }
  end

  defp write_knowledge_preflight!(workspace, issue_identifier, parent_identifier \\ nil, write_paths \\ []) do
    state_dir = Path.join(workspace, ".orocsy/delivery/state")
    File.mkdir_p!(state_dir)

    write_scope =
      Enum.map(write_paths, fn path ->
        %{
          "path" => path,
          "source" => "test.write_scope",
          "operation" => "write",
          "expires" => "branch"
        }
      end)

    scope_bundle =
      SymphonyElixir.IssueRequirements.refresh_scope_bundle_hash(%{
        "issue" => issue_identifier,
        "write_scope" => write_scope,
        "read_context" => [],
        "conflict_scope" => [],
        "denied_scope" => []
      })

    requirements =
      %{
        "identifier" => issue_identifier,
        "ticket_type" => "Implementation",
        "write_scope" => write_paths,
        "scope_bundle" => scope_bundle
      }
      |> then(fn requirements ->
        if is_binary(parent_identifier) and parent_identifier != "" do
          Map.put(requirements, "feature_group", parent_identifier)
        else
          requirements
        end
      end)

    File.write!(
      Path.join(state_dir, "dispatch-preflight.json"),
      Jason.encode!(%{
        "mode" => "review_rework",
        "issue" => issue_identifier,
        "requirements" => requirements
      })
    )
  end

  defp runtime_handoff_issue(%Issue{} = issue, opts \\ []) do
    miu_id = "#{issue.identifier}-MIU-1"
    branch = issue.branch_name
    automatic_merge? = Keyword.get(opts, :automatic_merge, false)

    description = """
    ## Runtime Contract

    ```yaml
    schema_version: 1
    ticket_type: implementation
    base_branch: main
    integration_branch: #{branch}
    dependencies: []
    mius:
      - id: #{miu_id}
        write_scope:
          - README.md
        validations:
          - git diff --check
    final_validations:
      - git diff --check
    review:
      authority: github_codex
      require_current_head: true
    merge:
      automatic: #{automatic_merge?}
      method: squash
      require_ci_checks: true
      completed_state: Done
    ```

    ## Technical Brief

    #{issue.description}
    """

    %{issue | description: description}
  end

  defp issue_runtime_handoff_certificate!(workspace, %Issue{} = issue) do
    {:ok, compiled} = SymphonyElixir.RuntimeContract.compile(issue.description)
    push_workspace_head_to_test_origin!(workspace)
    previous_pr_runner = Application.get_env(:symphony_elixir, :handoff_pull_request_runner)

    Application.put_env(:symphony_elixir, :handoff_pull_request_runner, fn _repo, branch ->
      {:ok,
       %{
         "number" => 999,
         "html_url" => "https://github.com/test/symphony/pull/999",
         "state" => "open",
         "head" => %{"ref" => branch, "sha" => git_head!(workspace)},
         "base" => %{"ref" => compiled.contract["base_branch"]}
       }}
    end)

    on_exit(fn ->
      if is_nil(previous_pr_runner) do
        Application.delete_env(:symphony_elixir, :handoff_pull_request_runner)
      else
        Application.put_env(:symphony_elixir, :handoff_pull_request_runner, previous_pr_runner)
      end
    end)

    assert {:ok, _certificate} =
             SymphonyElixir.HandoffCertificate.issue(issue, workspace,
               completed_mius: compiled.miu_ids,
               validation_event_ids: ["test-validation"]
             )

    :ok
  end

  defp push_workspace_head_to_test_origin!(workspace) do
    remote = Path.join(workspace, ".git/orocsy-test-origin.git")
    {_output, 0} = System.cmd("git", ["init", "--bare", remote], cd: workspace, stderr_to_stdout: true)

    remote_args =
      case System.cmd("git", ["remote", "get-url", "origin"], cd: workspace, stderr_to_stdout: true) do
        {_url, 0} -> ["remote", "set-url", "origin", remote]
        {_output, _status} -> ["remote", "add", "origin", remote]
      end

    {_output, 0} = System.cmd("git", remote_args, cd: workspace, stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["push", "--force", "--set-upstream", "origin", "HEAD"], cd: workspace, stderr_to_stdout: true)

    previous_runner = Application.get_env(:symphony_elixir, :handoff_remote_head_runner)

    Application.put_env(:symphony_elixir, :handoff_remote_head_runner, fn branch ->
      case System.cmd("git", ["--git-dir", remote, "rev-parse", "refs/heads/#{branch}"], stderr_to_stdout: true) do
        {head_sha, 0} -> {:ok, %{"repo" => "test/symphony", "head_sha" => String.trim(head_sha)}}
        {output, status} -> {:error, {:remote_ref_failed, status, String.trim(output)}}
      end
    end)

    on_exit(fn ->
      if is_nil(previous_runner) do
        Application.delete_env(:symphony_elixir, :handoff_remote_head_runner)
      else
        Application.put_env(:symphony_elixir, :handoff_remote_head_runner, previous_runner)
      end
    end)

    :ok
  end

  defp git_head!(workspace) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {head_sha, 0} -> String.trim(head_sha)
      {output, status} -> flunk("git rev-parse HEAD failed (#{status}): #{output}")
    end
  end

  defp empty_orchestrator_state do
    %Orchestrator.State{
      max_concurrent_agents: 1,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end

  defp iso_seconds(delta_seconds) do
    DateTime.utc_now()
    |> DateTime.add(delta_seconds, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
