defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure app-server refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-1000")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-symlink-guard",
        identifier: "MT-1000",
        title: "Validate symlink workspace guard",
        description: "Ensure app-server refuses symlink escape cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-1000",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               AppServer.run(symlink_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server forwards turn sandbox policies with local writable roots expanded" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-turn-policies-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-turn-policies.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)
      {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-turn-policies.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1001"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1001"}}}'
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

      issue = %Issue{
        id: "issue-supported-turn-policies",
        identifier: "MT-1001",
        title: "Validate explicit turn sandbox policy passthrough",
        description: "Ensure runtime startup forwards configured turn sandbox policies unchanged",
        state: "In Progress",
        url: "https://example.org/issues/MT-1001",
        labels: ["backend"]
      }

      policy_cases = [
        %{"type" => "dangerFullAccess"},
        %{"type" => "externalSandbox", "profile" => "remote-ci"},
        %{"type" => "workspaceWrite", "writableRoots" => ["relative/path"], "networkAccess" => true},
        %{"type" => "futureSandbox", "nested" => %{"flag" => true}}
      ]

      Enum.each(policy_cases, fn configured_policy ->
        expected_policy =
          case configured_policy do
            %{"type" => "workspaceWrite", "writableRoots" => writable_roots} ->
              Map.put(configured_policy, "writableRoots", Enum.map(writable_roots, &Path.expand(&1, canonical_workspace)))

            _ ->
              configured_policy
          end

        File.rm(trace_file)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server",
          codex_turn_sandbox_policy: configured_policy
        )

        assert {:ok, _result} = AppServer.run(workspace, "Validate supported turn policy", issue)

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)

        assert Enum.any?(lines, fn line ->
                 if String.starts_with?(line, "JSON:") do
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()
                   |> then(fn payload ->
                     payload["method"] == "turn/start" &&
                       get_in(payload, ["params", "sandboxPolicy"]) == expected_policy
                   end)
                 else
                   false
                 end
               end)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server treats app-server error notifications as a hard failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-error-notification-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-ERROR")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-error"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-error"}}}'
            printf '%s\\n' '{"method":"error","params":{"message":"startup failed"}}'
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
        id: "issue-error-notification",
        identifier: "MT-ERROR",
        title: "Fail on app-server error notification",
        description: "Ensure runtime does not keep retrying a failed app-server turn as normal completion",
        state: "In Progress",
        url: "https://example.org/issues/MT-ERROR",
        labels: ["backend"]
      }

      assert {:error, {:codex_error, %{"message" => "startup failed"}}} =
               AppServer.run(workspace, "Handle app-server error notification", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server treats turn_aborted wrapper events as hard failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-turn-aborted-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-ABORT")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-abort"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-abort"}}}'
            printf '%s\\n' '{"method":"codex/event/event_msg","params":{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted","turn_id":"turn-abort"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
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
        id: "issue-turn-abort",
        identifier: "MT-ABORT",
        title: "Abort on interrupted turn",
        description: "Ensure interrupted workers are not treated as normal completion",
        state: "Rework",
        url: "https://example.org/issues/MT-ABORT",
        labels: ["backend"]
      }

      assert {:error, {:turn_aborted, %{"payload" => %{"reason" => "interrupted"}}}} =
               AppServer.run(workspace, "Handle interrupted turn", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server starts review rework threads with isolated skill and plugin config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-thread-config-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW",
          "branch" => "orocsy/mt-review"
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-review-rework.trace}"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review"}}}'
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
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-review",
        identifier: "MT-REVIEW",
        title: "Review rework",
        description: "Fix current PR review feedback",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)

      thread_start =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["method"] == "thread/start"))

      assert get_in(thread_start, ["params", "baseInstructions"]) =~ "Symphony review-rework worker"
      assert get_in(thread_start, ["params", "baseInstructions"]) =~ "Do not perform broad project discovery"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "Symphony review-rework micro-worker"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "Do not load Codex skills"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "Do not refetch GitHub or Linear review text"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "Do not run broad rg, grep, find, ls, git ls-files, mutating gh api"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "bounded `rg -n"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "read-only GitHub PR/review inspection"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "gh pr comment <pr-number> --body '@codex review'"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "create that exact file"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "alternate app roots"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "colocated sibling tests"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "dispatch-preflight.json"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "read-only runtime context"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "Never move a review-rework issue to `Done`"

      disabled_skills = get_in(thread_start, ["params", "config", "skills", "disabled_skill_names"])
      assert "typescript-best-practices" in disabled_skills
      assert "linear:linear" in disabled_skills
      assert "build-web-apps:react-best-practices" in disabled_skills

      assert get_in(thread_start, ["params", "config", "features", "plugins"]) == false
      assert get_in(thread_start, ["params", "config", "features", "apps"]) == false
      assert get_in(thread_start, ["params", "config", "features", "tool_search"]) == false
      assert get_in(thread_start, ["params", "config", "apps", "_default", "enabled"]) == false
      assert get_in(thread_start, ["params", "config", "plugins", "linear@openai-curated", "enabled"]) == false
      assert get_in(thread_start, ["params", "config", "plugins", "build-web-apps@openai-curated", "enabled"]) == false
      refute Map.has_key?(get_in(thread_start, ["params", "config"]), "mcp_servers")
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server starts fresh implementation threads with isolated MIU config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fresh-implementation-thread-config-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-FRESH")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-fresh.trace")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "fresh_implementation",
          "issue" => "MT-FRESH",
          "requirements" => %{
            "ticket_type" => "contract",
            "write_scope" => ["docs/TECHNICAL_DESIGN.md"]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-fresh.trace}"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fresh"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fresh"}}}'
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
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-fresh",
        identifier: "MT-FRESH",
        title: "Fresh MIU",
        description: "Implement a focused MIU",
        state: "In Progress",
        url: "https://example.org/issues/MT-FRESH",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Implement fresh MIU", issue)

      thread_start =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["method"] == "thread/start"))

      assert get_in(thread_start, ["params", "baseInstructions"]) =~ "Symphony fresh-MIU worker"
      assert get_in(thread_start, ["params", "baseInstructions"]) =~ "Do not perform broad project discovery"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "Symphony fresh-MIU micro-worker"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ ".orocsy/delivery/issue-brief.md"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "technical-miu-trace"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "Do not run `rg`, `grep`, `find`"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "Never merge automatically"

      disabled_skills = get_in(thread_start, ["params", "config", "skills", "disabled_skill_names"])
      assert "agentic-delivery-loop" in disabled_skills
      assert "linear:linear" in disabled_skills
      assert "typescript-best-practices" in disabled_skills

      assert get_in(thread_start, ["params", "config", "features", "plugins"]) == false
      assert get_in(thread_start, ["params", "config", "features", "apps"]) == false
      assert get_in(thread_start, ["params", "config", "features", "tool_search"]) == false
      assert get_in(thread_start, ["params", "config", "apps", "_default", "enabled"]) == false
      assert get_in(thread_start, ["params", "config", "plugins", "linear@openai-curated", "enabled"]) == false
      refute Map.has_key?(get_in(thread_start, ["params", "config"]), "mcp_servers")
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server blocks broad search commands in fresh implementation mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fresh-implementation-forbidden-search-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-FRESH-SEARCH")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(Path.join(workspace, "src/app"))

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "fresh_implementation",
          "issue" => "MT-FRESH-SEARCH",
          "branch" => "orocsy/mt-fresh-search",
          "requirements" => %{
            "ticket_type" => "contract",
            "write_scope" => ["docs/TECHNICAL_DESIGN.md"]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fresh-search"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fresh-search"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"rg -n \\"SavedRecipe\\" docs/TECHNICAL_DESIGN.md"}}}'
            ;;
          *)
            sleep 1
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
        id: "issue-fresh-search",
        identifier: "MT-FRESH-SEARCH",
        title: "Fresh MIU search",
        description: "Search should be blocked in fresh implementation",
        state: "In Progress",
        url: "https://example.org/issues/MT-FRESH-SEARCH",
        labels: []
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Implement fresh MIU", issue)

      assert command == ~s(rg -n "SavedRecipe" docs/TECHNICAL_DESIGN.md)
      assert pattern == "(^|\\s|[\"'])rg(\\s|$)"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks exec_command function calls in fresh implementation mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fresh-implementation-function-call-command-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-FRESH-FUNCTION-CALL")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "fresh_implementation",
          "issue" => "MT-FRESH-FUNCTION-CALL",
          "branch" => "orocsy/mt-fresh-function-call",
          "requirements" => %{
            "ticket_type" => "contract",
            "write_scope" => ["docs/TECHNICAL_DESIGN.md"]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fresh-function-call"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fresh-function-call"}}}'
            printf '%s\\n' '{"method":"codex/event/response_item","params":{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"find . -maxdepth 2 -type f\\"}"}}}'
            ;;
          *)
            sleep 1
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
        id: "issue-fresh-function-call",
        identifier: "MT-FRESH-FUNCTION-CALL",
        title: "Fresh MIU function call",
        description: "Function-call exec commands should be blocked in fresh implementation",
        state: "In Progress",
        url: "https://example.org/issues/MT-FRESH-FUNCTION-CALL",
        labels: []
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Implement fresh MIU", issue)

      assert command == "find . -maxdepth 2 -type f"
      assert pattern == "(^|\\s|[\"'])find(\\s|$)"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows local directory listing in fresh implementation mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fresh-implementation-local-listing-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-FRESH-LOCAL-LISTING")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "fresh_implementation",
          "issue" => "MT-FRESH-LOCAL-LISTING",
          "branch" => "orocsy/mt-fresh-local-listing",
          "requirements" => %{
            "ticket_type" => "implementation",
            "write_scope" => ["src/features/saved/*", "tests/unit/saved-profile-screens.test.ts"]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fresh-local-listing"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fresh-local-listing"}}}'
            printf '%s\\n' '{"method":"codex/event/response_item","params":{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"ls -la src/features/saved 2>/dev/null || true && sed -n '\\''1,240p'\\'' tests/unit/saved-profile-screens.test.ts\\"}"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-fresh-local-listing",
        identifier: "MT-FRESH-LOCAL-LISTING",
        title: "Fresh MIU local listing",
        description: "Local directory listing should not park fresh implementation",
        state: "In Progress",
        url: "https://example.org/issues/MT-FRESH-LOCAL-LISTING",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Implement fresh MIU", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows git handoff shell chains in fresh implementation mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fresh-implementation-git-handoff-chain-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-FRESH-GIT-HANDOFF")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "fresh_implementation",
          "issue" => "MT-FRESH-GIT-HANDOFF",
          "branch" => "orocsy/mt-fresh-git-handoff",
          "requirements" => %{
            "ticket_type" => "contract",
            "write_scope" => ["docs/TECHNICAL_DESIGN.md"]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fresh-git-handoff"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fresh-git-handoff"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"git add docs/TECHNICAL_DESIGN.md && git commit -m \\"docs: define saved profile contract\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-fresh-git-handoff",
        identifier: "MT-FRESH-GIT-HANDOFF",
        title: "Fresh MIU git handoff",
        description: "Git add and commit handoff chains should be allowed in fresh implementation",
        state: "In Progress",
        url: "https://example.org/issues/MT-FRESH-GIT-HANDOFF",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Implement fresh MIU", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks GitHub API calls before fresh implementation progress" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fresh-implementation-preprogress-gh-api-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-FRESH-GH-BLOCK")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "fresh_implementation",
          "issue" => "MT-FRESH-GH-BLOCK",
          "branch" => "orocsy/mt-fresh-gh-block",
          "requirements" => %{
            "ticket_type" => "contract",
            "write_scope" => ["docs/TECHNICAL_DESIGN.md"]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fresh-gh-block"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fresh-gh-block"}}}'
            printf '%s\\n' '{"method":"codex/event/response_item","params":{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"gh api repos/orocsy/nutribuddy/pulls\\"}"}}}'
            ;;
          *)
            sleep 1
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
        id: "issue-fresh-gh-block",
        identifier: "MT-FRESH-GH-BLOCK",
        title: "Fresh MIU pre-progress gh api",
        description: "GitHub API discovery should be blocked before durable progress",
        state: "In Progress",
        url: "https://example.org/issues/MT-FRESH-GH-BLOCK",
        labels: []
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Implement fresh MIU", issue)

      assert command == "gh api repos/orocsy/nutribuddy/pulls"
      assert pattern == "(^|\\s|[\"'])gh\\s+api(\\s|$)"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows GitHub API handoff after fresh implementation progress" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fresh-implementation-handoff-gh-api-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-FRESH-GH-HANDOFF")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      events_dir = Path.join(workspace, ".orocsy/delivery/events")
      events_file = Path.join(events_dir, "events.jsonl")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(events_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "fresh_implementation",
          "issue" => "MT-FRESH-GH-HANDOFF",
          "branch" => "orocsy/mt-fresh-gh-handoff",
          "requirements" => %{
            "ticket_type" => "contract",
            "write_scope" => ["docs/TECHNICAL_DESIGN.md"]
          }
        })
      )

      File.write!(
        events_file,
        Jason.encode!(%{"event" => "tool.finished", "status" => "passed", "tool" => "technical-miu-trace"}) <> "\n"
      )

      write_fresh_checkpoint_git_progress!(workspace, "docs/TECHNICAL_DESIGN.md")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fresh-gh-handoff"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fresh-gh-handoff"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"git fetch origin main && MAIN_SHA=$(git rev-parse origin/main) && gh api repos/orocsy/nutribuddy/git/refs -f ref=refs/heads/orocsy/feature-saved-profile-integration -f sha=$MAIN_SHA"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-fresh-gh-handoff",
        identifier: "MT-FRESH-GH-HANDOFF",
        title: "Fresh MIU gh api handoff",
        description: "GitHub API handoff should be allowed after durable progress",
        state: "In Progress",
        url: "https://example.org/issues/MT-FRESH-GH-HANDOFF",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Implement fresh MIU", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows delivery event append metadata to mention forbidden command text" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-delivery-event-append-command-metadata-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-EVENT-METADATA")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "fresh_implementation",
          "issue" => "MT-EVENT-METADATA",
          "branch" => "orocsy/mt-event-metadata",
          "requirements" => %{
            "ticket_type" => "implementation",
            "write_scope" => ["src/example.ts"]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-event-metadata"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-event-metadata"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . event append --type blocker --status blocked --phase handoff --step handoff --tool handoff-review-scan --command \\"gh api graphql returned no reviews or threads; gh pr checks returned no checks reported\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-event-metadata",
        identifier: "MT-EVENT-METADATA",
        title: "Delivery event metadata",
        description: "Delivery blocker metadata can quote observed forbidden commands",
        state: "In Progress",
        url: "https://example.org/issues/MT-EVENT-METADATA",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Record delivery blocker", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server stops a fresh implementation turn once its first checkpoint appears" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fresh-implementation-checkpoint-stop-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-FRESH-CHECKPOINT-STOP")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "fresh_implementation",
          "issue" => "MT-FRESH-CHECKPOINT-STOP",
          "branch" => "orocsy/mt-fresh-checkpoint-stop",
          "requirements" => %{
            "ticket_type" => "implementation",
            "write_scope" => ["src/app/page.tsx"]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fresh-checkpoint-stop"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fresh-checkpoint-stop"}}}'
            mkdir -p .orocsy/delivery/events src/app
            printf '%s\\n' 'export default function Page() { return "checkpoint"; }' > src/app/page.tsx
            printf '%s\\n' '{"event":"tool.finished","status":"passed","tool":"technical-miu-trace"}' >> .orocsy/delivery/events/events.jsonl
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"pnpm exec playwright test tests/e2e/auth-migration.spec.ts --project chrome"}}}'
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      File.mkdir_p!(Path.join(workspace, "src/app"))
      File.write!(Path.join(workspace, "src/app/page.tsx"), "export default function Page() { return \"baseline\"; }\n")
      assert {_output, 0} = System.cmd("git", ["add", "src/app/page.tsx"], cd: workspace, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["commit", "-m", "Baseline"], cd: workspace, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: workspace, stderr_to_stdout: true)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-fresh-checkpoint-stop",
        identifier: "MT-FRESH-CHECKPOINT-STOP",
        title: "Fresh MIU checkpoint stop",
        description: "Fresh workers should stop after the scoped checkpoint",
        state: "In Progress",
        url: "https://example.org/issues/MT-FRESH-CHECKPOINT-STOP",
        labels: []
      }

      parent = self()
      on_message = fn message -> send(parent, {:codex_message, message}) end

      assert {:ok, %{result: :fresh_checkpoint_stop}} =
               AppServer.run(workspace, "Implement fresh MIU", issue, on_message: on_message)

      assert_receive {:codex_message, %{event: :fresh_checkpoint_stop, checkpoint_event: "technical-miu-trace"}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows read-only GitHub API GET after fresh implementation progress" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fresh-implementation-gh-api-get-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-FRESH-GH-GET-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      events_dir = Path.join(workspace, ".orocsy/delivery/events")
      events_file = Path.join(events_dir, "events.jsonl")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(events_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "fresh_implementation",
          "issue" => "MT-FRESH-GH-GET-READ",
          "branch" => "orocsy/mt-fresh-gh-get-read",
          "requirements" => %{
            "ticket_type" => "contract",
            "write_scope" => ["docs/TECHNICAL_DESIGN.md"]
          }
        })
      )

      File.write!(
        events_file,
        Jason.encode!(%{"event" => "tool.finished", "status" => "passed", "tool" => "technical-miu-trace"}) <> "\n"
      )

      write_fresh_checkpoint_git_progress!(workspace, "docs/TECHNICAL_DESIGN.md")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fresh-gh-get-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fresh-gh-get-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"gh api --method GET repos/orocsy/nutribuddy/pulls?head=orocsy:orocsy/cod-200-analytics-tdd-event-catalog-and-no-secret-schema"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-fresh-gh-get-read",
        identifier: "MT-FRESH-GH-GET-READ",
        title: "Fresh MIU gh api GET read",
        description: "Read-only GitHub PR lookup should be allowed after durable progress",
        state: "In Progress",
        url: "https://example.org/issues/MT-FRESH-GH-GET-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Implement fresh MIU", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows integration-check read-only GitHub API PR lookup before durable progress" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-integration-gh-api-readonly-preprogress-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-INTEGRATION-GH-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "integration_check",
          "issue" => "MT-INTEGRATION-GH-READ",
          "branch" => "orocsy/feature-analytics-observability-integration",
          "requirements" => %{
            "ticket_type" => "integration-check",
            "integration_branch" => "orocsy/feature-analytics-observability-integration",
            "write_scope" => ["Final PR validation notes only"]
          },
          "review" => %{"pr_number" => nil, "pr_url" => nil}
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-integration-gh-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-integration-gh-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"gh api --method GET repos/orocsy/nutribuddy/pulls -f state=open -f head=orocsy:orocsy/feature-analytics-observability-integration -f base=main --jq .[].number"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-integration-gh-read",
        identifier: "MT-INTEGRATION-GH-READ",
        title: "Integration check gh api read",
        description: "Integration-check PR lookup can read GitHub before durable local progress",
        state: "In Progress",
        url: "https://example.org/issues/MT-INTEGRATION-GH-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate integration handoff", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows integration-check shell-quoted read-only GitHub API PR lookup" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-integration-shell-quoted-gh-api-readonly-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-INTEGRATION-SHELL-GH-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "integration_check",
          "issue" => "MT-INTEGRATION-SHELL-GH-READ",
          "branch" => "orocsy/feature-analytics-observability-integration",
          "requirements" => %{
            "ticket_type" => "integration-check",
            "branch" => "orocsy/cod-208-analytics-integration-check-and-final-pr-handoff",
            "integration_branch" => "orocsy/feature-analytics-observability-integration",
            "write_scope" => ["Final PR validation notes only"]
          },
          "review" => %{"pr_number" => nil, "pr_url" => nil}
        })
      )

      command =
        ~s(/bin/zsh -lc "gh api --method GET \\"repos/orocsy/nutribuddy/pulls?head=orocsy:orocsy/cod-208-analytics-integration-check-and-final-pr-handoff&state=open\\" --jq .[].number")

      exec_event =
        Jason.encode!(%{
          "method" => "codex/event/exec_command_begin",
          "params" => %{"msg" => %{"command" => command}}
        })

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-integration-shell-gh-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-integration-shell-gh-read"}}}'
            printf '%s\\n' '#{exec_event}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-integration-shell-gh-read",
        identifier: "MT-INTEGRATION-SHELL-GH-READ",
        title: "Integration check shell quoted gh api read",
        description: "Integration-check PR lookup can use quoted GET endpoints in shell-wrapped commands",
        state: "In Progress",
        url: "https://example.org/issues/MT-INTEGRATION-SHELL-GH-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate integration handoff", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks plain pnpm test when symlinked Vitest workspaces need configLoader runner" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-symlinked-vitest-pnpm-test-block-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-SYMLINKED-VITEST-BLOCK")
      dependency_root = Path.join(test_root, "dependency-root")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(Path.join(dependency_root, "node_modules"))
      File.ln_s!(Path.join(dependency_root, "node_modules"), Path.join(workspace, "node_modules"))

      File.write!(
        Path.join(workspace, "package.json"),
        Jason.encode!(%{"scripts" => %{"test" => "vitest run"}})
      )

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "integration_check",
          "issue" => "MT-SYMLINKED-VITEST-BLOCK",
          "branch" => "orocsy/feature-analytics-observability-integration",
          "requirements" => %{
            "ticket_type" => "integration-check",
            "integration_branch" => "orocsy/feature-analytics-observability-integration",
            "validation" => %{"commands" => ["pnpm test"]},
            "write_scope" => ["Final PR validation notes only"]
          },
          "review" => %{"pr_number" => nil, "pr_url" => nil}
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-symlinked-vitest-block"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-symlinked-vitest-block"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"pnpm test"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-symlinked-vitest-block",
        identifier: "MT-SYMLINKED-VITEST-BLOCK",
        title: "Symlinked Vitest full validation",
        description: "Plain pnpm test should be redirected to configLoader runner",
        state: "In Progress",
        url: "https://example.org/issues/MT-SYMLINKED-VITEST-BLOCK",
        labels: []
      }

      assert {:error, {:forbidden_command, "pnpm test", "symlinked_vitest_full_test_requires_configLoader_runner"}} =
               AppServer.run(workspace, "Validate integration handoff", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server adds only symlinked Vite temp as writable root for Vitest workspaces" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-symlinked-vitest-temp-root-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-SYMLINKED-VITEST-TEMP")
      dependency_root = Path.join(test_root, "dependency-root")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(Path.join(dependency_root, "node_modules"))
      File.ln_s!(Path.join(dependency_root, "node_modules"), Path.join(workspace, "node_modules"))

      File.write!(
        Path.join(workspace, "package.json"),
        Jason.encode!(%{"scripts" => %{"test" => "vitest run"}})
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-symlinked-vitest-temp"}}}'
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_turn_sandbox_policy: %{
          "type" => "workspaceWrite",
          "writableRoots" => [".", ".git"],
          "readOnlyAccess" => %{"type" => "fullAccess"},
          "networkAccess" => true
        }
      )

      assert {:ok, session} = AppServer.start_session(workspace)

      try do
        expected_vite_temp =
          Path.join([dependency_root, "node_modules", ".vite-temp"])
          |> SymphonyElixir.PathSafety.canonicalize()
          |> elem(1)

        roots = session.turn_sandbox_policy["writableRoots"]
        {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

        assert canonical_workspace in roots
        assert Path.join(canonical_workspace, ".git") in roots
        assert expected_vite_temp in roots
        refute Path.join(dependency_root, "node_modules") in roots
        refute dependency_root in roots
      after
        AppServer.stop_session(session)
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows symlinked Vitest pnpm test with configLoader runner" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-symlinked-vitest-pnpm-test-runner-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-SYMLINKED-VITEST-RUNNER")
      dependency_root = Path.join(test_root, "dependency-root")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(Path.join(dependency_root, "node_modules"))
      File.ln_s!(Path.join(dependency_root, "node_modules"), Path.join(workspace, "node_modules"))

      File.write!(
        Path.join(workspace, "package.json"),
        Jason.encode!(%{"scripts" => %{"test" => "vitest run"}})
      )

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "integration_check",
          "issue" => "MT-SYMLINKED-VITEST-RUNNER",
          "branch" => "orocsy/feature-analytics-observability-integration",
          "requirements" => %{
            "ticket_type" => "integration-check",
            "integration_branch" => "orocsy/feature-analytics-observability-integration",
            "validation" => %{"commands" => ["pnpm test"]},
            "write_scope" => ["Final PR validation notes only"]
          },
          "review" => %{"pr_number" => nil, "pr_url" => nil}
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-symlinked-vitest-runner"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-symlinked-vitest-runner"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"pnpm test -- --configLoader runner"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-symlinked-vitest-runner",
        identifier: "MT-SYMLINKED-VITEST-RUNNER",
        title: "Symlinked Vitest full validation with runner",
        description: "ConfigLoader runner full validation should be allowed",
        state: "In Progress",
        url: "https://example.org/issues/MT-SYMLINKED-VITEST-RUNNER",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate integration handoff", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks integration-check GitHub API field lookup without GET method before progress" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-integration-gh-api-post-preprogress-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-INTEGRATION-GH-BLOCK")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "integration_check",
          "issue" => "MT-INTEGRATION-GH-BLOCK",
          "branch" => "orocsy/feature-analytics-observability-integration",
          "requirements" => %{
            "ticket_type" => "integration-check",
            "integration_branch" => "orocsy/feature-analytics-observability-integration",
            "write_scope" => ["Final PR validation notes only"]
          },
          "review" => %{"pr_number" => nil, "pr_url" => nil}
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-integration-gh-block"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-integration-gh-block"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"gh api repos/orocsy/nutribuddy/pulls -f state=open -f head=orocsy:orocsy/feature-analytics-observability-integration -f base=main"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-integration-gh-block",
        identifier: "MT-INTEGRATION-GH-BLOCK",
        title: "Integration check gh api block",
        description: "Integration-check PR lookup must not use gh api fields without explicit GET",
        state: "In Progress",
        url: "https://example.org/issues/MT-INTEGRATION-GH-BLOCK",
        labels: []
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Validate integration handoff", issue)

      assert command ==
               "gh api repos/orocsy/nutribuddy/pulls -f state=open -f head=orocsy:orocsy/feature-analytics-observability-integration -f base=main"

      assert pattern =~ "gh"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows integration-check branch ref filter for configured branches before progress" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-integration-show-ref-filter-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-INTEGRATION-SHOW-REF")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "integration_check",
          "issue" => "MT-INTEGRATION-SHOW-REF",
          "branch" => "orocsy/feature-analytics-observability-integration",
          "requirements" => %{
            "ticket_type" => "integration-check",
            "branch" => "orocsy/cod-208-analytics-integration-check-and-final-pr-handoff",
            "integration_branch" => "orocsy/feature-analytics-observability-integration",
            "write_scope" => ["Final PR validation notes only"]
          },
          "review" => %{"pr_number" => nil, "pr_url" => nil}
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-integration-show-ref"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-integration-show-ref"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc git show-ref --heads --remotes | grep -E refs/(heads|remotes/origin)/(main|orocsy/feature-analytics-observability-integration|orocsy/cod-208-analytics-integration-check-and-final-pr-handoff)"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-integration-show-ref",
        identifier: "MT-INTEGRATION-SHOW-REF",
        title: "Integration check branch ref filter",
        description: "Integration-check branch ref lookup can filter configured refs before progress",
        state: "In Progress",
        url: "https://example.org/issues/MT-INTEGRATION-SHOW-REF",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate integration handoff", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks integration-check branch ref filter for unrelated branches" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-integration-show-ref-filter-block-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-INTEGRATION-SHOW-REF-BLOCK")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "integration_check",
          "issue" => "MT-INTEGRATION-SHOW-REF-BLOCK",
          "branch" => "orocsy/feature-analytics-observability-integration",
          "requirements" => %{
            "ticket_type" => "integration-check",
            "branch" => "orocsy/cod-208-analytics-integration-check-and-final-pr-handoff",
            "integration_branch" => "orocsy/feature-analytics-observability-integration",
            "write_scope" => ["Final PR validation notes only"]
          },
          "review" => %{"pr_number" => nil, "pr_url" => nil}
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-integration-show-ref-block"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-integration-show-ref-block"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc git show-ref --heads --remotes | grep -E refs/(heads|remotes/origin)/(main|orocsy/unrelated-workstream)"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-integration-show-ref-block",
        identifier: "MT-INTEGRATION-SHOW-REF-BLOCK",
        title: "Integration check branch ref filter block",
        description: "Integration-check branch ref lookup cannot inspect unrelated branches",
        state: "In Progress",
        url: "https://example.org/issues/MT-INTEGRATION-SHOW-REF-BLOCK",
        labels: []
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Validate integration handoff", issue)

      assert command ==
               "/bin/zsh -lc git show-ref --heads --remotes | grep -E refs/(heads|remotes/origin)/(main|orocsy/unrelated-workstream)"

      assert pattern =~ "grep"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows read-only GitHub API review inspection after durable progress" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-gh-api-readonly-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-GH-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      events_dir = Path.join(workspace, ".orocsy/delivery/events")
      events_file = Path.join(events_dir, "events.jsonl")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(events_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-GH-READ",
          "branch" => "orocsy/mt-review-gh-read",
          "review" => %{
            "feedback" => [
              %{
                "path" => "src/app/api/profile/preferences/route.ts",
                "line" => 53,
                "body" => "Resolve preferences from the signed guest session"
              }
            ]
          }
        })
      )

      File.write!(
        events_file,
        Jason.encode!(%{"event" => "tool.finished", "status" => "passed", "tool" => "github-pr-created-and-codex-review-requested"}) <> "\n"
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-gh-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-gh-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"gh api repos/orocsy/nutribuddy/pulls/27/reviews && printf '\\''\\\\n--- review comments ---\\\\n'\\'' && gh api repos/orocsy/nutribuddy/pulls/27/comments && printf '\\''\\\\n--- issue comments ---\\\\n'\\'' && gh api repos/orocsy/nutribuddy/issues/27/comments"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-gh-read",
        identifier: "MT-REVIEW-GH-READ",
        title: "Review rework gh api read",
        description: "Read-only GitHub review endpoints should be allowed after durable handoff progress",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-GH-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle review rework", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows read-only GitHub GraphQL review inspection after durable progress" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-gh-graphql-readonly-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-GH-GRAPHQL-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      events_dir = Path.join(workspace, ".orocsy/delivery/events")
      events_file = Path.join(events_dir, "events.jsonl")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(events_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-GH-GRAPHQL-READ",
          "branch" => "orocsy/mt-review-gh-graphql-read",
          "review" => %{
            "feedback" => [
              %{
                "path" => "src/app/api/profile/preferences/route.ts",
                "line" => 53,
                "body" => "Confirm current review-thread state before handoff"
              }
            ]
          }
        })
      )

      File.write!(
        events_file,
        Jason.encode!(%{"event" => "tool.finished", "status" => "passed", "tool" => "github-pr-created-and-codex-review-requested"}) <> "\n"
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-gh-graphql-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-gh-graphql-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"gh api graphql -f query=query { repository(owner:\\"orocsy\\", name:\\"nutribuddy\\") { pullRequest(number:43) { reviewThreads(first:50) { nodes { isResolved isOutdated comments(first:10) { nodes { body createdAt updatedAt } } } } } } }"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-gh-graphql-read",
        identifier: "MT-REVIEW-GH-GRAPHQL-READ",
        title: "Review rework gh api GraphQL read",
        description: "Read-only GitHub GraphQL review inspection should be allowed after durable handoff progress",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-GH-GRAPHQL-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle review rework", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks mutating GitHub GraphQL after durable progress" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-gh-graphql-mutation-block-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-GH-GRAPHQL-BLOCK")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      events_dir = Path.join(workspace, ".orocsy/delivery/events")
      events_file = Path.join(events_dir, "events.jsonl")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(events_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-GH-GRAPHQL-BLOCK",
          "branch" => "orocsy/mt-review-gh-graphql-block",
          "review" => %{
            "feedback" => [
              %{
                "path" => "src/app/api/profile/preferences/route.ts",
                "line" => 53,
                "body" => "Do not allow GraphQL mutations from workers"
              }
            ]
          }
        })
      )

      File.write!(
        events_file,
        Jason.encode!(%{"event" => "tool.finished", "status" => "passed", "tool" => "github-pr-created-and-codex-review-requested"}) <> "\n"
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-gh-graphql-block"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-gh-graphql-block"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"gh api graphql -f query=mutation { addComment(input:{subjectId:\\"PR_1\\",body:\\"review\\"}) { clientMutationId } }"}}}'
            ;;
          *)
            sleep 1
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
        id: "issue-review-gh-graphql-block",
        identifier: "MT-REVIEW-GH-GRAPHQL-BLOCK",
        title: "Review rework gh api GraphQL mutation block",
        description: "Mutating GitHub GraphQL should stay blocked after durable handoff progress",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-GH-GRAPHQL-BLOCK",
        labels: []
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Handle review rework", issue)

      assert command ==
               "gh api graphql -f query=mutation { addComment(input:{subjectId:\"PR_1\",body:\"review\"}) { clientMutationId } }"

      assert pattern == "(^|\\s|[\"'])gh\\s+api(\\s|$)"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks GitHub API merge endpoint after fresh implementation progress" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fresh-implementation-gh-api-merge-block-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-FRESH-GH-MERGE-BLOCK")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      events_dir = Path.join(workspace, ".orocsy/delivery/events")
      events_file = Path.join(events_dir, "events.jsonl")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(events_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "fresh_implementation",
          "issue" => "MT-FRESH-GH-MERGE-BLOCK",
          "branch" => "orocsy/mt-fresh-gh-merge-block",
          "requirements" => %{
            "ticket_type" => "implementation",
            "write_scope" => ["src/app/page.tsx"]
          }
        })
      )

      File.write!(
        events_file,
        Jason.encode!(%{"event" => "tool.finished", "status" => "passed", "tool" => "technical-miu-trace"}) <> "\n"
      )

      write_fresh_checkpoint_git_progress!(workspace, "src/app/page.tsx")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fresh-gh-merge-block"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fresh-gh-merge-block"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"gh api repos/orocsy/nutribuddy/issues/9/comments -f body=@codex-review && gh api repos/orocsy/nutribuddy/pulls/9/merge -X PUT -f merge_method=merge"}}}'
            ;;
          *)
            sleep 1
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
        id: "issue-fresh-gh-merge-block",
        identifier: "MT-FRESH-GH-MERGE-BLOCK",
        title: "Fresh MIU gh api merge block",
        description: "GitHub API merge endpoint should not be allowed from workers",
        state: "In Progress",
        url: "https://example.org/issues/MT-FRESH-GH-MERGE-BLOCK",
        labels: []
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Implement fresh MIU", issue)

      assert command ==
               "gh api repos/orocsy/nutribuddy/issues/9/comments -f body=@codex-review && gh api repos/orocsy/nutribuddy/pulls/9/merge -X PUT -f merge_method=merge"

      assert pattern == "(^|\\s|[\"'])gh\\s+api(\\s|$)"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks broad search commands in review rework mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-forbidden-search-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-SEARCH")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-SEARCH",
          "branch" => "orocsy/mt-review-search"
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-search"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-search"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"rg -n \\"recipeChat|savedRecipe\\" src"}}}'
            ;;
          *)
            sleep 1
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
        id: "issue-review-search",
        identifier: "MT-REVIEW-SEARCH",
        title: "Review rework search",
        description: "Search should be blocked in review rework",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-SEARCH",
        labels: []
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Fix review feedback", issue)

      assert command == ~s(rg -n "recipeChat|savedRecipe" src)
      assert pattern == "(^|\\s|[\"'])rg(\\s|$)"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks git ls-files rediscovery in review rework mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-forbidden-git-ls-files-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-GIT-LS")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-GIT-LS",
          "branch" => "orocsy/mt-review-git-ls"
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-git-ls"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-git-ls"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"git ls-files src/features/swipe"}}}'
            ;;
          *)
            sleep 1
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
        id: "issue-review-git-ls",
        identifier: "MT-REVIEW-GIT-LS",
        title: "Review rework git ls-files",
        description: "git ls-files should be blocked in review rework",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-GIT-LS",
        labels: []
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Fix review feedback", issue)

      assert command == "git ls-files src/features/swipe"
      assert pattern == "(^|\\s|[\"'])git\\s+ls-files(\\s|$)"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks sideways file reads in review rework mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-sideways-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-READ",
          "branch" => "orocsy/mt-review-read",
          "review" => %{
            "feedback" => [
              %{"path" => "src/features/swipe/SwipeDeck.tsx", "line" => 81}
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"sed -n '\\''1,260p'\\'' src/app/api/swipes/handler.ts"}}}'
            ;;
          *)
            sleep 1
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
        id: "issue-review-read",
        identifier: "MT-REVIEW-READ",
        title: "Review rework read",
        description: "Sideways reads should be blocked in review rework",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-READ",
        labels: []
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Fix review feedback", issue)

      assert command == "sed -n '1,260p' src/app/api/swipes/handler.ts"
      assert pattern =~ "sed"
      assert pattern =~ "SwipeDeck"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks implementation child imported-file reads in review rework mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-implementation-import-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      inbox_dir = Path.join(workspace, ".orocsy/delivery/inbox")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(inbox_dir)
      File.mkdir_p!(Path.join(workspace, "src/features/swipe"))
      File.mkdir_p!(Path.join(workspace, "src/app/api/cards"))

      File.write!(
        Path.join(workspace, "src/features/swipe/SwipeExperience.tsx"),
        "import { SwipeDeck } from './SwipeDeck';\nexport function SwipeExperience() { return SwipeDeck; }\n"
      )

      File.write!(
        Path.join(workspace, "src/features/swipe/SwipeDeck.tsx"),
        "export function SwipeDeck() { return null; }\n"
      )

      File.write!(Path.join(workspace, "src/app/api/cards/route.ts"), "export const GET = () => Response.json([]);\n")

      File.write!(
        Path.join(inbox_dir, "correction_20260706060118_guard.json"),
        Jason.encode!(%{
          "correction_id" => "correction_20260706060118_guard",
          "status" => "resolved",
          "source" => "symphony.runtime.command-guard-loop",
          "resolved_at" => "2026-07-06T06:05:39Z",
          "summary" => "Previous failed runtime guard mentioned src/app/api/cards/route.ts.",
          "findings" => ["Worker read src/app/api/cards/route.ts before stopping."],
          "required_corrections" => ["Validation failed before product progress."]
        })
      )

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-IMPLEMENTATION-IMPORT-READ",
          "branch" => "orocsy/mt-review-implementation-import-read",
          "requirements" => %{
            "ticket_type" => "implementation",
            "write_scope" => [
              "src/features/swipe/SwipeExperience.tsx",
              "tests/unit/swipe-experience-request.test.ts"
            ],
            "validation" => %{
              "commands" => [
                "pnpm exec vitest run --configLoader runner tests/unit/swipe-experience-request.test.ts"
              ],
              "files" => []
            }
          },
          "review" => %{
            "feedback" => [
              %{"path" => "src/features/swipe/SwipeExperience.tsx", "line" => 105}
            ]
          }
        })
      )

      patterns = AppServer.effective_forbidden_command_patterns_for(workspace)
      joined = Enum.join(patterns, "\n")

      assert joined =~ "SwipeExperience"
      refute joined =~ "SwipeDeck"
      refute joined =~ "route"

      sideways_command = "sed -n 260,560p src/features/swipe/SwipeDeck.tsx"
      leaked_route_command = "sed -n 1,220p src/app/api/cards/route.ts"
      allowed_command = "sed -n 1,220p src/features/swipe/SwipeExperience.tsx"

      assert Enum.any?(patterns, &Regex.match?(Regex.compile!(&1), sideways_command))
      assert Enum.any?(patterns, &Regex.match?(Regex.compile!(&1), leaked_route_command))
      refute Enum.any?(patterns, &Regex.match?(Regex.compile!(&1), allowed_command))
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows quoted current feedback path reads in review rework mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-quoted-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-QUOTED-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-QUOTED-READ",
          "branch" => "orocsy/mt-review-quoted-read",
          "review" => %{
            "feedback" => [
              %{"path" => "src/app/api/recipe-chats/[chatId]/messages/route.ts", "line" => 81}
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-quoted-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-quoted-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"sed -n \\"1,80p\\" \\"src/app/api/recipe-chats/[chatId]/messages/route.ts\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-quoted-read",
        identifier: "MT-REVIEW-QUOTED-READ",
        title: "Review rework quoted read",
        description: "Quoted current feedback path reads should be allowed in review rework",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-QUOTED-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows sibling Next route helper reads for review rework routes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-route-helper-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-ROUTE-HELPER-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      route_dir = Path.join(workspace, "src/app/api/recipe-chats/[chatId]/messages")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(route_dir)
      File.write!(Path.join(route_dir, "route.ts"), "export { POST } from './handler';\n")
      File.write!(Path.join(route_dir, "handler.ts"), "export function POST() {}\n")

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-ROUTE-HELPER-READ",
          "branch" => "orocsy/mt-review-route-helper-read",
          "review" => %{
            "feedback" => [
              %{"path" => "src/app/api/recipe-chats/[chatId]/messages/route.ts", "line" => 8}
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-route-helper-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-route-helper-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''1,70p'\\'' '\\''src/app/api/recipe-chats/[chatId]/messages/handler.ts'\\''\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-route-helper-read",
        identifier: "MT-REVIEW-ROUTE-HELPER-READ",
        title: "Review rework route helper read",
        description: "Sibling route helper reads should be allowed for route review feedback",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-ROUTE-HELPER-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows missing sibling Next route helper test reads for review rework routes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-route-helper-test-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-ROUTE-HELPER-TEST-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      route_dir = Path.join(workspace, "src/app/api/recipe-chats/[chatId]/messages")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(route_dir)
      File.write!(Path.join(route_dir, "route.ts"), "export { POST } from './handler';\n")

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-ROUTE-HELPER-TEST-READ",
          "branch" => "orocsy/mt-review-route-helper-test-read",
          "review" => %{
            "feedback" => [
              %{"path" => "src/app/api/recipe-chats/[chatId]/messages/route.ts", "line" => 30}
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-route-helper-test-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-route-helper-test-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''1,220p'\\'' '\\''src/app/api/recipe-chats/[chatId]/messages/handler.test.ts'\\''\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-route-helper-test-read",
        identifier: "MT-REVIEW-ROUTE-HELPER-TEST-READ",
        title: "Review rework route helper test read",
        description: "Sibling route helper test reads should be allowed for route review feedback",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-ROUTE-HELPER-TEST-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows transitive local import reads during review rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-transitive-import-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-TRANSITIVE-IMPORT-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      guest_limit_file = Path.join(workspace, "src/lib/domain/guest-limit.ts")
      domain_index_file = Path.join(workspace, "src/lib/domain/index.ts")
      schemas_index_file = Path.join(workspace, "src/lib/schemas/index.ts")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(Path.dirname(guest_limit_file))
      File.mkdir_p!(Path.dirname(schemas_index_file))
      File.write!(guest_limit_file, "import type { GuestLimitState } from './index';\n")
      File.write!(domain_index_file, "import type { guestLimitStateSchema } from '../schemas';\n")
      File.write!(schemas_index_file, "export const guestLimitStateSchema = {};\n")

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-TRANSITIVE-IMPORT-READ",
          "branch" => "orocsy/mt-review-transitive-import-read",
          "requirements" => %{
            "write_scope" => [
              "src/lib/domain/guest-limit.ts"
            ]
          },
          "review" => %{
            "feedback" => [
              %{
                "path" => "src/features/swipe/SwipeDeck.tsx",
                "line" => 274,
                "body" => "Preserve unlocked swipe state when migration omits guestLimit."
              }
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-transitive-import-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-transitive-import-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''1,220p'\\'' src/lib/schemas.ts\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-transitive-import-read",
        identifier: "MT-REVIEW-TRANSITIVE-IMPORT-READ",
        title: "Review rework transitive import read",
        description: "Second-hop local support imports and missing extension candidates should stay inside the read-only guard",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-TRANSITIVE-IMPORT-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows tsconfig alias import reads during review rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-alias-import-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-ALIAS-IMPORT-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      tsconfig_file = Path.join(workspace, "tsconfig.json")
      recipe_chats_file = Path.join(workspace, "src/lib/server/recipe-chats.ts")
      recipe_chat_ids_file = Path.join(workspace, "src/lib/domain/recipe-chat-ids.ts")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(Path.dirname(recipe_chats_file))
      File.mkdir_p!(Path.dirname(recipe_chat_ids_file))

      File.write!(
        tsconfig_file,
        Jason.encode!(%{"compilerOptions" => %{"paths" => %{"@/*" => ["./src/*"]}}})
      )

      File.write!(
        recipe_chats_file,
        "import { createRecipeChatId } from '@/lib/domain/recipe-chat-ids';\n"
      )

      File.write!(
        recipe_chat_ids_file,
        "export function createRecipeChatId(): string { return 'chat_test'; }\n"
      )

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-ALIAS-IMPORT-READ",
          "branch" => "orocsy/mt-review-alias-import-read",
          "requirements" => %{
            "write_scope" => [
              "src/lib/server/recipe-chats.ts"
            ]
          },
          "review" => %{
            "feedback" => [
              %{
                "path" => "src/lib/server/recipe-chats.ts",
                "line" => 524,
                "body" => "Create post-signup chats with authenticated ownership."
              }
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-alias-import-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-alias-import-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''1,120p'\\'' src/lib/domain/recipe-chat-ids.ts\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-alias-import-read",
        identifier: "MT-REVIEW-ALIAS-IMPORT-READ",
        title: "Review rework alias import read",
        description: "Project alias support imports should stay inside the read-only guard",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-ALIAS-IMPORT-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks shell-wrapped reads outside review feedback paths" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-shell-wrapped-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-SHELL-WRAPPED-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-SHELL-WRAPPED-READ",
          "branch" => "orocsy/mt-review-shell-wrapped-read",
          "review" => %{
            "feedback" => [
              %{"path" => "src/app/api/swipes/handler.ts", "line" => 84}
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-shell-wrapped-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-shell-wrapped-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''1,180p'\\'' src/app/api/recipe-chats/route.ts\\""}}}'
            ;;
          *)
            sleep 1
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
        id: "issue-review-shell-wrapped-read",
        identifier: "MT-REVIEW-SHELL-WRAPPED-READ",
        title: "Review rework shell wrapped read",
        description: "Shell-wrapped sideways reads should be blocked in review rework",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-SHELL-WRAPPED-READ",
        labels: []
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Fix review feedback", issue)

      assert command == ~s(/bin/zsh -lc "sed -n '1,180p' src/app/api/recipe-chats/route.ts")
      assert pattern =~ "sed"
      assert pattern =~ "swipes/handler"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows shell-wrapped current feedback path reads in review rework mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-shell-wrapped-allowed-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-SHELL-WRAPPED-ALLOWED-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-SHELL-WRAPPED-ALLOWED-READ",
          "branch" => "orocsy/mt-review-shell-wrapped-allowed-read",
          "review" => %{
            "feedback" => [
              %{"path" => "src/app/api/swipes/handler.ts", "line" => 84}
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-shell-wrapped-allowed-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-shell-wrapped-allowed-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''1,120p'\\'' src/app/api/swipes/handler.ts\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-shell-wrapped-allowed-read",
        identifier: "MT-REVIEW-SHELL-WRAPPED-ALLOWED-READ",
        title: "Review rework shell wrapped allowed read",
        description: "Shell-wrapped current feedback path reads should be allowed in review rework",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-SHELL-WRAPPED-ALLOWED-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows missing referenced support file reads in review rework mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-missing-referenced-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-MISSING-REFERENCED-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      profile_file = Path.join(workspace, "src/features/profile/index.tsx")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(Path.dirname(profile_file))
      File.write!(profile_file, "export function activeAuthProvider() { return 'custom-email-token'; }\n")

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-MISSING-REFERENCED-READ",
          "branch" => "orocsy/mt-review-missing-referenced-read",
          "review" => %{
            "feedback" => [
              %{
                "path" => "src/features/profile/index.tsx",
                "line" => 143,
                "body" => "Honor AUTH_PROVIDER_MODE=fake and NEXT_PUBLIC_AUTH_PROVIDER when choosing the signup provider."
              }
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-missing-referenced-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-missing-referenced-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''1,180p'\\'' src/lib/auth/provider-config.ts\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-missing-referenced-read",
        identifier: "MT-REVIEW-MISSING-REFERENCED-READ",
        title: "Review rework missing referenced read",
        description: "Missing support paths named by review concepts should fail in-shell, not at the guard",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-MISSING-REFERENCED-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows reads of existing api route files referenced by review endpoints" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-referenced-api-route-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-REFERENCED-API-ROUTE-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      profile_file = Path.join(workspace, "src/features/profile/index.tsx")
      route_file = Path.join(workspace, "src/app/api/auth/email-token/signup/route.ts")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(Path.dirname(profile_file))
      File.mkdir_p!(Path.dirname(route_file))
      File.write!(profile_file, "export function activeAuthProvider() { return 'custom-email-token'; }\n")
      File.write!(route_file, "export async function POST() { return Response.json({ ok: true }); }\n")

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-REFERENCED-API-ROUTE-READ",
          "branch" => "orocsy/mt-review-referenced-api-route-read",
          "review" => %{
            "feedback" => [
              %{
                "path" => "src/features/profile/index.tsx",
                "line" => 146,
                "body" => "In fake mode this client submits /api/auth/email-token/signup, which returns AUTH_PROVIDER_DISABLED."
              }
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-referenced-api-route-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-referenced-api-route-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''1,220p'\\'' src/app/api/auth/email-token/signup/route.ts\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-referenced-api-route-read",
        identifier: "MT-REVIEW-REFERENCED-API-ROUTE-READ",
        title: "Review rework referenced api route read",
        description: "Endpoint URLs named by review feedback should allow the matching Next route read",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-REFERENCED-API-ROUTE-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows package metadata reads for review rework validation" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-package-validation-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-PACKAGE-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.write!(Path.join(workspace, "package.json"), ~s({"scripts":{"typecheck":"tsc --noEmit"}}\n))

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-PACKAGE-READ",
          "branch" => "orocsy/mt-review-package-read",
          "review" => %{
            "feedback" => [
              %{"path" => "src/features/profile/index.tsx", "line" => 147}
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-package-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-package-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''1,120p'\\'' package.json\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-package-read",
        identifier: "MT-REVIEW-PACKAGE-READ",
        title: "Review rework package validation read",
        description: "package.json reads should be allowed only as validation metadata",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-PACKAGE-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows vitest config reads for review rework validation" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-vitest-validation-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-VITEST-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.write!(Path.join(workspace, "vitest.config.ts"), "export default {};\n")

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-VITEST-READ",
          "branch" => "orocsy/mt-review-vitest-read",
          "review" => %{
            "feedback" => [
              %{"path" => "src/features/profile/index.tsx", "line" => 147}
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-vitest-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-vitest-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''1,220p'\\'' vitest.config.ts\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-vitest-read",
        identifier: "MT-REVIEW-VITEST-READ",
        title: "Review rework vitest validation read",
        description: "Vitest config reads should be allowed only as validation metadata",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-VITEST-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows review rework reads for validation files named by runtime corrections" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-correction-validation-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-CORRECTION-VALIDATION-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      inbox_dir = Path.join(workspace, ".orocsy/delivery/inbox")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      correction_file = Path.join(inbox_dir, "correction_validation_read.json")
      profile_file = Path.join(workspace, "src/features/profile/index.tsx")
      failing_test_file = Path.join(workspace, "tests/unit/swipe-deck.test.ts")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(inbox_dir)
      File.mkdir_p!(Path.dirname(profile_file))
      File.mkdir_p!(Path.dirname(failing_test_file))
      File.write!(profile_file, "export function activeAuthProvider() { return 'custom-email-token'; }\n")
      File.write!(failing_test_file, "test('swipe deck auth fallback', () => expect(true).toBe(true));\n")

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-CORRECTION-VALIDATION-READ",
          "branch" => "orocsy/mt-review-correction-validation-read",
          "review" => %{
            "feedback" => [
              %{"path" => "src/features/profile/index.tsx", "line" => 139}
            ]
          }
        })
      )

      File.write!(
        correction_file,
        Jason.encode!(%{
          "source" => "symphony.runtime.permission",
          "status" => "resolved",
          "findings" => [
            "pnpm test failed in tests/unit/swipe-deck.test.ts before the worker could inspect the failing assertion."
          ]
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-correction-validation-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-correction-validation-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''230,285p'\\'' tests/unit/swipe-deck.test.ts\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-correction-validation-read",
        identifier: "MT-REVIEW-CORRECTION-VALIDATION-READ",
        title: "Review rework correction validation read",
        description: "Runtime correction evidence should allow a read-only failing test inspection",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-CORRECTION-VALIDATION-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Continue validation rework", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks chrome-default playwright retry for browser launch corrections" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-playwright-chromium-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-PLAYWRIGHT-GUARD")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      inbox_dir = Path.join(workspace, ".orocsy/delivery/inbox")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      correction_file = Path.join(inbox_dir, "correction_20260626160144_0a19a053.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(inbox_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-PLAYWRIGHT-GUARD",
          "branch" => "orocsy/mt-review-playwright-guard",
          "review" => %{"feedback" => []}
        })
      )

      File.write!(
        correction_file,
        Jason.encode!(%{
          "correction_id" => "correction_20260626160144_0a19a053",
          "status" => "open",
          "next_action" => "retry",
          "summary" => "Focused Playwright validation blocked by local Chrome launch sandbox",
          "findings" => [
            "browserType.launch failed because Google Chrome exited SIGABRT; cleanup logged kill EPERM."
          ],
          "required_corrections" => [
            "Retry focused validation with the safe Chromium channel."
          ]
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-playwright-guard"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-playwright-guard"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN=false pnpm --config.verify-deps-before-run=false exec playwright test tests/e2e/ui-state-matrix.spec.ts"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-playwright-guard",
        identifier: "MT-REVIEW-PLAYWRIGHT-GUARD",
        title: "Review rework Playwright guard",
        description: "Chrome-default Playwright retries should be blocked under browser launch corrections",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-PLAYWRIGHT-GUARD",
        labels: []
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Continue validation rework", issue)

      assert command ==
               "PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN=false pnpm --config.verify-deps-before-run=false exec playwright test tests/e2e/ui-state-matrix.spec.ts"

      assert pattern == "playwright_chrome_sandbox_correction_requires_chromium_channel"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows bounded exact test file rg during review rework validation" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-exact-test-rg-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-EXACT-TEST-RG")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      route_file = Path.join(workspace, "src/app/api/cards/route.ts")
      cards_test = Path.join(workspace, "tests/integration/cards-route.test.ts")
      rework_test = Path.join(workspace, "tests/unit/cod-205-review-rework.test.ts")
      analytics_test = Path.join(workspace, "tests/integration/analytics-instrumentation.test.ts")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(Path.dirname(route_file))
      File.mkdir_p!(Path.dirname(cards_test))
      File.mkdir_p!(Path.dirname(rework_test))
      File.mkdir_p!(Path.dirname(analytics_test))

      File.write!(route_file, "export async function GET() { return Response.json({ ok: true }); }\n")
      File.write!(cards_test, "test('records start_clicked', () => expect(true).toBe(true));\n")
      File.write!(rework_test, "test('keeps guestLimit', () => expect(true).toBe(true));\n")
      File.write!(analytics_test, "test('records card_served', () => expect(true).toBe(true));\n")

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-EXACT-TEST-RG",
          "branch" => "orocsy/mt-review-exact-test-rg",
          "requirements" => %{
            "write_scope" => [
              "src/app/api/cards/route.ts",
              "tests/integration/analytics-instrumentation.test.ts only to activate/update existing specs"
            ],
            "validation" => %{
              "commands" => [
                "pnpm exec vitest run --configLoader runner tests/integration/analytics-instrumentation.test.ts",
                "pnpm test -- --configLoader runner"
              ]
            }
          },
          "review" => %{
            "feedback" => [
              %{
                "path" => "src/app/api/cards/route.ts",
                "line" => 103,
                "body" => "Reuse existing guest session before creating one on cards load."
              }
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-exact-test-rg"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-exact-test-rg"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"rg -n start_clicked tests/integration/cards-route.test.ts tests/unit/cod-205-review-rework.test.ts tests/integration/analytics-instrumentation.test.ts\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-exact-test-rg",
        identifier: "MT-REVIEW-EXACT-TEST-RG",
        title: "Review rework exact test rg",
        description: "Exact test file rg after validation failure should stay inside the read-only guard",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-EXACT-TEST-RG",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Continue review validation", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows bounded exact test/spec candidate rg during review rework validation" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-exact-test-candidate-rg-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-EXACT-TEST-CANDIDATE-RG")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      handler_file = Path.join(workspace, "src/app/api/cards/handler.ts")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(Path.dirname(handler_file))

      File.write!(handler_file, "export async function handleCardsRequest() { return Response.json({ ok: true }); }\n")

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-EXACT-TEST-CANDIDATE-RG",
          "branch" => "orocsy/mt-review-exact-test-candidate-rg",
          "requirements" => %{
            "write_scope" => [
              "src/app/api/cards/handler.ts"
            ],
            "validation" => %{
              "commands" => [
                "pnpm test -- --configLoader runner"
              ]
            }
          },
          "review" => %{
            "feedback" => [
              %{
                "path" => "src/app/api/cards/handler.ts",
                "line" => 91,
                "body" => "Avoid creating guest sessions from unrelated cookies."
              }
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-exact-test-candidate-rg"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-exact-test-candidate-rg"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"rg -n '\\''handleCardsRequest'\\'' src/app/api/cards/handler.test.ts src/app/api/cards/route.test.ts src/app/api/cards/route.spec.ts tests/api/cards.test.ts\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-exact-test-candidate-rg",
        identifier: "MT-REVIEW-EXACT-TEST-CANDIDATE-RG",
        title: "Review rework exact test candidate rg",
        description: "Exact test/spec candidate file rg should stay inside the read-only guard",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-EXACT-TEST-CANDIDATE-RG",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Continue review validation", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows bounded exact reviewed source file rg during review rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-exact-source-rg-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-EXACT-SOURCE-RG")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      store_file = Path.join(workspace, "src/lib/db/guest-session-store.ts")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(Path.dirname(store_file))

      File.write!(store_file, """
      export class D1GuestSessionStore {}
      export function attemptGuestSwipe() { return true; }
      export function applyGuestSwipeDecision() { return true; }
      """)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-EXACT-SOURCE-RG",
          "branch" => "orocsy/feature-cloudflare-infra-integration",
          "requirements" => %{
            "write_scope" => [
              "src/lib/db/guest-session-store.ts",
              "tests/** only for focused regression tests"
            ]
          },
          "review" => %{
            "feedback" => [
              %{
                "path" => "src/lib/db/guest-session-store.ts",
                "line" => 228,
                "body" => "Preserve swipe rollback when handoff fails."
              }
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-exact-source-rg"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-exact-source-rg"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc '\\''rg -n \\"applyGuestSwipeDecision|class D1GuestSessionStore|attemptGuestSwipe\\" src/lib/db/guest-session-store.ts'\\''"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-exact-source-rg",
        identifier: "MT-REVIEW-EXACT-SOURCE-RG",
        title: "Review rework exact source rg",
        description: "Exact reviewed source file rg should stay inside the read-only guard",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-EXACT-SOURCE-RG",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Continue review validation", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks bare test directory rg during review rework validation" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-bare-test-dir-rg-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-BARE-TEST-DIR-RG")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      route_file = Path.join(workspace, "src/app/api/cards/route.ts")
      analytics_test = Path.join(workspace, "tests/integration/analytics-instrumentation.test.ts")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(Path.dirname(route_file))
      File.mkdir_p!(Path.dirname(analytics_test))

      File.write!(route_file, "export async function GET() { return Response.json({ ok: true }); }\n")
      File.write!(analytics_test, "test('records card_served', () => expect(true).toBe(true));\n")

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-BARE-TEST-DIR-RG",
          "branch" => "orocsy/mt-review-bare-test-dir-rg",
          "requirements" => %{
            "write_scope" => [
              "src/app/api/cards/route.ts",
              "tests/integration/analytics-instrumentation.test.ts only to activate/update existing specs"
            ]
          },
          "review" => %{
            "feedback" => [
              %{
                "path" => "src/app/api/cards/route.ts",
                "line" => 103,
                "body" => "Reuse existing guest session before creating one on cards load."
              }
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-bare-test-dir-rg"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-bare-test-dir-rg"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"rg -n start_clicked tests/integration tests/integration/analytics-instrumentation.test.ts\\""}}}'
            ;;
          *)
            sleep 1
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
        id: "issue-review-bare-test-dir-rg",
        identifier: "MT-REVIEW-BARE-TEST-DIR-RG",
        title: "Review rework bare test dir rg",
        description: "Bare test directory rg should stay blocked in review rework",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-BARE-TEST-DIR-RG",
        labels: []
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Continue review validation", issue)

      assert command ==
               ~s(/bin/zsh -lc "rg -n start_clicked tests/integration tests/integration/analytics-instrumentation.test.ts")

      assert pattern == "(^|\\s|[\"'])rg(\\s|$)"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows scoped conflict marker grep during integration check" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-integration-check-conflict-grep-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-INTEGRATION-CONFLICT-GREP")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "integration_check",
          "issue" => "MT-INTEGRATION-CONFLICT-GREP",
          "branch" => "orocsy/mt-integration-conflict-grep",
          "requirements" => %{
            "write_scope" => [
              "src/app/api/recipe-chats/route.ts",
              "tests/integration/recipe-chat-routes.test.ts"
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-integration-conflict-grep"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-integration-conflict-grep"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc grep -R ^<<<<<<< ^======= ^>>>>>>> -n src/app/api/recipe-chats/route.ts tests/integration/recipe-chat-routes.test.ts"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-integration-conflict-grep",
        identifier: "MT-INTEGRATION-CONFLICT-GREP",
        title: "Integration conflict marker grep",
        description: "Scoped conflict marker grep should be allowed during integration checks",
        state: "Rework",
        url: "https://example.org/issues/MT-INTEGRATION-CONFLICT-GREP",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Resolve integration conflicts", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows scoped file grep during integration check" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-integration-check-file-grep-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-INTEGRATION-FILE-GREP")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-integration-file-grep.trace")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "integration_check",
          "issue" => "MT-INTEGRATION-FILE-GREP",
          "branch" => "orocsy/mt-integration-file-grep",
          "requirements" => %{
            "write_scope" => [
              "src/lib/server/recipe-chats.ts"
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-integration-file-grep.trace}"
      count=0
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-integration-file-grep"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-integration-file-grep"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc grep -n migrateRecipeChats\\\\\\\\|resetRecipeChats src/lib/server/recipe-chats.ts"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-integration-file-grep",
        identifier: "MT-INTEGRATION-FILE-GREP",
        title: "Integration scoped file grep",
        description: "Scoped file grep should be allowed during integration checks",
        state: "Rework",
        url: "https://example.org/issues/MT-INTEGRATION-FILE-GREP",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Resolve integration validation", issue)

      thread_start =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["method"] == "thread/start"))

      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "Current Validation Rework"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "do not just rerun the same failing validation"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "dirty handoff recovery"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "validation fails and names the exact broken file"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "handoff.integration-check-started"
      assert get_in(thread_start, ["params", "developerInstructions"]) =~ "before any `gh pr`"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server allows scoped rg during integration validation rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-integration-check-file-rg-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-INTEGRATION-FILE-RG")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "integration_check",
          "issue" => "MT-INTEGRATION-FILE-RG",
          "branch" => "orocsy/mt-integration-file-rg",
          "requirements" => %{
            "write_scope" => [
              "src/lib/server/recipe-chat-page-view.ts",
              "tests/integration/recipe-chat-routes.test.ts"
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-integration-file-rg"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-integration-file-rg"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"rg -n \\"fallbackActor\\" src/lib/server/recipe-chat-page-view.ts tests/integration/recipe-chat-routes.test.ts"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-integration-file-rg",
        identifier: "MT-INTEGRATION-FILE-RG",
        title: "Integration scoped file rg",
        description: "Scoped rg should be allowed during validation rework",
        state: "Rework",
        url: "https://example.org/issues/MT-INTEGRATION-FILE-RG",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Resolve integration validation", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks bare-directory rg during integration validation rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-integration-check-bare-dir-rg-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-INTEGRATION-BARE-DIR-RG")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "integration_check",
          "issue" => "MT-INTEGRATION-BARE-DIR-RG",
          "branch" => "orocsy/mt-integration-bare-dir-rg",
          "requirements" => %{
            "write_scope" => [
              "src/lib/server/recipe-chat-page-view.ts",
              "tests/integration/recipe-chat-routes.test.ts"
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-integration-bare-dir-rg"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-integration-bare-dir-rg"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"rg -n \\"fallbackActor\\" src tests/integration/recipe-chat-routes.test.ts"}}}'
            ;;
          *)
            sleep 1
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
        id: "issue-integration-bare-dir-rg",
        identifier: "MT-INTEGRATION-BARE-DIR-RG",
        title: "Integration bare directory rg",
        description: "Bare-directory rg should stay blocked during validation rework",
        state: "Rework",
        url: "https://example.org/issues/MT-INTEGRATION-BARE-DIR-RG",
        labels: []
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Resolve integration validation", issue)

      assert command == ~s(rg -n "fallbackActor" src tests/integration/recipe-chat-routes.test.ts)
      assert pattern == "(^|\\s|[\"'])rg(\\s|$)"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows shell-wrapped reads for paths named in review feedback body" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-feedback-body-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-FEEDBACK-BODY-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-FEEDBACK-BODY-READ",
          "branch" => "orocsy/mt-review-feedback-body-read",
          "review" => %{
            "feedback" => [
              %{
                "path" => "src/app/api/recipe-chats/route.ts",
                "line" => 508,
                "body" => "Wire DeepSeek selection into follow-up messages in `src/app/api/recipe-chats/[chatId]/messages/route.ts`."
              }
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-feedback-body-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-feedback-body-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''150,230p'\\'' src/app/api/recipe-chats/[chatId]/messages/route.ts\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-feedback-body-read",
        identifier: "MT-REVIEW-FEEDBACK-BODY-READ",
        title: "Review rework feedback body read",
        description: "Review feedback body paths should be allowed in review rework",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-FEEDBACK-BODY-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows shell-wrapped local source import reads from current feedback files" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-local-import-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-LOCAL-IMPORT-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      test_file = Path.join(workspace, "tests/integration/auth-boundary.test.ts")
      source_file = Path.join(workspace, "src/lib/auth/auth-boundary.ts")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(Path.dirname(test_file))
      File.mkdir_p!(Path.dirname(source_file))

      File.write!(test_file, """
      import { resolveActorFromSession } from "../../src/lib/auth/auth-boundary";

      resolveActorFromSession({ guestId: "guest-123" });
      """)

      File.write!(source_file, """
      export function resolveActorFromSession(input: unknown) {
        return input;
      }
      """)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-LOCAL-IMPORT-READ",
          "branch" => "orocsy/mt-review-local-import-read",
          "review" => %{
            "feedback" => [
              %{
                "path" => "tests/integration/auth-boundary.test.ts",
                "line" => 23,
                "body" => "Replace fake auth helpers with real boundary calls."
              }
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-local-import-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-local-import-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''1,160p'\\'' src/lib/auth/auth-boundary.ts\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-local-import-read",
        identifier: "MT-REVIEW-LOCAL-IMPORT-READ",
        title: "Review rework local import read",
        description: "Shell-wrapped local source import reads should be allowed in review rework",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-LOCAL-IMPORT-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows review-referenced root config reads in review rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-root-config-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-ROOT-CONFIG-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      root_config = Path.join(workspace, "opennext.js")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(root_config, """
      export default {};
      """)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-ROOT-CONFIG-READ",
          "branch" => "orocsy/mt-review-root-config-read",
          "review" => %{
            "feedback" => [
              %{
                "path" => "src/lib/server/recipe-chats.ts",
                "line" => 42,
                "body" => "Confirm the root OpenNext config in `opennext.js` before the provider review fix."
              }
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-root-config-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-root-config-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''1,120p'\\'' opennext.js\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-root-config-read",
        identifier: "MT-REVIEW-ROOT-CONFIG-READ",
        title: "Review rework root config read",
        description: "Review feedback body root config paths should be allowed in review rework",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-ROOT-CONFIG-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows shell-wrapped declared support path reads in review rework mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-shell-wrapped-support-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-SHELL-WRAPPED-SUPPORT-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-SHELL-WRAPPED-SUPPORT-READ",
          "branch" => "orocsy/mt-review-shell-wrapped-support-read",
          "review" => %{
            "feedback" => [
              %{"path" => "src/app/api/swipes/handler.ts", "line" => 84}
            ]
          },
          "requirements" => %{
            "write_scope" => [
              "`src/app/api/swipes/handler.ts`"
            ],
            "shared_files" => [
              "Read-only support path: `src/app/api/recipe-chats/route.ts`"
            ],
            "validation" => %{
              "files" => [
                "`tests/integration/saved-recipes-route.test.ts`"
              ],
              "commands" => [
                "pnpm exec vitest run --configLoader runner tests/integration/saved-recipes-route.test.ts"
              ]
            }
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-shell-wrapped-support-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-shell-wrapped-support-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''1,180p'\\'' src/app/api/recipe-chats/route.ts\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-shell-wrapped-support-read",
        identifier: "MT-REVIEW-SHELL-WRAPPED-SUPPORT-READ",
        title: "Review rework shell wrapped support read",
        description: "Shell-wrapped declared support path reads should be allowed in review rework",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-SHELL-WRAPPED-SUPPORT-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows shell-wrapped reads for issue brief paths in review rework mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-issue-brief-path-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-ISSUE-BRIEF-PATH-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      issue_brief = Path.join(workspace, ".orocsy/delivery/issue-brief.md")
      test_file = Path.join(workspace, "tests/unit/telemetry-logger.test.ts")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(Path.dirname(issue_brief))
      File.mkdir_p!(Path.dirname(test_file))

      File.write!(issue_brief, """
      ## Write Scope

      - `tests/unit/telemetry-logger.test.ts`

      ## Validation

      - `pnpm exec vitest run --configLoader runner tests/unit/telemetry-logger.test.ts`
      """)

      File.write!(test_file, "test('redacts nested telemetry payloads', () => {})\n")

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-ISSUE-BRIEF-PATH-READ",
          "branch" => "orocsy/mt-review-issue-brief-path-read",
          "review" => %{
            "feedback" => [
              %{"path" => "src/lib/telemetry-logger.ts", "line" => 35}
            ]
          },
          "requirements" => %{
            "issue_brief" => %{
              "path" => ".orocsy/delivery/issue-brief.md"
            }
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-issue-brief-path-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-issue-brief-path-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''1,220p'\\'' tests/unit/telemetry-logger.test.ts\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-issue-brief-path-read",
        identifier: "MT-REVIEW-ISSUE-BRIEF-PATH-READ",
        title: "Review rework issue brief path read",
        description: "Issue brief paths should be allowed in review rework",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-ISSUE-BRIEF-PATH-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows shell-wrapped reads for existing test/source counterpart files in review rework mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-counterpart-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-COUNTERPART-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      test_file = Path.join(workspace, "tests/unit/analytics-metrics.test.ts")
      source_file = Path.join(workspace, "src/analytics/metrics.ts")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)
      File.mkdir_p!(Path.dirname(test_file))
      File.mkdir_p!(Path.dirname(source_file))
      File.write!(test_file, "test('derives MVP metrics', () => {})\n")
      File.write!(source_file, "export function deriveMvpMetrics() { return {}; }\n")

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-COUNTERPART-READ",
          "branch" => "orocsy/mt-review-counterpart-read",
          "review" => %{
            "feedback" => [
              %{
                "path" => "tests/unit/analytics-metrics.test.ts",
                "line" => 72,
                "body" => "Test the production derivation instead of the local helper."
              }
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-counterpart-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-counterpart-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''1,220p'\\'' src/analytics/metrics.ts\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-counterpart-read",
        identifier: "MT-REVIEW-COUNTERPART-READ",
        title: "Review rework counterpart read",
        description: "Existing test/source counterpart paths should be allowed in review rework",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-COUNTERPART-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server allows reads for line-ranged requirement paths in review rework mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-line-ranged-support-read-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-LINE-RANGE-READ")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-LINE-RANGE-READ",
          "branch" => "orocsy/mt-review-line-range-read",
          "review" => %{
            "feedback" => [
              %{"path" => "tests/integration/analytics-instrumentation.test.ts", "line" => 84}
            ]
          },
          "requirements" => %{
            "shared_files" => [
              "Read-only support path: `docs/TECHNICAL_DESIGN.md:898-911`"
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-line-range-read"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-line-range-read"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"/bin/zsh -lc \\"sed -n '\\''886,918p'\\'' docs/TECHNICAL_DESIGN.md\\""}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            sleep 1
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
        id: "issue-review-line-range-read",
        identifier: "MT-REVIEW-LINE-RANGE-READ",
        title: "Review rework line-ranged support read",
        description: "Line-ranged declared support paths should allow reads from the base file",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-LINE-RANGE-READ",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix review feedback", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks exec_command function calls in review rework mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-rework-function-call-command-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-FUNCTION-CALL")
      preflight_dir = Path.join(workspace, ".orocsy/delivery/state")
      preflight_file = Path.join(preflight_dir, "dispatch-preflight.json")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(preflight_dir)

      File.write!(
        preflight_file,
        Jason.encode!(%{
          "mode" => "review_rework",
          "issue" => "MT-REVIEW-FUNCTION-CALL",
          "branch" => "orocsy/mt-review-function-call",
          "review" => %{
            "feedback" => [
              %{"path" => "src/features/swipe/SwipeDeck.tsx", "line" => 81}
            ]
          }
        })
      )

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-function-call"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-function-call"}}}'
            printf '%s\\n' '{"method":"codex/event/response_item","params":{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"ls src/lib/db && sed -n 1,340p src/lib/db/guest-session-store.ts\\"}"}}}'
            ;;
          *)
            sleep 1
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
        id: "issue-review-function-call",
        identifier: "MT-REVIEW-FUNCTION-CALL",
        title: "Review rework function call",
        description: "Function-call exec commands should be blocked in review rework",
        state: "Rework",
        url: "https://example.org/issues/MT-REVIEW-FUNCTION-CALL",
        labels: []
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Fix review feedback", issue)

      assert command == "ls src/lib/db && sed -n 1,340p src/lib/db/guest-session-store.ts"
      assert pattern == "(^|\\s|[\"'])ls(\\s|$)"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server marks request-for-input events as a hard failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-input-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-input.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

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
            printf '%s\\n' '{\"method\":\"turn/input_required\",\"id\":\"resp-1\",\"params\":{\"requiresInput\":true,\"reason\":\"blocked\"}}'
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
        id: "issue-input",
        identifier: "MT-88",
        title: "Input needed",
        description: "Cannot satisfy codex input",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs input", issue)

      assert payload["method"] == "turn/input_required"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks configured forbidden non-interactive commands" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-forbidden-command-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-91")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-91"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-91"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"PORT=3101 pnpm dev --port 3101"}}}'
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_forbidden_command_patterns: ["pnpm dev"]
      )

      issue = %Issue{
        id: "issue-forbidden-command",
        identifier: "MT-91",
        title: "Forbidden command",
        description: "Ensure Symphony stops raw dev-server commands",
        state: "In Progress",
        url: "https://example.org/issues/MT-91",
        labels: ["frontend"]
      }

      assert {:error, {:forbidden_command, command, pattern}} =
               AppServer.run(workspace, "Run browser evidence", issue)

      assert command == "PORT=3101 pnpm dev --port 3101"
      assert pattern == "pnpm dev"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server stops a live turn when token budget is exceeded" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-token-budget-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-92")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-92"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-92"}}}'
            printf '%s\\n' '{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"input_tokens":900,"output_tokens":250,"total_tokens":1150}}}}'
            sleep 5
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_turn_timeout_ms: 1_000,
        codex_max_turn_total_tokens: 1_000
      )

      issue = %Issue{
        id: "issue-token-budget",
        identifier: "MT-92",
        title: "Token budget",
        description: "Ensure Symphony bounds runaway live turns",
        state: "In Progress",
        url: "https://example.org/issues/MT-92",
        labels: ["backend"]
      }

      parent = self()
      on_message = fn message -> send(parent, {:codex_message, message}) end

      assert {:error, {:turn_token_budget_exceeded, 1150, 1000}} =
               AppServer.run(workspace, "Run bounded turn", issue, on_message: on_message)

      assert_receive {:codex_message, %{event: :turn_token_budget_exceeded, total_tokens: 1150, max_tokens: 1000}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server writes redacted token telemetry spans for token updates and commands" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-token-telemetry-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-93")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(Path.join([workspace, "src", "app", "api"]))
      File.write!(Path.join([workspace, "src", "app", "api", "secret.ts"]), "export const value = 1\n")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-93"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-93"}}}'
            printf '%s\\n' '{"method":"codex/event/exec_command_begin","params":{"msg":{"command":"sed -n \\"1,40p\\" src/app/api/secret.ts --token sk_live_secret"}}}'
            printf '%s\\n' '{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"input_tokens":900,"cached_input_tokens":700,"output_tokens":250,"total_tokens":1150}}}}'
            printf '%s\\n' '{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"input_tokens":950,"cached_input_tokens":725,"output_tokens":275,"total_tokens":1225}}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_max_turn_total_tokens: 0
      )

      issue = %Issue{
        id: "issue-token-telemetry",
        identifier: "MT-93",
        title: "Token telemetry",
        description: "Ensure token usage is persisted without raw command arguments",
        state: "In Progress",
        url: "https://example.org/issues/MT-93",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Record token telemetry", issue)

      spans_path = Path.join(workspace, ".orocsy/delivery/token-telemetry/spans.jsonl")

      spans =
        spans_path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert Enum.any?(spans, &(&1["kind"] == "worker_start"))

      command_span = Enum.find(spans, &(&1["kind"] == "command"))
      assert command_span["phase"] == "code_read"
      assert command_span["command_fingerprint"] == "sed-read-src-app-api-secret.ts"
      assert command_span["files"] == ["src/app/api/secret.ts"]
      refute inspect(command_span) =~ "sk_live_secret"

      token_spans = Enum.filter(spans, &(&1["kind"] == "token_update"))
      assert Enum.map(token_spans, & &1["total_tokens_delta"]) == [1150, 75]
      assert Enum.map(token_spans, & &1["cached_input_tokens_delta"]) == [700, 25]
      assert Enum.map(token_spans, & &1["counted_guard_tokens_delta"]) == [200, 25]
      assert Enum.all?(token_spans, &(&1["command_fingerprint"] == "sed-read-src-app-api-secret.ts"))
      refute File.read!(spans_path) =~ "sk_live_secret"

      workers_path = Path.join(workspace, ".orocsy/delivery/token-telemetry/workers.jsonl")
      worker_summary = workers_path |> File.read!() |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

      assert worker_summary["status"] == "blocked_no_durable_progress"
      assert worker_summary["total_tokens"] == 1225
      assert [%{"phase" => "code_read", "total_tokens" => 1225}] = worker_summary["top_phases"]
      assert File.regular?(Path.join(workspace, ".orocsy/delivery/token-telemetry/summaries/MT-93-thread-93-turn-93-turn-1.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails when command execution approval is required under safer defaults" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-approval-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-89"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-89"}}}'
            printf '%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"gh pr view","cwd":"/tmp","reason":"need approval"}}'
            ;;
          *)
            sleep 1
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
        id: "issue-approval-required",
        identifier: "MT-89",
        title: "Approval required",
        description: "Ensure safer defaults do not auto approve requests",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, payload}} =
               AppServer.run(workspace, "Handle approval request", issue)

      assert payload["method"] == "item/commandExecution/requestApproval"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves file change approval requests when granular rules are disabled" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-file-change-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-file-change-auto-approve.trace")
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
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-file-change-auto-approve.trace}"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-90"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-90"}}}'
            printf '%s\\n' '{"id":99,"method":"item/fileChange/requestApproval","params":{"itemId":"file-change-1","threadId":"thread-90","turnId":"turn-90","grantRoot":null,"reason":null}}'
            ;;
          5)
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

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: %{granular: %{sandbox_approval: true, rules: false, mcp_elicitations: true}}
      )

      issue = %Issue{
        id: "issue-file-change-auto-approve",
        identifier: "MT-90",
        title: "Auto approve file changes",
        description: "Ensure file change approval requests do not block worker edits",
        state: "In Progress",
        url: "https://example.org/issues/MT-90",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle file change request", issue)

      trace = File.read!(trace_file)

      assert trace =~ ~s("id":99)
      assert trace =~ ~s("decision":"acceptForSession")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves only configured safe command approval requests" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-safe-command-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-94")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-safe-command-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEX_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEX_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEX_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex-safe-command-auto-approve.trace}"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-94"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-94"}}}'
            printf '%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"ps -axo pid,ppid,stat,command","cwd":"/tmp","reason":"inspect stuck process"}}'
            ;;
          5)
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

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: %{granular: %{sandbox_approval: true, rules: false, mcp_elicitations: true}},
        codex_safe_command_approval_patterns: [
          ~s(^ps -axo pid,ppid,stat,command$)
        ]
      )

      issue = %Issue{
        id: "issue-safe-command-auto-approve",
        identifier: "MT-94",
        title: "Auto approve safe command",
        description: "Ensure narrow read-only diagnostics can continue without approving broad commands",
        state: "In Progress",
        url: "https://example.org/issues/MT-94",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle safe command approval request", issue)

      trace = File.read!(trace_file)

      assert trace =~ ~s("id":99)
      assert trace =~ ~s("decision":"acceptForSession")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server stops on MCP tool approval prompts under granular defaults" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-granular-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-91")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-granular.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEX_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEX_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEX_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex-tool-user-input-granular.trace}"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-91"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-91"}}}'
            printf '%s\\n' '{"id":110,"method":"item/tool/requestUserInput","params":{"itemId":"call-91","questions":[{"header":"Approve app tool call?","id":"mcp_tool_call_approval_call-91","isOther":false,"isSecret":false,"options":[{"description":"Run the tool and continue.","label":"Approve Once"},{"description":"Run the tool and remember this choice for this session.","label":"Approve this Session"},{"description":"Decline this tool call and continue.","label":"Deny"},{"description":"Cancel this tool call","label":"Cancel"}],"question":"The linear MCP server wants to run the tool \\"Save issue\\", which may modify or delete data. Allow this action?"}],"threadId":"thread-91","turnId":"turn-91"}}'
            ;;
          5)
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

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: %{granular: %{sandbox_approval: true, rules: false, mcp_elicitations: true}}
      )

      issue = %Issue{
        id: "issue-tool-user-input-granular",
        identifier: "MT-91",
        title: "Do not auto approve MCP tool approval prompt",
        description: "Ensure granular mode does not approve external tool mutation prompts",
        state: "In Progress",
        url: "https://example.org/issues/MT-91",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, payload}} =
               AppServer.run(workspace, "Handle MCP tool approval prompt", issue)

      assert payload["method"] == "item/tool/requestUserInput"

      trace = File.read!(trace_file)
      refute trace =~ "Approve this Session"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves command execution approval requests when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-auto-approve.trace")
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
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-89\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-89\"}}}'
            printf '%s\\n' '{\"id\":99,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"command\":\"gh pr view\",\"cwd\":\"/tmp\",\"reason\":\"need approval\"}}'
            ;;
          5)
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
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-auto-approve",
        identifier: "MT-89",
        title: "Auto approve request",
        description: "Ensure app-server approval requests are handled automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle approval request", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 1 and
                   get_in(payload, ["params", "capabilities", "experimentalApi"]) == true
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 2 and
                   case get_in(payload, ["params", "dynamicTools"]) do
                     [
                       %{
                         "description" => description,
                         "inputSchema" => %{"required" => ["query"]},
                         "name" => "linear_graphql"
                       }
                     ] ->
                       description =~ "Linear"

                     _ ->
                       false
                   end
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 99 and get_in(payload, ["result", "decision"]) == "acceptForSession"
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves MCP tool approval prompts when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-717")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-717\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-717\"}}}'
            printf '%s\\n' '{\"id\":110,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-717\",\"questions\":[{\"header\":\"Approve app tool call?\",\"id\":\"mcp_tool_call_approval_call-717\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Run the tool and continue.\",\"label\":\"Approve Once\"},{\"description\":\"Run the tool and remember this choice for this session.\",\"label\":\"Approve this Session\"},{\"description\":\"Decline this tool call and continue.\",\"label\":\"Deny\"},{\"description\":\"Cancel this tool call\",\"label\":\"Cancel\"}],\"question\":\"The linear MCP server wants to run the tool \\\"Save issue\\\", which may modify or delete data. Allow this action?\"}],\"threadId\":\"thread-717\",\"turnId\":\"turn-717\"}}'
            ;;
          5)
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
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-auto-approve",
        identifier: "MT-717",
        title: "Auto approve MCP tool request user input",
        description: "Ensure app tool approval prompts continue automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-717",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle tool approval prompt", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 110 and
                   get_in(payload, ["result", "answers", "mcp_tool_call_approval_call-717", "answers"]) ==
                     ["Approve this Session"]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server sends a generic non-interactive answer for freeform tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-718")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-718"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-718"}}}'
            printf '%s\\n' '{"id":111,"method":"item/tool/requestUserInput","params":{"itemId":"call-718","questions":[{"header":"Provide context","id":"freeform-718","isOther":false,"isSecret":false,"options":null,"question":"What comment should I post back to the issue?"}],"threadId":"thread-718","turnId":"turn-718"}}'
            ;;
          5)
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

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-required",
        identifier: "MT-718",
        title: "Non interactive tool input answer",
        description: "Ensure arbitrary tool prompts receive a generic answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-718",
        labels: ["backend"]
      }

      on_message = fn message -> send(self(), {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle generic tool input", issue, on_message: on_message)

      assert_received {:app_server_message,
                       %{
                         event: :tool_input_auto_answered,
                         answer: "This is a non-interactive session. Operator input is unavailable."
                       }}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server stops on option-based tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-options-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-719")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-options.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-options.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-719\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-719\"}}}'
            printf '%s\\n' '{\"id\":112,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-719\",\"questions\":[{\"header\":\"Choose an action\",\"id\":\"options-719\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Use the default behavior.\",\"label\":\"Use default\"},{\"description\":\"Skip this step.\",\"label\":\"Skip\"}],\"question\":\"How should I proceed?\"}],\"threadId\":\"thread-719\",\"turnId\":\"turn-719\"}}'
            ;;
          5)
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
        id: "issue-tool-user-input-options",
        identifier: "MT-719",
        title: "Option based tool input answer",
        description: "Ensure option prompts receive a generic non-interactive answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-719",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Handle option based tool input", issue)

      assert payload["method"] == "item/tool/requestUserInput"

      trace = File.read!(trace_file)
      refute trace =~ "options-719"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects unsupported dynamic tool calls without stalling" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90\"}}}'
            printf '%s\\n' '{\"id\":101,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"some_tool\",\"callId\":\"call-90\",\"threadId\":\"thread-90\",\"turnId\":\"turn-90\",\"arguments\":{}}}'
            ;;
          5)
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
        id: "issue-tool-call",
        identifier: "MT-90",
        title: "Unsupported tool call",
        description: "Ensure unsupported tool calls do not stall a turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-90",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Reject unsupported tool calls", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 101 and
                   get_in(payload, ["result", "success"]) == false and
                   String.contains?(
                     get_in(payload, ["result", "output"]),
                     "Unsupported dynamic tool"
                   )
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server executes supported dynamic tool calls and returns the tool result" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90A")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90a\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90a\"}}}'
            printf '%s\\n' '{\"id\":102,\"method\":\"item/tool/call\",\"params\":{\"name\":\"linear_graphql\",\"callId\":\"call-90a\",\"threadId\":\"thread-90a\",\"turnId\":\"turn-90a\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\",\"variables\":{\"includeTeams\":false}}}}'
            ;;
          5)
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
        id: "issue-supported-tool-call",
        identifier: "MT-90A",
        title: "Supported tool call",
        description: "Ensure supported tool calls return tool output",
        state: "In Progress",
        url: "https://example.org/issues/MT-90A",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => true,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"data":{"viewer":{"id":"usr_123"}}})
            }
          ]
        }
      end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle supported tool calls", issue, tool_executor: tool_executor)

      assert_received {:tool_called, "linear_graphql",
                       %{
                         "query" => "query Viewer { viewer { id } }",
                         "variables" => %{"includeTeams" => false}
                       }}

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 102 and
                   get_in(payload, ["result", "success"]) == true and
                   get_in(payload, ["result", "output"]) ==
                     ~s({"data":{"viewer":{"id":"usr_123"}}})
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits tool_call_failed for supported tool failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-failed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90B")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call-failed.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call-failed.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90b\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90b\"}}}'
            printf '%s\\n' '{\"id\":103,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"linear_graphql\",\"callId\":\"call-90b\",\"threadId\":\"thread-90b\",\"turnId\":\"turn-90b\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\"}}}'
            ;;
          5)
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
        id: "issue-tool-call-failed",
        identifier: "MT-90B",
        title: "Tool call failed",
        description: "Ensure supported tool failures emit a distinct event",
        state: "In Progress",
        url: "https://example.org/issues/MT-90B",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => false,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"error":{"message":"boom"}})
            }
          ]
        }
      end

      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle failed tool calls", issue,
                 on_message: on_message,
                 tool_executor: tool_executor
               )

      assert_received {:tool_called, "linear_graphql", %{"query" => "query Viewer { viewer { id } }"}}

      assert_received {:app_server_message, %{event: :tool_call_failed, payload: %{"params" => %{"tool" => "linear_graphql"}}}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server buffers partial JSON lines until newline terminator" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-partial-line-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-91")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            padding=$(printf '%*s' 1100000 '' | tr ' ' a)
            printf '{"id":1,"result":{},"padding":"%s"}\\n' "$padding"
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-91"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-91"}}}'
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

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-partial-line",
        identifier: "MT-91",
        title: "Partial line decode",
        description: "Ensure JSON parsing waits for newline-delimited messages",
        state: "In Progress",
        url: "https://example.org/issues/MT-91",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate newline-delimited buffering", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server captures codex side output and logs it through Logger" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-92")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-92"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-92"}}}'
            ;;
          4)
            printf '%s\\n' 'warning: this is stderr noise' >&2
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

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-stderr",
        identifier: "MT-92",
        title: "Capture stderr",
        description: "Ensure codex stderr is captured and logged",
        state: "In Progress",
        url: "https://example.org/issues/MT-92",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   AppServer.run(workspace, "Capture stderr log", issue, on_message: on_message)
        end)

      assert_received {:app_server_message, %{event: :turn_completed}}
      refute_received {:app_server_message, %{event: :malformed}}
      assert log =~ "Codex turn stream output: warning: this is stderr noise"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits malformed events for JSON-like protocol lines that fail to decode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-malformed-protocol-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-93")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-93"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-93"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"'
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

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-malformed-protocol",
        identifier: "MT-93",
        title: "Malformed protocol frame",
        description: "Ensure malformed JSON-like frames are surfaced to the orchestrator",
        state: "In Progress",
        url: "https://example.org/issues/MT-93",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Capture malformed protocol line", issue, on_message: on_message)

      assert_received {:app_server_message, %{event: :malformed, payload: "{\"method\":\"turn/completed\""}}
      assert_received {:app_server_message, %{event: :turn_completed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server launches over ssh for remote workers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-remote-ssh-#{System.unique_integer([:positive])}"
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
      remote_workspace = "/remote/workspaces/MT-REMOTE"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      count=0
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-remote"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-remote"}}}'
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

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        codex_command: "fake-remote-codex app-server"
      )

      issue = %Issue{
        id: "issue-remote",
        identifier: "MT-REMOTE",
        title: "Run remote app server",
        description: "Validate ssh-backed codex startup",
        state: "In Progress",
        url: "https://example.org/issues/MT-REMOTE",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(
                 remote_workspace,
                 "Run remote worker",
                 issue,
                 worker_host: "worker-01:2200"
               )

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, &String.starts_with?(&1, "ARGV:"))
      assert argv_line =~ "-T -p 2200 worker-01 bash -lc"
      assert argv_line =~ "cd "
      assert argv_line =~ remote_workspace
      assert argv_line =~ "exec "
      assert argv_line =~ "fake-remote-codex app-server"

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [remote_workspace],
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
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace
                 end)
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)

      refute File.exists?(Path.join(remote_workspace, ".orocsy/delivery/token-telemetry/spans.jsonl"))
      refute File.exists?(Path.join(remote_workspace, ".orocsy/delivery/token-telemetry/workers.jsonl"))
    after
      File.rm_rf(test_root)
    end
  end

  defp write_fresh_checkpoint_git_progress!(workspace, relative_path) do
    full_path = Path.join(workspace, relative_path)
    File.mkdir_p!(Path.dirname(full_path))

    assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace, stderr_to_stdout: true)
    assert {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)

    File.write!(full_path, "baseline\n")
    assert {_output, 0} = System.cmd("git", ["add", relative_path], cd: workspace, stderr_to_stdout: true)
    assert {_output, 0} = System.cmd("git", ["commit", "-m", "Baseline"], cd: workspace, stderr_to_stdout: true)
    assert {_output, 0} = System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: workspace, stderr_to_stdout: true)

    File.write!(full_path, "checkpoint\n")
  end
end
