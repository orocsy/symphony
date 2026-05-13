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
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
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

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
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
    assert Map.get(hooks, "after_create") =~ "git clone --depth 1 https://github.com/openai/symphony ."
    assert Map.get(hooks, "after_create") =~ "cd elixir && mise trust"
    assert Map.get(hooks, "after_create") =~ "mise exec -- mix deps.get"
    assert Map.get(hooks, "before_remove") =~ "cd elixir && mise exec -- mix workspace.before_remove"

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
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
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
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
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

      initial_state = :sys.get_state(pid)

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

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, 500, 1_100)
  end

  test "normal worker exit with open correction does not schedule continuation retry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-continuation-correction-block-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

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

      [correction_path] = Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
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

      [correction_path] = Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
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

      [correction_path] = Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.token-budget"
      assert correction["source_status"] == "blocked"
      assert correction["next_action"] == "block"
      assert Workspace.blocking_correction_in_workspace?(workspace)

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
      assert {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
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
      assert {_output, 0} = System.cmd("git", ["switch", "-c", "worker"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "review-fix.txt"), "local handoff work\n")
      assert {_output, 0} = System.cmd("git", ["add", "review-fix.txt"], cd: workspace)
      assert {_output, 0} = System.cmd("git", ["commit", "-m", "Fix review feedback"], cd: workspace, stderr_to_stdout: true)

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
      assert %{attempt: 1, workspace_path: ^workspace} = Map.fetch!(state.retry_attempts, issue_id)
      assert [] == Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
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
      assert {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      assert {_output, 0} = System.cmd("git", ["config", "core.logAllRefUpdates", "true"], cd: workspace)
      File.write!(Path.join(workspace, "baseline.txt"), "baseline\n")
      assert {_output, 0} = System.cmd("git", ["add", "baseline.txt"], cd: workspace)

      assert {_output, 0} =
               System.cmd("git", ["commit", "-m", "Baseline"],
                 cd: workspace,
                 env: [{"GIT_AUTHOR_DATE", baseline_ts}, {"GIT_COMMITTER_DATE", baseline_ts}],
                 stderr_to_stdout: true
               )

      assert {_output, 0} = System.cmd("git", ["branch", "-M", "main"], cd: workspace)
      assert {_output, 0} = System.cmd("git", ["switch", "-c", "worker"], cd: workspace, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["remote", "add", "origin", "https://example.org/repo.git"], cd: workspace)

      File.write!(Path.join(workspace, "review-fix.txt"), "remote handoff work\n")
      assert {_output, 0} = System.cmd("git", ["add", "review-fix.txt"], cd: workspace)
      assert {_output, 0} = System.cmd("git", ["commit", "-m", "Fix review feedback"], cd: workspace, stderr_to_stdout: true)
      {remote_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
      assert {_output, 0} = System.cmd("git", ["reset", "--hard", "HEAD~1"], cd: workspace, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["update-ref", "refs/remotes/origin/worker", String.trim(remote_sha)], cd: workspace)
      assert {_output, 0} = System.cmd("git", ["branch", "--set-upstream-to", "origin/worker"], cd: workspace, stderr_to_stdout: true)

      assert {counts, 0} = System.cmd("git", ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], cd: workspace)
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
      assert %{attempt: 1, workspace_path: ^workspace} = Map.fetch!(state.retry_attempts, issue_id)
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

      orchestrator_name = Module.concat(__MODULE__, :NoDurableProgressParkOrchestrator)
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
      refute Map.has_key?(state.retry_attempts, issue_id)

      [correction_path] = Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.no-durable-progress"
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
      assert {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
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
        Jason.encode!(%{"event" => "gate.declared-scope", "status" => "passed", "ts" => stale_ts}) <> "\n"
      )

      assert {_output, 0} = System.cmd("git", ["add", ".orocsy/delivery/events/events.jsonl"], cd: workspace)

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

      [correction_path] = Path.wildcard(Path.join(workspace, ".orocsy/delivery/inbox/correction_*.json"))
      correction = correction_path |> File.read!() |> Jason.decode!()

      assert correction["source"] == "symphony.runtime.no-durable-progress"
      assert correction["guard"]["quiet_ms"] >= 10
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
      assert {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
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
      assert {_output, 0} = System.cmd("git", ["switch", "-c", "worker"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "progress.txt"), "committed work proves progress\n")
      assert {_output, 0} = System.cmd("git", ["add", "progress.txt"], cd: workspace)
      assert {_output, 0} = System.cmd("git", ["commit", "-m", "Add progress"], cd: workspace, stderr_to_stdout: true)

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

      assert Orchestrator.durable_progress_quiet_ms_for_test(running_entry, DateTime.utc_now()) < 60_000

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

      assert Orchestrator.durable_progress_quiet_ms_for_test(running_entry, DateTime.utc_now()) < 60_000

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

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 39_500, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
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

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
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
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
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

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms - 250
    assert remaining_ms <= max_remaining_ms
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
    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

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

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

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
    assert prompt =~ "Ticket MT-201"
  end

  test "prompt builder prepends issue technical brief when present" do
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
      File.write!(Path.join(brief_dir, "MT-202.md"), "Current paths: src/lib/session.ts\nTarget shape: resolveGuestSession()\n")

      issue = %Issue{
        identifier: "MT-202",
        title: "Use issue brief",
        description: "Prompt should include local issue brief",
        state: "In Progress",
        url: "https://example.org/issues/MT-202",
        labels: []
      }

      prompt = PromptBuilder.build_prompt(issue, workspace: workspace)

      assert String.starts_with?(prompt, "Issue technical brief:")
      assert prompt =~ "Current paths: src/lib/session.ts"
      assert prompt =~ "Target shape: resolveGuestSession()"
      assert prompt =~ "Ticket MT-202"
    after
      File.rm_rf(workspace)
    end
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
      assert prompt =~ "First action: inspect the focused diff, stage the intended files, commit, and push"
      assert prompt =~ "Do not query broad Linear/GitHub context"
      assert prompt =~ "Ticket MT-203"
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
      {_output, 0} = System.cmd("git", ["config", "user.email", "symphony@example.test"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["config", "user.name", "Symphony Test"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "README.md"), "# Test\n")
      {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["branch", "-M", "main"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["switch", "-c", "orocsy/mt-203"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "README.md"), "# Test\n\nReview fix.\n")
      {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Fix review feedback"], cd: workspace, stderr_to_stdout: true)

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
      assert prompt =~ "run the smallest validation needed for those changed files"
      assert prompt =~ "Do not redo implementation"
      assert prompt =~ "Ticket MT-203"
    after
      File.rm_rf(workspace)
    end
  end

  test "prompt builder prepends pushed validated handoff checkpoint for clean tracked branches" do
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
      {_output, 0} = System.cmd("git", ["config", "user.email", "symphony@example.test"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["config", "user.name", "Symphony Test"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "README.md"), "# Test\n")
      {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["switch", "-c", "orocsy/mt-204"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "README.md"), "# Test\n\nReady.\n")
      {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Add ready state"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["remote", "add", "origin", "https://example.org/repo.git"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-204", "HEAD"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-204"], cd: workspace, stderr_to_stdout: true)
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

      assert String.starts_with?(prompt, "Pushed validated handoff checkpoint:")
      assert prompt =~ "Minimal review handoff mode:"
      assert prompt =~ "handoff-ready validation passed"
      assert prompt =~ "current ticket, current workspace branch/code, and the current GitHub/Codex PR review only"
      assert prompt =~ "Do not read AGENTS.md, skills, broad project docs, historical delivery logs, unrelated tickets"
      assert prompt =~ "Active issue: `MT-204`"
      refute prompt =~ "You must read AGENTS.md"
      refute prompt =~ "Ticket MT-204"
    after
      File.rm_rf(workspace)
    end
  end

  test "orchestrator completes clean pushed review handoff without starting a Codex worker" do
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
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-direct-handoff",
        identifier: "MT-205",
        title: "Finish pushed handoff",
        description: "Only PR review handoff remains.",
        state: "Rework",
        url: "https://linear.example/MT-205",
        branch_name: "orocsy/mt-205",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["config", "user.email", "symphony@example.test"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["config", "user.name", "Symphony Test"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "README.md"), "# Test\n")
      {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["switch", "-c", "orocsy/mt-205"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "README.md"), "# Test\n\nReady.\n")
      {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Add ready handoff"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-205", "HEAD"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-205"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "focused validation passed", "ts": "2026-05-12T05:00:49Z"}\n)
      )

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 3,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/3",
                 "head" => %{"sha" => "abc123current", "ref" => "orocsy/mt-205"}
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/3/comments" ->
            {:ok, []}

          endpoint == "repos/acme/nutribuddy/pulls/3/reviews" ->
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
                 "headRefOid" => "abc123current",
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

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_api_runner)
        Application.delete_env(:symphony_elixir, :github_graphql_runner)
      end)

      assert {:completed, %{target_state: "Human Review", pr_number: 3}} =
               Orchestrator.complete_pushed_handoff_for_test(issue)

      assert_receive {:memory_tracker_state_update, "issue-direct-handoff", "Human Review"}
      assert_receive {:memory_tracker_comment, "issue-direct-handoff", body}
      assert body =~ "without starting a new Codex worker"
      assert body =~ "https://github.com/acme/nutribuddy/pull/3"

      events = File.read!(Path.join(event_dir, "events.jsonl"))
      assert events =~ ~s("event":"handoff.completed")
      assert events =~ "direct-pushed-review-handoff"
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
        review_monitor_repo: "acme/nutribuddy",
        review_monitor_states: ["Human Review"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-direct-handoff-feedback",
        identifier: "MT-206",
        title: "Resolve feedback",
        description: "Review feedback remains.",
        state: "Rework",
        branch_name: "orocsy/mt-206",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["config", "user.email", "symphony@example.test"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["config", "user.name", "Symphony Test"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "README.md"), "# Test\n")
      {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Initial"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["switch", "-c", "orocsy/mt-206"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "README.md"), "# Test\n\nNeeds feedback fix.\n")
      {_output, 0} = System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "Add review state"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["remote", "add", "origin", "https://github.com/acme/nutribuddy.git"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["update-ref", "refs/remotes/origin/orocsy/mt-206", "HEAD"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["branch", "--set-upstream-to", "origin/orocsy/mt-206"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])

      event_dir = Path.join(workspace, ".orocsy/delivery/events")
      File.mkdir_p!(event_dir)

      File.write!(
        Path.join(event_dir, "events.jsonl"),
        ~s({"event": "gate.post-miu", "status": "passed", "step": "focused validation passed", "ts": "2026-05-12T05:00:49Z"}\n)
      )

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        cond do
          String.starts_with?(endpoint, "repos/acme/nutribuddy/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 3,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/3",
                 "head" => %{"sha" => "abc123current", "ref" => "orocsy/mt-206"}
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/3/comments" ->
            {:ok,
             [
               %{
                 "body" => "Fix the review target.",
                 "commit_id" => "abc123current",
                 "path" => "README.md",
                 "line" => 3,
                 "html_url" => "https://github.com/acme/nutribuddy/pull/3#discussion"
               }
             ]}

          endpoint == "repos/acme/nutribuddy/pulls/3/reviews" ->
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
                 "headRefOid" => "abc123current",
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
      refute_receive {:memory_tracker_state_update, "issue-direct-handoff-feedback", "Human Review"}, 50
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
end
