defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger

  alias SymphonyElixir.{
    Codex.DynamicTool,
    CommandIntent,
    Config,
    DispatchPreflight,
    PathSafety,
    ScopeAccess,
    SSH,
    TokenTelemetry,
    Workspace
  }

  alias SymphonyElixir.ScopeAccess.Controller, as: ScopeAccessController

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @delivery_event_path ".orocsy/delivery/events/events.jsonl"
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."
  @review_rework_disabled_skill_names [
    "agentic-delivery-loop",
    "build-web-apps:frontend-app-builder",
    "build-web-apps:frontend-testing-debugging",
    "build-web-apps:react-best-practices",
    "github:gh-address-comments",
    "github:gh-fix-ci",
    "github:github",
    "linear:linear",
    "playwright",
    "playwright-interactive",
    "requesting-code-review",
    "typescript-best-practices",
    "vercel:react-best-practices"
  ]
  @fresh_implementation_disabled_skill_names @review_rework_disabled_skill_names
  @integration_check_disabled_skill_names @review_rework_disabled_skill_names
  @review_rework_disabled_plugins [
    "browser@openai-bundled",
    "build-web-apps@openai-curated",
    "chrome@openai-bundled",
    "cloudflare@openai-curated",
    "computer-use@openai-bundled",
    "documents@openai-primary-runtime",
    "figma@openai-curated",
    "github@openai-curated",
    "google-drive@openai-curated",
    "linear@openai-curated",
    "notion@openai-curated",
    "presentations@openai-primary-runtime",
    "spreadsheets@openai-primary-runtime",
    "stripe@openai-curated",
    "supabase@openai-curated",
    "vercel@openai-curated"
  ]
  @worker_disabled_mcp_servers []
  @review_rework_command_chain_pattern "command_chain_operator_outside_quotes"
  @review_rework_git_diff_base_pattern "git_diff_base_branch_without_path_scope"
  @review_rework_dirty_validated_handoff_recheck_pattern "dirty_validated_handoff_recheck_before_commit"
  @review_rework_git_log_pattern "(^|\\s|[\"'])git\\s+log(\\s|$)"
  @review_rework_forbidden_command_patterns [
    @review_rework_command_chain_pattern,
    @review_rework_dirty_validated_handoff_recheck_pattern,
    "(^|\\s|[\"'])rg(\\s|$)",
    "(^|\\s|[\"'])grep(\\s|$)",
    "(^|\\s|[\"'])gh\\s+api(\\s|$)",
    "(^|\\s|[\"'])find(\\s|$)",
    @review_rework_git_log_pattern,
    "(^|\\s|[\"'])git\\s+diff\\s+--stat(\\s|$)",
    @review_rework_git_diff_base_pattern,
    "(^|\\s|[\"'])git\\s+ls-files(\\s|$)",
    "(^|\\s|[\"'])ls(\\s|$)"
  ]
  @fresh_implementation_forbidden_command_patterns [
    "(^|\\s|[\"'])rg(\\s|$)",
    "(^|\\s|[\"'])grep(\\s|$)",
    "(^|\\s|[\"'])gh\\s+api(\\s|$)",
    "(^|\\s|[\"'])find(\\s|$)",
    "(^|\\s|[\"'])git\\s+ls-files(\\s|$)"
  ]
  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approvals: map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          forbidden_command_patterns: [String.t()],
          safe_command_approval_patterns: [String.t()],
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host) do
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, thread_id} <- do_start_session(port, expanded_workspace, session_policies) do
        session_policies = with_symlinked_vitest_writable_roots(session_policies, expanded_workspace)

        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approvals: auto_approvals(session_policies.approval_policy, session_policies.safe_command_approval_patterns),
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           forbidden_command_patterns: session_policies.forbidden_command_patterns,
           safe_command_approval_patterns: session_policies.safe_command_approval_patterns,
           thread_id: thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approvals: auto_approvals,
          forbidden_command_patterns: forbidden_command_patterns,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace,
          worker_host: worker_host
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    configured_forbidden_command_patterns = forbidden_command_patterns
    forbidden_command_patterns = effective_forbidden_command_patterns(workspace, configured_forbidden_command_patterns)

    command_guard = %{
      patterns: forbidden_command_patterns,
      configured_patterns: configured_forbidden_command_patterns,
      workspace: workspace,
      worker_host: worker_host,
      fresh_checkpoint_stop_enabled: dispatch_preflight_mode(workspace) == "fresh_implementation",
      fresh_checkpoint_present_at_turn_start: fresh_implementation_checkpoint_ready?(workspace)
    }

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments, workspace: workspace)
      end)

    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        telemetry = start_token_telemetry(workspace, issue, thread_id, turn_id, opts, worker_host)
        command_guard = Map.put(command_guard, :token_telemetry, telemetry)
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        try do
          case await_turn_completion(port, on_message, tool_executor, auto_approvals, command_guard) do
            {:ok, result} ->
              Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

              {:ok,
               %{
                 result: result,
                 session_id: session_id,
                 thread_id: thread_id,
                 turn_id: turn_id
               }}

            {:error, reason} ->
              Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

              emit_message(
                on_message,
                :turn_ended_with_error,
                %{
                  session_id: session_id,
                  reason: reason
                },
                metadata
              )

              {:error, reason}
          end
        after
          TokenTelemetry.stop(telemetry)
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(codex_launch_command())],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp remote_launch_command(workspace) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      "exec #{codex_launch_command()}"
    ]
    |> Enum.join(" && ")
  end

  defp codex_launch_command do
    Config.settings!().codex.command <> worker_disabled_mcp_server_flags()
  end

  defp worker_disabled_mcp_server_flags do
    @worker_disabled_mcp_servers
    |> Enum.map_join("", &" --config mcp_servers.#{&1}.enabled=false")
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp with_symlinked_vitest_writable_roots(%{turn_sandbox_policy: policy} = session_policies, workspace)
       when is_binary(workspace) do
    %{session_policies | turn_sandbox_policy: maybe_allow_symlinked_vite_temp(policy, workspace)}
  end

  defp with_symlinked_vitest_writable_roots(session_policies, _workspace), do: session_policies

  defp maybe_allow_symlinked_vite_temp(%{"type" => "workspaceWrite", "writableRoots" => roots} = policy, workspace)
       when is_list(roots) and is_binary(workspace) do
    with true <- symlinked_node_modules?(workspace),
         true <- package_test_script_vitest?(workspace),
         {:ok, vite_temp_root} <- ensure_symlinked_vite_temp_root(workspace) do
      Map.put(policy, "writableRoots", Enum.uniq(roots ++ [vite_temp_root]))
    else
      _ -> policy
    end
  end

  defp maybe_allow_symlinked_vite_temp(policy, _workspace), do: policy

  defp ensure_symlinked_vite_temp_root(workspace) when is_binary(workspace) do
    vite_temp = Path.join([workspace, "node_modules", ".vite-temp"])

    with :ok <- File.mkdir_p(vite_temp),
         {:ok, canonical_vite_temp} <- PathSafety.canonicalize(vite_temp) do
      {:ok, canonical_vite_temp}
    end
  rescue
    _error -> :error
  end

  defp do_start_session(port, workspace, session_policies) do
    case send_initialize(port) do
      :ok -> start_thread(port, workspace, session_policies)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(port, workspace, %{approval_policy: approval_policy, thread_sandbox: thread_sandbox}) do
    params =
      %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => DynamicTool.tool_specs()
      }
      |> maybe_put_worker_thread_overrides(workspace)

    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => params
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp maybe_put_worker_thread_overrides(params, workspace) when is_binary(workspace) do
    case DispatchPreflight.read_for_prompt(workspace) do
      {:ok, %{"mode" => "review_rework"}} ->
        params
        |> Map.put("baseInstructions", review_rework_base_instructions())
        |> Map.put("developerInstructions", review_rework_developer_instructions())
        |> Map.put("config", review_rework_thread_config())

      {:ok, %{"mode" => "fresh_implementation"}} ->
        params
        |> Map.put("baseInstructions", fresh_implementation_base_instructions())
        |> Map.put("developerInstructions", fresh_implementation_developer_instructions())
        |> Map.put("config", fresh_implementation_thread_config())

      {:ok,
       %{
         "mode" => "handoff_recovery",
         "requirements" => %{"runtime_contract_status" => "structured"}
       }} ->
        params
        |> Map.put("baseInstructions", fresh_implementation_base_instructions())
        |> Map.put("developerInstructions", structured_handoff_recovery_developer_instructions())
        |> Map.put("config", fresh_implementation_thread_config())

      {:ok, %{"mode" => "integration_check"}} ->
        params
        |> Map.put("baseInstructions", integration_check_base_instructions())
        |> Map.put("developerInstructions", integration_check_developer_instructions())
        |> Map.put("config", integration_check_thread_config())

      _ ->
        params
    end
  end

  defp maybe_put_worker_thread_overrides(params, _workspace), do: params

  defp fresh_implementation_thread_config do
    %{
      "skills" => %{
        "disabled_skill_names" => @fresh_implementation_disabled_skill_names
      },
      "features" => %{
        "apps" => false,
        "plugins" => false,
        "tool_search" => false
      },
      "apps" => %{
        "_default" => %{
          "enabled" => false,
          "open_world_enabled" => false,
          "destructive_enabled" => false
        }
      },
      "plugins" => disabled_named_config(@review_rework_disabled_plugins)
    }
  end

  defp integration_check_thread_config do
    %{
      "skills" => %{
        "disabled_skill_names" => @integration_check_disabled_skill_names
      },
      "features" => %{
        "apps" => false,
        "plugins" => false,
        "tool_search" => false
      },
      "apps" => %{
        "_default" => %{
          "enabled" => false,
          "open_world_enabled" => false,
          "destructive_enabled" => false
        }
      },
      "plugins" => disabled_named_config(@review_rework_disabled_plugins)
    }
  end

  defp review_rework_thread_config do
    %{
      "skills" => %{
        "disabled_skill_names" => @review_rework_disabled_skill_names
      },
      "features" => %{
        "apps" => false,
        "plugins" => false,
        "tool_search" => false
      },
      "apps" => %{
        "_default" => %{
          "enabled" => false,
          "open_world_enabled" => false,
          "destructive_enabled" => false
        }
      },
      "plugins" => disabled_named_config(@review_rework_disabled_plugins)
    }
  end

  defp disabled_named_config(names) do
    Map.new(names, fn name -> {name, %{"enabled" => false}} end)
  end

  defp review_rework_base_instructions do
    """
    You are a Symphony review-rework worker for one existing pull request.
    Use only the current prompt, current branch, referenced review feedback, and local files needed for the fix.
    Make a scoped code/test edit or record an explicit Orocsy blocker. Do not perform broad project discovery.
    """
    |> String.trim()
  end

  defp fresh_implementation_base_instructions do
    """
    You are a Symphony fresh-MIU worker for one Linear issue and one declared write scope.
    Use the current prompt, the focused issue brief, and the named files only.
    Make a scoped code/test/doc edit or record an explicit Orocsy blocker. Do not perform broad project discovery.
    """
    |> String.trim()
  end

  defp integration_check_base_instructions do
    """
    You are a Symphony integration-check worker for one integration branch and final PR handoff.
    Use the current prompt, focused issue brief, configured integration branch or PR branch, and named conflict paths only.
    Resolve PR mergeability blockers or validate the handoff, push the same branch, and record a blocker if any external step fails.
    """
    |> String.trim()
  end

  defp review_rework_developer_instructions do
    """
    Symphony review-rework micro-worker.

    This thread exists only to resolve current-head PR review feedback already named in the user prompt.
    If the prompt includes a `Runtime Contract final handoff gate`, that gate is authoritative: after the scoped review edit, commit and push without running contract-declared validation inside the Codex worker sandbox, append the exact `handoff.requested` event, and stop. Symphony's validation controller runs the review-delta validation outside the worker sandbox.
    Do not load Codex skills, plugins, apps, MCP tools, broad project docs, prior session JSONL, or unrelated issue history.
    Do not refetch GitHub or Linear review text when the prompt already includes the current-head feedback body.
    Before a dirty/local handoff shortcut, run `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py symphony guidance --workspace . --json`. If guidance or the dispatch preflight reports any open Orocsy correction, that correction defines the first scoped fix. Under a Runtime Contract final handoff, explicitly resolve a worker/guidance correction after the scoped fix, then commit and push without worker-side validation and append `handoff.requested`; only a controller-owned review validation correction remains open for controller reconciliation. For a legacy issue, run focused validation and resolve the correction only after evidence is recorded. Do not append `review-feedback-classified` or run validation-only browser retries.
    Exception: when the open correction source is `symphony.runtime.validation-controller` and its guard MIU is `__review_rework__`, do not rerun validation or resolve the correction manually. Use the supplied output to make the smallest scoped fix, commit and push it, append the Runtime Contract `handoff.requested` event, and stop so the controller can validate and resolve it.
    When guidance reports no open corrections and there is no dirty/local handoff checkpoint, do not append `review-feedback-classified` as a standalone first action. The supplied current-head feedback is already classified enough to begin; read only the referenced in-scope file range, then make the scoped fix or record an explicit blocker.
    Do not run broad rg, grep, find, ls, git ls-files, mutating gh api, shell pipelines, or chained shell commands in review-rework mode; use the supplied feedback body, dirty diff, and short sed ranges.
    If current-head feedback or an Orocsy correction names exact files and a symbol lookup is truly needed after the active checkpoint, use only bounded `rg -n "literal" <exact named file...>` over those named files. Never use grep, recursive flags, or bare directories such as `src`, `app`, `lib`, or `tests`.
    For implementation-child review rework, shared-file or owned-by-other notes are not automatically readable. Read only write-scope files plus shared files explicitly labeled read-only/context/support; never read files listed as out of scope or owned by another ticket.
    After durable local handoff progress, read-only GitHub PR/review inspection via `gh api --method GET` or read-only PR GraphQL is allowed only to confirm current PR review state.
    If the prompt includes a `Runtime Contract final handoff gate`, do not post `@codex review` yourself. After the scoped commit is pushed, request final runtime certification with the exact `handoff.requested` command supplied by that contract; Symphony issues `handoff.ready` and posts the fresh review request. For a legacy issue with no Runtime Contract gate, request review directly with `gh pr comment <pr-number> --body '@codex review'` after focused validation and push.
    If the prompt starts with a dirty/local handoff checkpoint, follow that checkpoint first. For a structured Runtime Contract final handoff, inspect only the focused local diff, commit and push it without worker-side validation, then append `handoff.requested`. For a legacy issue, run its contract-declared focused validation before committing; then follow the same structured-versus-legacy handoff rule above. Leave Linear state transitions to Symphony's review monitor.
    Run only validation commands declared by the active issue/runtime contract; do not add a full suite as an extra review-rework gate. For declared Vitest validation, use `--configLoader runner` to avoid Vite writing startup temp files into symlinked `node_modules/.vite-temp`. If the issue brief names a focused test, run the exact `pnpm exec vitest run --configLoader runner <test-file>` command. If the declared full-suite command is `pnpm test` and `package.json` has `"test": "vitest run"`, run `pnpm test -- --configLoader runner` instead and record it as satisfying `pnpm test`. Do not run `pnpm test <test-file>` and do not probe or request approval for `node_modules/.vite-temp`.
    Start from the feedback file listed in the prompt. Read a short range around that target file only, then edit only directly related code/tests or record a blocker.
    If the issue brief names an exact write-scope file that does not exist yet, create that exact file; do not try alternate app roots such as `app/`, `apps/web/`, or `packages/web/`.
    If the issue brief names an exact test file, use that path; do not invent colocated sibling tests such as `src/.../*.test.ts`.
    Treat `.orocsy/delivery/state/dispatch-preflight.json` as read-only runtime context; never patch it to record validation evidence.
    Before spending broad analysis tokens, either edit a scoped code/test file or write an explicit Orocsy blocker/correction.
    If validation, git push, GitHub, Linear, PATH, auth, network/provider access, or approval/input fails, record the exact command, stderr/output, failure kind, and next action in an Orocsy blocker/correction before stopping.
    Do not use a plain `event append --type validation.blocker` as the only blocker record; create an Orocsy inbox correction when stopping for a blocker.
    In the first turn, complete the scoped fix and either the controller-owned structured runtime handoff or the legacy direct review request with worker validation described above, or stop with a concrete blocker.
    Never move a review-rework issue to `Done`, `Closed`, or another terminal Linear state. A fresh review request is not proof of a clean review.
    Never merge automatically.
    """
    |> String.trim()
  end

  defp fresh_implementation_developer_instructions do
    """
    Symphony fresh-MIU micro-worker.

    This thread exists only to complete the current Linear issue's first declared MIU.
    Do not load Codex skills, plugins, apps, MCP tools, prior session JSONL, broad project docs, historical tickets, or unrelated issue history.
    Treat `.orocsy/delivery/state/dispatch-preflight.json` as read-only runtime context; never patch it to record validation evidence.
    Start from `git status --short --branch`, then read `.orocsy/delivery/issue-brief.md` if present.
    Use exact files, line ranges, data shapes, tests, and validation commands from the issue brief. Do not run `rg`, `grep`, `find`, `git ls-files`, GitHub, or Linear discovery before the first scoped edit unless the issue brief is missing required code-level scope.
    Shared-file or owned-by-other notes are not automatically readable. Read only write-scope files plus shared files explicitly labeled read-only/context/support; never read files listed as out of scope or owned by another ticket.
    After durable local handoff progress, read-only GitHub PR/review inspection via `gh api --method GET` or read-only PR GraphQL is allowed only to confirm current PR review state; use `gh pr create` or `gh pr comment` for PR creation and Codex review requests.
    For Vitest validation, use `--configLoader runner` to avoid Vite writing startup temp files into symlinked `node_modules/.vite-temp`. If the issue brief names a focused test, run the exact `pnpm exec vitest run --configLoader runner <test-file>` command. If the declared full-suite command is `pnpm test` and `package.json` has `"test": "vitest run"`, run `pnpm test -- --configLoader runner` instead and record it as satisfying `pnpm test`. Do not run `pnpm test <test-file>` and do not probe or request approval for `node_modules/.vite-temp`.
    If the brief is missing exact write scope, dependencies, target files, target tests, or acceptance criteria, write an Orocsy blocker/correction and stop instead of searching broadly.
    If an exact write-scope file from the brief is missing, create that exact path; do not try alternate app roots such as `app/`, `apps/web/`, or `packages/web/`.
    If the brief names an exact test file, use that path; do not invent colocated sibling tests such as `src/.../*.test.ts`.
    Before any wider context read, either make the first scoped code/test/doc edit and append `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . event append --type tool.finished --status passed --tool "technical-miu-trace"`, or record a blocker/correction. Trace-only/read-only MIU notes are not durable progress.
    For docs-only or contract tickets, edit the declared contract section first; do not search the whole document to rediscover the section if the issue brief names the target section.
    If the user prompt begins with a `Runtime Contract execution gate`, that gate replaces all legacy validation and handoff instructions: implement the named MIU, do not run contract-declared validation inside the Codex worker sandbox, create its clean local micro commit, append `miu.completion_requested` exactly as instructed, and stop without pushing or requesting review. Symphony's validation controller runs authoritative validation after the request. Otherwise, in the first fresh implementation turn stop after the scoped edit and `technical-miu-trace`; do not validate, commit, push, create/update a PR, request Codex review, or update Linear in that same first turn. A later dirty handoff-recovery turn owns focused validation, evidence, commit, push, PR review request, and Linear handoff.
    If validation, git push, GitHub, Linear, PATH, auth, network/provider access, or approval/input fails, record the exact command, stderr/output, failure kind, and next action in an Orocsy blocker/correction before stopping.
    Do not use a plain `event append --type validation.blocker` as the only blocker record; create an Orocsy inbox correction when stopping for a blocker.
    In the first turn, complete the active structured-contract gate or the legacy scoped implementation checkpoint, or stop with a concrete blocker.
    Never merge automatically.
    """
    |> String.trim()
  end

  defp structured_handoff_recovery_developer_instructions do
    """
    Symphony structured handoff-recovery micro-worker.

    The user prompt's active `Runtime Contract execution gate` or `Runtime Contract final handoff gate` is authoritative and replaces legacy worker-side validation and handoff instructions.
    If the prompt reports an open Orocsy correction, that correction is the first task even when the persisted preflight previously named a Runtime Contract gate. Make only the correction's scoped fix. Resolve a worker/guidance correction with scoped-fix evidence before handoff; leave a controller-owned validation correction open for controller reconciliation.
    Inspect only `git status --short --branch`, the focused dirty diff, the active issue brief, and files named by the active gate.
    For an execution gate, finish only the named MIU inside its declared write scope, create one clean local micro commit, append the exact `miu.completion_requested` event supplied by the gate, and stop without pushing.
    For a final handoff gate, do not create another MIU commit: push the canonical branch, verify upstream equality, ensure its PR exists, append the exact `handoff.requested` event supplied by the gate, and stop.
    Do not run contract-declared validation inside the Codex worker sandbox and do not recreate a browser or environment correction solely because worker-side validation is unavailable.
    Symphony's validation controller runs authoritative validation after an MIU request, writes exact failure evidence into an Orocsy correction, and resolves matching MIU validation corrections after successful certification.
    Do not load skills, plugins, apps, MCP tools, prior session logs, historical tickets, or broad project context. Do not broaden read or write scope.
    Do not request GitHub review or change Linear state yourself.
    Never merge automatically.
    """
    |> String.trim()
  end

  defp integration_check_developer_instructions do
    """
    Symphony integration-check micro-worker.

    This thread exists only to make the configured integration branch or existing PR branch mergeable and ready for final PR handoff.
    Do not load Codex skills, plugins, apps, MCP tools, prior session JSONL, broad project docs, historical tickets, or unrelated issue history.
    Treat `.orocsy/delivery/state/dispatch-preflight.json` as read-only runtime context; never patch it to record validation evidence.
    Start from `git status --short --branch`, then use the issue brief/preflight paths and bounded git conflict commands to expose current merge conflicts.
    Immediately after confirming the current branch/status, and before any `gh pr`, `gh api`, conflict scan, diff, or file read, append `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . event append --type handoff.integration-check-started --status passed --phase handoff --step "integration branch/status confirmed" --tool "integration-handoff-preflight"`.
    If the preflight PR is unknown, use bounded read-only `gh pr view`/`gh pr list` for the configured integration branch before deciding whether a same-branch PR handoff is missing. If you use `gh api` for PR lookup, it must include `--method GET`; never pass `-f`, `-F`, `--field`, or `--raw-field` without `--method GET`.
    If no PR exists for the configured integration branch after bounded lookup, create exactly one PR for that branch only when the branch contains the intended handoff commits; do not create a new branch.
    For full-suite Vitest validation, if the issue/preflight declares `pnpm test` and `package.json` has `"test": "vitest run"`, run `pnpm test -- --configLoader runner` instead and record it as satisfying `pnpm test`. Do not rerun plain `pnpm test` after a `node_modules/.vite-temp` EPERM.
    If `git status --short --branch` shows staged or unstaged product edits but no unmerged files, this is dirty handoff recovery. Do not make another product edit first. Inspect only focused `git diff -- <dirty-file>` reads for the dirty files; do not run `git log` or `git diff --stat` — the runtime denies them. If recent passed Orocsy validation/gate evidence already covers those dirty files and the diff has not changed since that evidence, do not rerun the same validation command before committing; stage, commit, push the existing PR branch, and request fresh review. Rerun exact focused validation only when evidence is missing, stale, or the focused diff is incomplete/invalid.
    In dirty handoff recovery, edit again only when focused validation fails and names the exact broken file/assertion.
    If no unmerged files remain and the issue brief has a `Current Validation Rework` section or an open correction names validation failures, treat the turn as validation rework: inspect and edit only the named in-scope helper/test files before rerunning validation.
    In validation rework, do not just rerun the same failing validation command and create the same correction again. First restore the missing export, fallback behavior, or directly named assertion path from the issue brief/correction; then rerun the exact focused validation command.
    If a declared validation command fails after merge/review fixes and names an exact failing test, route, helper, or assertion on the integration branch, treat it as integration validation rework for this handoff branch. Make the smallest same-branch fix, or create an Orocsy inbox correction with the exact command, failing test/assertion, and next action; do not record only a `validation.blocker` event and stop.
    A single conflict-marker scan with `grep` is allowed only when it searches for `<<<<<<<`, `=======`, and `>>>>>>>` across explicit issue-brief/preflight files.
    If current validation rework needs symbol lookup after the correction names exact files, use only bounded `rg -n "literal" <exact named file...>` over those named files. Never use grep for symbol search, recursive flags, or bare directories such as `src`, `app`, `lib`, or `tests`.
    Append `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . event append --type tool.finished --status passed --tool "technical-miu-trace"` after naming the exact conflict files, validation commands, PR number or missing-PR finding, and same-branch push target.
    Resolve only the named conflict files and directly required helper/test files; do not do unrelated feature work or broad rediscovery.
    Do not reason through every conflict before editing. Take unresolved files in `git status --short` order; read one conflicted file, resolve and `git add` it, then append `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . event append --type tool.finished --status passed --tool "integration-conflict-slice"` before moving to the next file.
    If you cannot confidently resolve the first current conflicted file from the file itself and directly named helper paths, create an Orocsy blocker/correction immediately instead of reading broader context.
    After the conflict fix, run focused validation, commit, push to the existing PR branch, and request fresh review with `gh pr comment <pr-number> --body '@codex review'`.
    Never create a duplicate PR, move Linear to a terminal state, or merge the PR automatically.
    If validation, git push, GitHub, Linear, PATH, auth, network/provider access, or approval/input fails, record the exact command, stderr/output, failure kind, and next action in an Orocsy blocker/correction before stopping.
    Do not use a plain `event append --type validation.blocker` as the only blocker record; create an Orocsy inbox correction when stopping for a blocker.
    """
    |> String.trim()
  end

  @doc """
  Returns the effective forbidden command patterns for a workspace, merging the
  configured patterns with the dispatch-mode-specific additions. Used by the
  prompt builder to surface the command policy to workers instead of leaving it
  as an invisible tripwire.
  """
  @spec effective_forbidden_command_patterns_for(String.t()) :: [String.t()]
  def effective_forbidden_command_patterns_for(workspace) when is_binary(workspace) do
    patterns = Config.settings!().codex.forbidden_command_patterns
    effective_forbidden_command_patterns(workspace, patterns)
  rescue
    _error -> []
  end

  def effective_forbidden_command_patterns_for(_workspace), do: []

  @spec bounded_git_log_exception_available?(String.t()) :: boolean()
  def bounded_git_log_exception_available?(workspace) when is_binary(workspace) do
    bounded_git_log_exception_available?(
      workspace,
      Config.settings!().codex.forbidden_command_patterns
    )
  rescue
    _error -> false
  end

  def bounded_git_log_exception_available?(_workspace), do: false

  if Mix.env() == :test do
    @spec command_policy_violation_for_test(String.t(), String.t()) ::
            :ok | {:error, String.t(), String.t()}
    def command_policy_violation_for_test(workspace, command) do
      command_policy_violation_for_test(
        workspace,
        command,
        Config.settings!().codex.forbidden_command_patterns
      )
    end

    @spec command_policy_violation_for_test(String.t(), String.t(), [String.t()]) ::
            :ok | {:error, String.t(), String.t()}
    def command_policy_violation_for_test(workspace, command, configured_patterns) do
      command_policy_violation_for_test(workspace, command, configured_patterns, nil)
    end

    @spec command_policy_violation_for_test(
            String.t(),
            String.t(),
            [String.t()],
            String.t() | nil
          ) ::
            :ok | {:error, String.t(), String.t()}
    def command_policy_violation_for_test(workspace, command, configured_patterns, worker_host)
        when is_list(configured_patterns) do
      payload = %{"params" => %{"msg" => %{"command" => command}}}
      patterns = effective_forbidden_command_patterns(workspace, configured_patterns)

      forbidden_command_violation(payload, %{
        patterns: patterns,
        configured_patterns: configured_patterns,
        workspace: workspace,
        worker_host: worker_host
      })
    end

    @spec bounded_git_log_exception_available_for_test(String.t(), [String.t()]) :: boolean()
    def bounded_git_log_exception_available_for_test(workspace, configured_patterns)
        when is_list(configured_patterns) do
      bounded_git_log_exception_available?(workspace, configured_patterns)
    end

    def pure_scope_read_command_for_test(command) when is_binary(command),
      do: pure_scope_read_command?(command)

    def worker_thread_overrides_for_test(params, workspace),
      do: maybe_put_worker_thread_overrides(params, workspace)

    def scope_access_resolution_for_test(workspace, command, pattern, configured_patterns \\ [])
        when is_binary(workspace) and is_binary(command) and is_binary(pattern) do
      resolve_scope_access_violation(
        %{
          workspace: workspace,
          worker_host: nil,
          configured_patterns: configured_patterns
        },
        command,
        pattern
      )
    end
  end

  defp bounded_git_log_exception_available?(workspace, configured_patterns)
       when is_binary(workspace) and is_list(configured_patterns) do
    payload = %{
      "params" => %{
        "msg" => %{"command" => "/bin/zsh -lc 'git log -5 --oneline --decorate'"}
      }
    }

    patterns = effective_forbidden_command_patterns(workspace, configured_patterns)

    dispatch_preflight_mode(workspace) == "review_rework" and
      forbidden_command_violation(payload, %{
        patterns: patterns,
        configured_patterns: configured_patterns,
        workspace: workspace
      }) == :ok
  end

  defp bounded_git_log_exception_available?(_workspace, _configured_patterns), do: false

  defp effective_forbidden_command_patterns(workspace, patterns) when is_binary(workspace) and is_list(patterns) do
    case dispatch_preflight_mode(workspace) do
      "review_rework" ->
        configured_patterns = review_rework_configured_forbidden_patterns(workspace, patterns)
        Enum.uniq(configured_patterns ++ @review_rework_forbidden_command_patterns ++ review_rework_path_guard_patterns(workspace))

      "fresh_implementation" ->
        Enum.uniq(patterns ++ @fresh_implementation_forbidden_command_patterns)

      "handoff_recovery" ->
        if structured_handoff_recovery?(workspace) do
          Enum.uniq(patterns ++ @fresh_implementation_forbidden_command_patterns)
        else
          patterns
        end

      "integration_check" ->
        Enum.uniq(patterns ++ @fresh_implementation_forbidden_command_patterns)

      _mode ->
        patterns
    end
  end

  defp effective_forbidden_command_patterns(_workspace, patterns), do: patterns

  defp structured_handoff_recovery?(workspace) do
    case DispatchPreflight.read(workspace) do
      {:ok,
       %{
         "mode" => "handoff_recovery",
         "requirements" => %{"runtime_contract_status" => "structured"}
       }} ->
        true

      _ ->
        false
    end
  end

  defp review_rework_configured_forbidden_patterns(workspace, patterns) when is_binary(workspace) and is_list(patterns) do
    case DispatchPreflight.read(workspace) do
      {:ok, %{"mode" => "review_rework"} = preflight} ->
        if review_rework_implementation_child?(preflight) do
          Enum.reject(patterns, &broad_sed_range_forbidden_pattern?/1)
        else
          patterns
        end

      _ ->
        patterns
    end
  rescue
    _error -> patterns
  end

  defp review_rework_configured_forbidden_patterns(_workspace, patterns), do: patterns

  defp broad_sed_range_forbidden_pattern?(pattern) when is_binary(pattern) do
    String.contains?(pattern, "sed -n") and
      String.contains?(pattern, ["1,(1[6-9]", "260,560p"])
  end

  defp broad_sed_range_forbidden_pattern?(_pattern), do: false

  defp dispatch_preflight_mode(workspace) when is_binary(workspace) do
    case DispatchPreflight.read(workspace) do
      {:ok, %{"mode" => mode}} when is_binary(mode) -> mode
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp review_rework_path_guard_patterns(workspace) do
    case DispatchPreflight.read(workspace) do
      {:ok, %{"mode" => "review_rework"} = preflight} ->
        preflight
        |> review_rework_allowed_read_paths(workspace)
        |> review_rework_path_guard_patterns_for_paths()

      _ ->
        []
    end
  rescue
    _error -> []
  end

  defp review_rework_allowed_read_paths(%{} = preflight, workspace) do
    if review_rework_implementation_child?(preflight) do
      review_rework_strict_implementation_read_paths(preflight, workspace)
    else
      review_rework_broad_read_paths(preflight, workspace)
    end
  end

  defp review_rework_broad_read_paths(%{} = preflight, workspace) do
    base_paths =
      (review_rework_feedback_paths(preflight) ++
         review_rework_requirement_paths(preflight) ++
         review_rework_issue_brief_paths(preflight, workspace) ++
         review_rework_referenced_api_route_paths(preflight, workspace) ++
         review_rework_correction_paths(workspace) ++
         review_rework_validation_metadata_paths(workspace))
      |> Enum.uniq()

    counterpart_paths = review_rework_counterpart_paths(workspace, base_paths)
    route_helper_paths = review_rework_route_helper_paths(workspace, base_paths ++ counterpart_paths)

    (base_paths ++
       counterpart_paths ++
       route_helper_paths ++
       review_rework_local_import_paths(workspace, base_paths ++ counterpart_paths ++ route_helper_paths))
    |> Enum.uniq()
  end

  defp review_rework_implementation_child?(%{"requirements" => %{"ticket_type" => ticket_type}})
       when is_binary(ticket_type) do
    ticket_type
    |> String.trim()
    |> String.downcase()
    |> Kernel.==("implementation")
  end

  defp review_rework_implementation_child?(_preflight), do: false

  defp review_rework_strict_implementation_read_paths(%{} = preflight, workspace) do
    (review_rework_feedback_target_paths(preflight) ++
       review_rework_implementation_write_scope_paths(preflight) ++
       review_rework_scope_bundle_read_paths(preflight) ++
       review_rework_implementation_shared_file_paths(preflight) ++
       review_rework_implementation_validation_paths(preflight) ++
       review_rework_correction_paths(workspace, :open_only) ++
       review_rework_validation_metadata_paths(workspace))
    |> Enum.uniq()
  end

  defp review_rework_implementation_write_scope_paths(%{"requirements" => %{"write_scope" => write_scope}}) do
    write_scope
    |> string_values()
    |> Enum.flat_map(&paths_from_requirement_text/1)
  end

  defp review_rework_implementation_write_scope_paths(_preflight), do: []

  defp review_rework_scope_bundle_read_paths(%{"requirements" => %{"scope_bundle" => bundle}})
       when is_map(bundle) do
    (scope_bundle_entry_paths(Map.get(bundle, "write_scope"), ["write", "write-if-conflicted"]) ++
       scope_bundle_entry_paths(Map.get(bundle, "read_context"), ["read", "search"]))
    |> Enum.uniq()
  end

  defp review_rework_scope_bundle_read_paths(_preflight), do: []

  defp scope_bundle_entry_paths(entries, allowed_operations) when is_list(entries) do
    entries
    |> Enum.flat_map(fn
      %{"path" => path, "operation" => operation}
      when is_binary(path) and (is_binary(operation) or is_nil(operation)) ->
        if operation in allowed_operations or is_nil(operation) do
          [normalize_requirement_path(path)]
        else
          []
        end

      %{"path" => path} when is_binary(path) ->
        [normalize_requirement_path(path)]

      _ ->
        []
    end)
    |> Enum.filter(&review_rework_path_like?/1)
    |> Enum.uniq()
  end

  defp scope_bundle_entry_paths(_entries, _allowed_operations), do: []

  defp review_rework_implementation_shared_file_paths(%{"requirements" => %{"shared_files" => shared_files}}) do
    shared_files
    |> string_values()
    |> Enum.filter(&review_rework_read_only_shared_file?/1)
    |> Enum.flat_map(&paths_from_requirement_text/1)
  end

  defp review_rework_implementation_shared_file_paths(_preflight), do: []

  defp review_rework_read_only_shared_file?(value) when is_binary(value) do
    text = String.downcase(value)

    read_only_context? =
      String.contains?(text, "read-only") or
        String.contains?(text, "readonly") or
        String.contains?(text, "context") or
        String.contains?(text, "support path")

    excluded? =
      String.contains?(text, "owned by") or
        String.contains?(text, "owned-by") or
        String.contains?(text, "out of scope") or
        String.contains?(text, "out-of-scope")

    read_only_context? and not excluded?
  end

  defp review_rework_read_only_shared_file?(_value), do: false

  defp review_rework_implementation_validation_paths(%{"requirements" => %{"validation" => validation}})
       when is_map(validation) do
    [Map.get(validation, "commands"), Map.get(validation, "files")]
    |> Enum.flat_map(&string_values/1)
    |> Enum.flat_map(&paths_from_requirement_text/1)
  end

  defp review_rework_implementation_validation_paths(_preflight), do: []

  defp review_rework_feedback_paths(%{"review" => %{"feedback" => feedback}}) when is_list(feedback) do
    feedback
    |> Enum.flat_map(fn
      %{"path" => path, "body" => body} when is_binary(path) and path != "" ->
        [path | paths_from_review_rework_text(body)]

      %{"path" => path} when is_binary(path) and path != "" ->
        [path]

      %{"body" => body} ->
        paths_from_review_rework_text(body)

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp review_rework_feedback_paths(_preflight), do: []

  defp review_rework_feedback_target_paths(%{"review" => %{"feedback" => feedback}}) when is_list(feedback) do
    feedback
    |> Enum.flat_map(fn
      %{"path" => path} when is_binary(path) and path != "" -> [path]
      %{"body" => body} -> paths_from_review_rework_text(body)
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp review_rework_feedback_target_paths(_preflight), do: []

  defp review_rework_requirement_paths(%{"requirements" => requirements}) when is_map(requirements) do
    requirements
    |> requirement_path_sources()
    |> Enum.flat_map(&paths_from_requirement_text/1)
  end

  defp review_rework_requirement_paths(_preflight), do: []

  defp review_rework_issue_brief_paths(%{"requirements" => %{"issue_brief" => %{"path" => path}}}, workspace)
       when is_binary(path) and is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_path = Path.expand(path, expanded_workspace)

    with true <- String.starts_with?(expanded_path, expanded_workspace <> "/"),
         true <- File.regular?(expanded_path),
         {:ok, content} <- File.read(expanded_path) do
      paths_from_review_rework_text(content)
    else
      _ -> []
    end
  rescue
    _error -> []
  end

  defp review_rework_issue_brief_paths(_preflight, _workspace), do: []

  defp review_rework_referenced_api_route_paths(%{} = preflight, workspace) when is_binary(workspace) do
    preflight
    |> review_rework_reference_text(workspace)
    |> api_route_paths_from_text()
    |> Enum.flat_map(&next_app_api_route_candidates/1)
    |> Enum.filter(&local_workspace_file?(workspace, &1))
    |> Enum.uniq()
  end

  defp review_rework_referenced_api_route_paths(_preflight, _workspace), do: []

  defp review_rework_correction_paths(workspace, mode \\ :default)

  defp review_rework_correction_paths(workspace, mode) when is_binary(workspace) do
    workspace
    |> Path.join(".orocsy/delivery/inbox/correction_*.json")
    |> Path.wildcard()
    |> Enum.flat_map(&review_rework_correction_file_paths(workspace, &1, mode))
    |> Enum.uniq()
  end

  defp review_rework_correction_paths(_workspace, _mode), do: []

  defp review_rework_correction_file_paths(workspace, path, mode) do
    with true <- File.regular?(path),
         {:ok, content} <- File.read(path),
         {:ok, %{} = correction} <- Jason.decode(content),
         true <- correction_path_reference_allowed?(correction, mode) do
      correction
      |> correction_reference_text()
      |> paths_from_review_rework_text()
      |> Enum.filter(&local_workspace_file?(workspace, &1))
    else
      _ -> []
    end
  rescue
    _error -> []
  end

  defp correction_path_reference_allowed?(%{} = correction, :open_only) do
    open_correction?(correction)
  end

  defp correction_path_reference_allowed?(%{} = correction, _mode) do
    open_correction?(correction) or runtime_validation_reference_correction?(correction)
  end

  defp correction_path_reference_allowed?(_correction, _mode), do: false

  defp runtime_validation_reference_correction?(%{} = correction) do
    source = correction["source"] |> to_string() |> String.downcase()
    text = correction_reference_text(correction) |> String.downcase()

    String.starts_with?(source, "symphony.runtime") and
      String.contains?(text, ["validation", "failed", "failure", "pnpm ", "test "])
  end

  defp runtime_validation_reference_correction?(_correction), do: false

  defp open_correction?(%{} = correction) do
    normalize_correction_field(correction["status"]) == "open" and
      normalize_correction_field(correction["next_action"]) in ["block", "retry", "escalate"] and
      is_nil(correction["resolved_at"])
  end

  defp open_correction?(_correction), do: false

  defp normalize_correction_field(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_correction_field(_value), do: ""

  defp correction_reference_text(correction) when is_map(correction) do
    [
      Map.get(correction, "summary"),
      Map.get(correction, "findings"),
      Map.get(correction, "required_corrections"),
      Map.get(correction, "resolution_summary")
    ]
    |> string_values()
    |> Enum.join("\n")
  end

  defp correction_reference_text(_correction), do: ""

  defp api_route_paths_from_text(text) when is_binary(text) do
    ~r{(?:^|[\s`"'(])(/api/[A-Za-z0-9_\-./\[\]]+)}
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.flat_map(fn
      [path] -> [path |> String.trim_trailing(".") |> normalize_api_route_path()]
      _ -> []
    end)
    |> Enum.filter(&api_route_path?/1)
    |> Enum.uniq()
  end

  defp api_route_paths_from_text(_text), do: []

  defp normalize_api_route_path(path) when is_binary(path) do
    path
    |> String.split(~r/[?#]/, parts: 2)
    |> List.first()
    |> String.trim_trailing("/")
  end

  defp normalize_api_route_path(_path), do: ""

  defp api_route_path?(path) when is_binary(path) do
    path != "/api" and String.starts_with?(path, "/api/")
  end

  defp api_route_path?(_path), do: false

  defp next_app_api_route_candidates(route_path) when is_binary(route_path) do
    segments =
      route_path
      |> String.trim_leading("/")
      |> String.split("/", trim: true)

    case segments do
      ["api" | _rest] ->
        route_dir = Path.join(["src", "app" | segments])

        Enum.map([".ts", ".tsx", ".js", ".jsx"], fn ext ->
          Path.join(route_dir, "route#{ext}")
        end)

      _ ->
        []
    end
  end

  defp next_app_api_route_candidates(_route_path), do: []

  defp review_rework_validation_metadata_paths(workspace) when is_binary(workspace) do
    [
      "package.json",
      "vitest.config.ts",
      "vitest.config.mts",
      "vitest.config.cts",
      "vitest.config.js",
      "vitest.config.mjs",
      "vitest.config.cjs"
    ]
    |> Enum.filter(&local_workspace_file?(workspace, &1))
  end

  defp review_rework_validation_metadata_paths(_workspace), do: []

  defp requirement_path_sources(requirements) when is_map(requirements) do
    [
      Map.get(requirements, "write_scope"),
      Map.get(requirements, "shared_files"),
      get_in(requirements, ["validation", "commands"]),
      get_in(requirements, ["validation", "files"])
    ]
    |> Enum.flat_map(&string_values/1)
  end

  defp string_values(values) when is_list(values), do: Enum.flat_map(values, &string_values/1)
  defp string_values(value) when is_binary(value), do: [value]
  defp string_values(_value), do: []

  defp paths_from_requirement_text(text) when is_binary(text) do
    paths_from_review_rework_text(text)
  end

  defp paths_from_requirement_text(_text), do: []

  defp paths_from_review_rework_text(text) when is_binary(text) do
    ~r{`([^`]+)`|(?:^|[\s,;:"'(])((?:\./)?[A-Za-z0-9_.@+\-][A-Za-z0-9_\-./()\[\]@+]*\.(?:tsx|ts|jsx|js|mjs|cjs|md|json|yml|yaml|css|scss|html|svg|png))}
    |> Regex.scan(text)
    |> Enum.flat_map(fn captures ->
      captures
      |> tl()
      |> Enum.find(&(&1 != ""))
      |> case do
        path when is_binary(path) -> [normalize_requirement_path(path)]
        _ -> []
      end
    end)
    |> Enum.filter(&review_rework_path_like?/1)
  end

  defp paths_from_review_rework_text(_text), do: []

  defp review_rework_local_import_paths(workspace, source_paths) when is_binary(workspace) do
    source_paths = Enum.map(source_paths, &normalize_requirement_path/1)

    workspace
    |> collect_review_rework_local_import_paths(source_paths, 2, MapSet.new(source_paths))
    |> MapSet.difference(MapSet.new(source_paths))
    |> MapSet.to_list()
  end

  defp review_rework_local_import_paths(_workspace, _source_paths), do: []

  defp collect_review_rework_local_import_paths(_workspace, _source_paths, 0, seen), do: seen

  defp collect_review_rework_local_import_paths(workspace, source_paths, depth, seen) do
    next_paths =
      source_paths
      |> Enum.filter(&review_rework_code_file?/1)
      |> Enum.flat_map(&local_import_paths_from_file(workspace, &1))
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.uniq()

    collect_review_rework_local_import_paths(
      workspace,
      next_paths,
      depth - 1,
      Enum.into(next_paths, seen)
    )
  end

  defp review_rework_counterpart_paths(workspace, paths) when is_binary(workspace) do
    paths
    |> Enum.flat_map(&counterpart_path_candidates/1)
    |> Enum.filter(&local_workspace_file?(workspace, &1))
    |> Enum.map(&normalize_requirement_path/1)
    |> Enum.uniq()
  end

  defp review_rework_counterpart_paths(_workspace, _paths), do: []

  defp review_rework_route_helper_paths(workspace, paths) when is_binary(workspace) do
    paths
    |> Enum.flat_map(&route_helper_path_candidates/1)
    |> Enum.filter(&local_workspace_path?(workspace, &1))
    |> Enum.map(&normalize_requirement_path/1)
    |> Enum.uniq()
  end

  defp review_rework_route_helper_paths(_workspace, _paths), do: []

  defp route_helper_path_candidates(path) when is_binary(path) do
    path = normalize_requirement_path(path)
    basename = Path.basename(path)

    cond do
      String.starts_with?(path, "src/app/") and basename in ["route.ts", "route.tsx"] ->
        dir = Path.dirname(path)

        [
          Path.join(dir, "handler.ts"),
          Path.join(dir, "handler.tsx"),
          Path.join(dir, "handler.test.ts"),
          Path.join(dir, "handler.test.tsx"),
          Path.join(dir, "handler.spec.ts"),
          Path.join(dir, "handler.spec.tsx"),
          Path.join(dir, "route.test.ts"),
          Path.join(dir, "route.test.tsx"),
          Path.join(dir, "route.spec.ts"),
          Path.join(dir, "route.spec.tsx"),
          Path.join(dir, "view.ts"),
          Path.join(dir, "view.tsx"),
          Path.join(dir, "view.test.ts"),
          Path.join(dir, "view.test.tsx"),
          Path.join(dir, "view.spec.ts"),
          Path.join(dir, "view.spec.tsx")
        ]

      true ->
        []
    end
  end

  defp route_helper_path_candidates(_path), do: []

  defp counterpart_path_candidates(path) when is_binary(path) do
    path = normalize_requirement_path(path)

    cond do
      String.starts_with?(path, "tests/") ->
        source_counterpart_candidates(path)

      String.starts_with?(path, "src/") ->
        test_counterpart_candidates(path)

      true ->
        []
    end
  end

  defp counterpart_path_candidates(_path), do: []

  defp source_counterpart_candidates(path) do
    ext = Path.extname(path)
    stem = path |> Path.basename(ext) |> String.replace(~r/\.(test|spec)$/, "")
    relative_dir = test_relative_dir(path)
    hyphen_segments = String.split(stem, "-", trim: true)
    hyphen_source_candidates = hyphen_source_candidates(hyphen_segments, ext)

    [
      "src/#{stem}#{ext}",
      "src/lib/#{stem}#{ext}",
      "src/features/#{stem}#{ext}"
      | source_candidates_from_test_dir(relative_dir, stem, ext)
    ]
    |> Kernel.++(hyphen_source_candidates)
    |> Enum.uniq()
  end

  defp test_counterpart_candidates(path) do
    ext = Path.extname(path)
    stem = path |> Path.basename(ext) |> String.replace(~r/\.(test|spec)$/, "")

    path_segments =
      path
      |> Path.rootname()
      |> String.split("/", trim: true)
      |> Enum.drop(1)

    dashed_stem = Enum.join(path_segments, "-")

    [stem, dashed_stem]
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn candidate_stem ->
      [
        "tests/unit/#{candidate_stem}.test#{ext}",
        "tests/integration/#{candidate_stem}.test#{ext}",
        "tests/e2e/#{candidate_stem}.spec#{ext}"
      ]
    end)
    |> Enum.uniq()
  end

  defp test_relative_dir(path) do
    path
    |> Path.dirname()
    |> String.split("/", trim: true)
    |> Enum.drop(2)
    |> Enum.join("/")
  end

  defp source_candidates_from_test_dir("", _stem, _ext), do: []

  defp source_candidates_from_test_dir(relative_dir, stem, ext) do
    [
      "src/#{relative_dir}/#{stem}#{ext}",
      "src/lib/#{relative_dir}/#{stem}#{ext}",
      "src/features/#{relative_dir}/#{stem}#{ext}"
    ]
  end

  defp hyphen_source_candidates([first | rest], ext) when rest != [] do
    tail = Enum.join(rest, "-")

    [
      "src/#{first}/#{tail}#{ext}",
      "src/lib/#{first}/#{tail}#{ext}",
      "src/features/#{first}/#{tail}#{ext}"
    ]
  end

  defp hyphen_source_candidates(_segments, _ext), do: []

  defp review_rework_code_file?(path) when is_binary(path) do
    Path.extname(path) in [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"]
  end

  defp review_rework_code_file?(_path), do: false

  defp review_rework_supported_file?(path) when is_binary(path) do
    Path.extname(path) in [
      ".ts",
      ".tsx",
      ".js",
      ".jsx",
      ".mjs",
      ".cjs",
      ".md",
      ".json",
      ".toml",
      ".yml",
      ".yaml",
      ".css",
      ".scss",
      ".html",
      ".svg",
      ".png"
    ]
  end

  defp review_rework_supported_file?(_path), do: false

  defp local_import_paths_from_file(workspace, source_path) do
    workspace = Path.expand(workspace)
    expanded_source = Path.expand(source_path, workspace)

    with true <- String.starts_with?(expanded_source, workspace <> "/"),
         true <- File.regular?(expanded_source),
         {:ok, content} <- File.read(expanded_source) do
      source_path
      |> Path.dirname()
      |> import_specifiers_from_content(content)
      |> Enum.flat_map(&resolve_local_import_path(workspace, &1))
    else
      _ -> []
    end
  rescue
    _error -> []
  end

  defp import_specifiers_from_content(source_dir, content) do
    ~r/(?:from\s+|import\s*\(\s*|require\(\s*)["']((?:\.{1,2}|@|~)\/[^"']+)["']/
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.flat_map(fn
      [specifier] -> [{source_dir, specifier}]
      _ -> []
    end)
  end

  defp resolve_local_import_path(workspace, {source_dir, specifier}) do
    specifier
    |> local_import_base_candidates(workspace, source_dir)
    |> Enum.flat_map(&import_path_candidates/1)
    |> Enum.filter(&(local_workspace_file?(workspace, &1) or missing_local_import_candidate?(workspace, &1)))
    |> Enum.map(&normalize_requirement_path/1)
  end

  defp missing_local_import_candidate?(workspace, path) do
    local_workspace_path?(workspace, path) and
      review_rework_supported_file?(path) and
      not local_workspace_file?(workspace, path)
  end

  defp local_import_base_candidates(specifier, workspace, source_dir)
       when is_binary(specifier) and is_binary(source_dir) do
    cond do
      String.starts_with?(specifier, ["./", "../"]) ->
        [
          specifier
          |> Path.expand(Path.join("/", source_dir))
          |> String.trim_leading("/")
        ]

      String.starts_with?(specifier, ["@/", "~/"]) ->
        workspace_alias_import_base_candidates(workspace, specifier)

      true ->
        []
    end
  end

  defp local_import_base_candidates(_specifier, _workspace, _source_dir), do: []

  defp workspace_alias_import_base_candidates(workspace, specifier) do
    configured = configured_alias_import_base_candidates(workspace, specifier)

    case configured do
      [] -> fallback_alias_import_base_candidates(specifier)
      _ -> configured
    end
  end

  defp configured_alias_import_base_candidates(workspace, specifier) do
    ["tsconfig.json", "jsconfig.json"]
    |> Enum.flat_map(&alias_import_base_candidates_from_config(workspace, &1, specifier))
    |> Enum.uniq()
  end

  defp alias_import_base_candidates_from_config(workspace, config_file, specifier) do
    config_path = Path.join(workspace, config_file)

    with true <- File.regular?(config_path),
         {:ok, content} <- File.read(config_path),
         {:ok, %{"compilerOptions" => compiler_options}} <- Jason.decode(content),
         %{} = paths <- Map.get(compiler_options, "paths") do
      base_url = Map.get(compiler_options, "baseUrl", ".")

      paths
      |> Enum.flat_map(fn
        {alias_pattern, target_patterns} when is_binary(alias_pattern) and is_list(target_patterns) ->
          alias_target_base_candidates(alias_pattern, target_patterns, specifier, base_url)

        _ ->
          []
      end)
      |> Enum.uniq()
    else
      _ -> []
    end
  rescue
    _error -> []
  end

  defp alias_target_base_candidates(alias_pattern, target_patterns, specifier, base_url) do
    case alias_pattern_match(alias_pattern, specifier) do
      {:ok, wildcard} ->
        target_patterns
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.replace(&1, "*", wildcard))
        |> Enum.map(&normalize_alias_target_path(base_url, &1))

      :error ->
        []
    end
  end

  defp alias_pattern_match(alias_pattern, specifier) do
    case String.split(alias_pattern, "*", parts: 2) do
      [prefix, suffix] ->
        if String.starts_with?(specifier, prefix) and String.ends_with?(specifier, suffix) do
          wildcard = String.replace_prefix(specifier, prefix, "")
          wildcard = if suffix == "", do: wildcard, else: String.replace_suffix(wildcard, suffix, "")

          {:ok, wildcard}
        else
          :error
        end

      [exact] ->
        if exact == specifier, do: {:ok, ""}, else: :error
    end
  end

  defp normalize_alias_target_path(base_url, target_path) do
    [base_url, target_path]
    |> Path.join()
    |> Path.expand("/")
    |> String.trim_leading("/")
  end

  defp fallback_alias_import_base_candidates(specifier) do
    path = String.replace(specifier, ~r/^[@~]\//, "")

    [path, Path.join("src", path)]
    |> Enum.map(&normalize_alias_target_path(".", &1))
    |> Enum.uniq()
  end

  defp import_path_candidates(base) do
    if Path.extname(base) == "" do
      [
        base,
        "#{base}.ts",
        "#{base}.tsx",
        "#{base}.js",
        "#{base}.jsx",
        "#{base}.mjs",
        "#{base}.cjs",
        Path.join(base, "index.ts"),
        Path.join(base, "index.tsx"),
        Path.join(base, "index.js"),
        Path.join(base, "index.jsx")
      ]
    else
      [base]
    end
  end

  defp local_workspace_file?(workspace, path) do
    expanded_workspace = Path.expand(workspace)
    expanded_path = Path.expand(path, expanded_workspace)

    String.starts_with?(expanded_path, expanded_workspace <> "/") and File.regular?(expanded_path)
  end

  defp local_workspace_path?(workspace, path) do
    expanded_workspace = Path.expand(workspace)
    expanded_path = Path.expand(path, expanded_workspace)

    String.starts_with?(expanded_path, expanded_workspace <> "/")
  end

  defp normalize_requirement_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.trim_leading("./")
    |> String.replace(~r/:\d+(?:-\d+)?$/, "")
  end

  defp review_rework_path_like?(path) when is_binary(path) do
    path != "" and
      review_rework_supported_file?(path) and
      (String.contains?(path, "/") or review_rework_root_config_path?(path)) and
      not String.contains?(path, ["\t", "\n", "\r"]) and
      not String.starts_with?(path, ["http://", "https://", "origin/"])
  end

  defp review_rework_path_like?(_path), do: false

  defp review_rework_root_config_path?(path) when is_binary(path) do
    path in [
      "opennext.js",
      "open-next.config.ts",
      "open-next.config.js",
      "open-next.config.mjs",
      "next.config.ts",
      "next.config.js",
      "next.config.mjs",
      "wrangler.toml",
      "wrangler.json",
      "wrangler.jsonc",
      "package.json",
      "tsconfig.json",
      "DESIGN.md",
      "README.md",
      "AGENTS.md"
    ] or String.starts_with?(path, "vitest.config.")
  end

  defp review_rework_root_config_path?(_path), do: false

  defp review_rework_path_guard_patterns_for_paths([]), do: []

  defp review_rework_path_guard_patterns_for_paths(paths) do
    allowed_paths =
      paths
      |> Enum.map_join("|", &review_rework_allowed_path_pattern/1)

    [
      "(^|\\s|[\"'])sed\\s+-n\\s+\\S+\\s+(?!(?:--\\s+)?(?:#{allowed_paths})(\\s|[\"']|$))",
      "(^|\\s|[\"'])(cat|head|tail|nl)\\s+(?!(?:--\\s+)?(?:#{allowed_paths})(\\s|[\"']|$))"
    ]
  end

  defp review_rework_allowed_path_pattern(path) do
    variants =
      path
      |> review_rework_allowed_path_variants()
      |> Enum.map_join("|", fn variant ->
        escaped = Regex.escape(variant)
        "(?:#{escaped}|'#{escaped}'|\"#{escaped}\")"
      end)

    "(?:#{variants})"
  end

  defp review_rework_allowed_path_variants(path) when is_binary(path) do
    trimmed_root_path = String.trim_leading(path, "/")

    [path, trimmed_root_path]
    |> Enum.filter(&(&1 != ""))
    |> Enum.filter(fn variant ->
      variant == path or
        (review_rework_root_config_path?(variant) and not String.contains?(variant, "/"))
    end)
    |> Enum.uniq()
  end

  defp review_rework_allowed_path_variants(_path), do: []

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests, command_guard) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests,
      command_guard
    )
  end

  defp receive_loop(
         port,
         on_message,
         timeout_ms,
         pending_line,
         tool_executor,
         auto_approve_requests,
         command_guard
       ) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)

        handle_incoming(
          port,
          on_message,
          complete_line,
          timeout_ms,
          tool_executor,
          auto_approve_requests,
          command_guard
        )

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests,
          command_guard
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(
         port,
         on_message,
         data,
         timeout_ms,
         tool_executor,
         auto_approve_requests,
         command_guard
       ) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        observe_token_telemetry(command_guard, payload)
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        observe_token_telemetry(command_guard, payload)

        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        observe_token_telemetry(command_guard, payload)

        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => "error"} = payload} ->
        observe_token_telemetry(command_guard, payload)

        emit_turn_event(
          on_message,
          :codex_error,
          payload,
          payload_string,
          port,
          Map.get(payload, "params", payload)
        )

        {:error, {:codex_error, Map.get(payload, "params", payload)}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        observe_token_telemetry(command_guard, payload)

        if turn_aborted_payload?(payload) do
          handle_turn_aborted_payload(on_message, payload, payload_string, port)
        else
          case turn_token_budget_violation(payload, Config.settings!().codex.max_turn_total_tokens) do
            {:error, total_tokens, max_tokens} ->
              metadata = metadata_from_message(port, payload)

              emit_message(
                on_message,
                :turn_token_budget_exceeded,
                %{payload: payload, raw: payload_string, total_tokens: total_tokens, max_tokens: max_tokens},
                metadata
              )

              stop_port(port)
              {:error, {:turn_token_budget_exceeded, total_tokens, max_tokens}}

            :ok ->
              handle_turn_method(
                port,
                on_message,
                payload,
                payload_string,
                method,
                timeout_ms,
                tool_executor,
                auto_approve_requests,
                command_guard
              )
          end
        end

      {:ok, payload} ->
        observe_token_telemetry(command_guard, payload)

        if turn_aborted_payload?(payload) do
          handle_turn_aborted_payload(on_message, payload, payload_string, port)
        else
          emit_message(
            on_message,
            :other_message,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata_from_message(port, payload)
          )

          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests, command_guard)
        end

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests, command_guard)
    end
  end

  defp observe_token_telemetry(%{token_telemetry: telemetry}, payload) do
    TokenTelemetry.observe(telemetry, payload)
  end

  defp observe_token_telemetry(_command_guard, _payload), do: :ok

  defp start_token_telemetry(workspace, issue, thread_id, turn_id, opts, nil) do
    TokenTelemetry.start_turn(workspace, issue, thread_id, turn_id, turn_number: Keyword.get(opts, :turn_number, 1))
  end

  defp start_token_telemetry(workspace, issue, thread_id, turn_id, opts, worker_host) when is_binary(worker_host) do
    Logger.info("Token telemetry disabled for remote worker_host=#{worker_host}; remote telemetry writes are not implemented")

    TokenTelemetry.disabled_turn(
      workspace,
      issue,
      thread_id,
      turn_id,
      turn_number: Keyword.get(opts, :turn_number, 1),
      reason: :remote_worker_unsupported
    )
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_aborted_payload(on_message, payload, payload_string, port) do
    details = turn_aborted_details(payload)

    emit_turn_event(
      on_message,
      :turn_aborted,
      payload,
      payload_string,
      port,
      details
    )

    {:error, {:turn_aborted, details}}
  end

  defp turn_aborted_payload?(%{"method" => "codex/event/turn_aborted"}), do: true
  defp turn_aborted_payload?(%{"method" => "turn/aborted"}), do: true
  defp turn_aborted_payload?(payload) when is_map(payload), do: payload_contains_type?(payload, "turn_aborted", 0)
  defp turn_aborted_payload?(_payload), do: false

  defp turn_aborted_details(%{"params" => params}) when is_map(params), do: params
  defp turn_aborted_details(payload) when is_map(payload), do: payload
  defp turn_aborted_details(payload), do: payload

  defp payload_contains_type?(_value, _type, depth) when depth > 6, do: false

  defp payload_contains_type?(%{} = payload, type, depth) do
    Map.get(payload, "type") == type or
      Map.get(payload, :type) == type or
      Enum.any?(payload, fn {_key, value} -> payload_contains_type?(value, type, depth + 1) end)
  end

  defp payload_contains_type?(values, type, depth) when is_list(values) do
    Enum.any?(values, &payload_contains_type?(&1, type, depth + 1))
  end

  defp payload_contains_type?(_value, _type, _depth), do: false

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests,
         command_guard
       ) do
    metadata = metadata_from_message(port, payload)

    cond do
      fresh_checkpoint_stop_reached?(command_guard) ->
        emit_message(
          on_message,
          :fresh_checkpoint_stop,
          %{
            payload: payload,
            raw: payload_string,
            checkpoint_event: "technical-miu-trace",
            reason: "fresh_implementation_first_checkpoint_reached"
          },
          metadata
        )

        stop_port(port)
        {:ok, :fresh_checkpoint_stop}

      true ->
        case forbidden_command_violation(payload, command_guard) do
          {:error, command, pattern} ->
            case resolve_scope_access_violation(command_guard, command, pattern) do
              {:allow, {:scope_access_decision, decision, policy}} ->
                record_scope_access_events(
                  command_guard,
                  command,
                  pattern,
                  decision,
                  policy
                )

                handle_allowed_turn_method(
                  port,
                  on_message,
                  payload,
                  payload_string,
                  method,
                  timeout_ms,
                  tool_executor,
                  auto_approve_requests,
                  metadata,
                  command_guard
                )

              {:deny, decision} ->
                record_scope_access_events(command_guard, command, pattern, decision)

                emit_message(
                  on_message,
                  :forbidden_command,
                  %{payload: payload, raw: payload_string, command: command, pattern: pattern},
                  metadata
                )

                {:error, {:forbidden_command, command, pattern}}

              :defer ->
                record_scope_access_events(command_guard, command, pattern)

                emit_message(
                  on_message,
                  :forbidden_command,
                  %{payload: payload, raw: payload_string, command: command, pattern: pattern},
                  metadata
                )

                {:error, {:forbidden_command, command, pattern}}
            end

          :ok ->
            handle_allowed_turn_method(
              port,
              on_message,
              payload,
              payload_string,
              method,
              timeout_ms,
              tool_executor,
              auto_approve_requests,
              metadata,
              command_guard
            )
        end
    end
  end

  defp fresh_checkpoint_stop_reached?(%{
         workspace: workspace,
         fresh_checkpoint_stop_enabled: true,
         fresh_checkpoint_present_at_turn_start: false
       })
       when is_binary(workspace) do
    fresh_implementation_checkpoint_ready?(workspace)
  end

  defp fresh_checkpoint_stop_reached?(_command_guard), do: false

  defp handle_allowed_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests,
         metadata,
         command_guard
       ) do
    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          "",
          tool_executor,
          auto_approve_requests,
          command_guard
        )

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")

          receive_loop(
            port,
            on_message,
            timeout_ms,
            "",
            tool_executor,
            auto_approve_requests,
            command_guard
          )
        end
    end
  end

  defp forbidden_command_violation(payload, %{patterns: patterns, workspace: workspace} = command_guard)
       when is_list(patterns) do
    command = command_text(payload)
    command_for_patterns = command_for_forbidden_patterns(command)

    cond do
      is_nil(command) ->
        :ok

      delivery_inbox_command_substitution?(command) ->
        {:error, command, "delivery_inbox_metadata_command_substitution"}

      open_correction_blocks_review_classification?(command_for_patterns, workspace) ->
        {:error, command, "open_correction_requires_scoped_fix_before_review_feedback_classified"}

      unsafe_playwright_correction_validation?(command_for_patterns, workspace, Map.get(command_guard, :worker_host)) ->
        {:error, command, "playwright_browser_correction_requires_runtime_controller_handoff"}

      symlinked_vitest_full_test_command?(command_for_patterns, workspace) ->
        {:error, command, "symlinked_vitest_full_test_requires_configLoader_runner"}

      dirty_validated_handoff_recheck_before_commit?(command_for_patterns, workspace) ->
        {:error, command, @review_rework_dirty_validated_handoff_recheck_pattern}

      match = first_matching_command_pattern(command_for_patterns, patterns) ->
        cond do
          match == @review_rework_git_diff_base_pattern and
              scope_audit_allowed?(command_for_patterns, workspace) ->
            :ok

          match == @review_rework_git_log_pattern and
            not configured_forbidden_command_match?(command_for_patterns, command_guard) and
              bounded_git_log_metadata_allowed?(command_for_patterns, workspace) ->
            :ok

          gh_api_pattern?(match) and integration_check_readonly_gh_api_allowed?(command_for_patterns, workspace) ->
            :ok

          gh_api_pattern?(match) and handoff_gh_api_allowed?(command_for_patterns, workspace) ->
            :ok

          grep_pattern?(match) and integration_check_show_ref_filter_allowed?(command_for_patterns, workspace) ->
            :ok

          grep_pattern?(match) and scoped_conflict_marker_scan_allowed?(command_for_patterns, workspace) ->
            :ok

          grep_pattern?(match) and scoped_file_grep_allowed?(command_for_patterns, workspace) ->
            :ok

          rg_pattern?(match) and scoped_file_rg_allowed?(command_for_patterns, workspace) ->
            :ok

          review_rework_missing_referenced_read_allowed?(command_for_patterns, workspace) ->
            :ok

          true ->
            {:error, command, match}
        end

      true ->
        :ok
    end
  end

  defp forbidden_command_violation(payload, patterns) when is_list(patterns) do
    command = command_text(payload)
    command_for_patterns = command_for_forbidden_patterns(command)

    cond do
      is_nil(command) ->
        :ok

      match = first_matching_command_pattern(command_for_patterns, patterns) ->
        {:error, command, match}

      true ->
        :ok
    end
  end

  defp forbidden_command_violation(_payload, _patterns), do: :ok

  defp configured_forbidden_command_match?(command, %{configured_patterns: patterns})
       when is_binary(command) and is_list(patterns) do
    not is_nil(first_matching_command_pattern(command, patterns))
  end

  defp configured_forbidden_command_match?(_command, _command_guard), do: false

  defp record_scope_access_events(%{workspace: workspace}, command, pattern)
       when is_binary(workspace) and is_binary(command) and is_binary(pattern) do
    workspace
    |> scope_access_events(command, pattern)
    |> Enum.each(&append_scope_access_event(workspace, &1))
  rescue
    error ->
      Logger.warning("Failed to record scope access events: #{Exception.message(error)}")
      :ok
  end

  defp record_scope_access_events(_command_guard, _command, _pattern), do: :ok

  defp record_scope_access_events(%{workspace: workspace}, command, pattern, decision)
       when is_binary(workspace) and is_binary(command) and is_binary(pattern) and is_map(decision) do
    workspace
    |> scope_access_events(command, pattern, decision)
    |> Enum.each(&append_scope_access_event(workspace, &1))
  rescue
    error ->
      Logger.warning("Failed to record resolved scope access events: #{Exception.message(error)}")
      :ok
  end

  defp record_scope_access_events(command_guard, command, pattern, _decision),
    do: record_scope_access_events(command_guard, command, pattern)

  defp record_scope_access_events(
         %{workspace: workspace},
         command,
         pattern,
         decision,
         policy
       )
       when is_binary(workspace) and is_binary(command) and is_binary(pattern) and
              is_map(decision) and is_map(policy) do
    command
    |> ScopeAccess.events(pattern, policy, scope_access_attrs(workspace), decision)
    |> Enum.each(&append_scope_access_event(workspace, &1))
  rescue
    error ->
      Logger.warning("Failed to record resolved scope access events: #{Exception.message(error)}")
      :ok
  end

  defp record_scope_access_events(command_guard, command, pattern, decision, _policy),
    do: record_scope_access_events(command_guard, command, pattern, decision)

  defp scope_access_events(workspace, command, pattern) do
    ScopeAccess.events(command, pattern, scope_access_policy(workspace), scope_access_attrs(workspace))
  end

  defp scope_access_events(workspace, command, pattern, decision) do
    ScopeAccess.events(
      command,
      pattern,
      scope_access_policy(workspace),
      scope_access_attrs(workspace),
      decision
    )
  end

  defp scope_access_policy(workspace) when is_binary(workspace) do
    case DispatchPreflight.read(workspace) do
      {:ok, preflight} when is_map(preflight) -> preflight
      _ -> %{}
    end
  rescue
    _error -> %{}
  end

  defp scope_access_policy(_workspace), do: %{}

  defp resolve_scope_access_violation(
         %{workspace: workspace, worker_host: nil} = command_guard,
         command,
         pattern
       )
       when is_binary(workspace) and is_binary(command) and
              pattern != @review_rework_dirty_validated_handoff_recheck_pattern do
    if configured_forbidden_command_match?(command, command_guard) or
         not scope_generated_violation?(pattern, workspace) do
      :defer
    else
      policy = scope_access_policy(workspace)

      case ScopeAccess.classify_command(command, policy) do
        %{} = request ->
          if request["broad"] == true or
               scope_access_command_eligible?(command, request) do
            case ScopeAccessController.decide(request, policy, workspace) do
              {:allow_once, patch} ->
                if scope_access_command_eligible?(command, request) do
                  case ScopeAccessController.write_policy_patch(workspace, patch) do
                    {:ok, written_patch} ->
                      {:allow, {:scope_access_decision, written_patch, policy}}

                    {:error, reason} ->
                      decision =
                        request
                        |> ScopeAccess.decision_for()
                        |> Map.put("reason_class", "policy_patch_write_failed")
                        |> Map.put("error", inspect(reason))

                      {:deny, decision}
                  end
                else
                  :defer
                end

              {decision, correction_attrs} when decision in [:block, :escalate] ->
                {:deny, correction_attrs}
            end
          else
            :defer
          end

        _ ->
          :defer
      end
    end
  rescue
    error ->
      Logger.warning("Failed to resolve scope access in app server: #{Exception.message(error)}")
      :defer
  end

  defp resolve_scope_access_violation(_command_guard, _command, _pattern), do: :defer

  defp scope_generated_violation?(pattern, workspace)
       when is_binary(pattern) and is_binary(workspace) do
    pattern in @review_rework_forbidden_command_patterns or
      pattern in @fresh_implementation_forbidden_command_patterns or
      pattern in review_rework_path_guard_patterns(workspace)
  end

  defp scope_generated_violation?(_pattern, _workspace), do: false

  defp scope_access_command_eligible?(
         command,
         %{
           "operation" => operation,
           "command_class" => command_class,
           "broad" => false
         } = request
       )
       when operation in ["read", "search"] and
              command_class in [
                "bounded_file_read",
                "bounded_file_search",
                "directory_listing",
                "git_diff",
                "git_discovery"
              ] do
    normalized = unwrap_shell_login_command(command)
    pure_scope_read_command?(normalized) and all_scope_read_operands_classified?(normalized, request)
  end

  defp scope_access_command_eligible?(_command, _request), do: false

  defp all_scope_read_operands_classified?(
         command,
         %{"paths" => requested_paths, "command_class" => command_class}
       )
       when is_binary(command) and is_list(requested_paths) and is_binary(command_class) do
    case scope_read_operand_paths(command, command_class) do
      paths when is_list(paths) and paths != [] ->
        normalized_requested = requested_paths |> Enum.map(&normalize_scope_operand_path/1) |> MapSet.new()
        normalized_operands = paths |> Enum.map(&normalize_scope_operand_path/1) |> MapSet.new()
        normalized_operands == normalized_requested

      _ ->
        false
    end
  rescue
    _error -> false
  end

  defp all_scope_read_operands_classified?(_command, _request), do: false

  defp scope_read_operand_paths(command, command_class) when is_binary(command) do
    case {command_class, OptionParser.split(command)} do
      {"bounded_file_read", ["sed" | args]} ->
        args |> Enum.reject(&scope_read_option_token?/1) |> List.last() |> List.wrap()

      {"bounded_file_read", [tool | args]} when tool in ["cat", "head", "tail", "nl"] ->
        scope_read_non_option_operands(args)

      {"bounded_file_search", [tool | args]} when tool in ["rg", "grep"] ->
        args
        |> scope_read_non_option_operands()
        |> case do
          [_pattern | paths] -> paths
          _ -> []
        end

      {"directory_listing", ["ls" | args]} ->
        scope_read_non_option_operands(args)

      {command_class, ["git", _subcommand | args]}
      when command_class in ["git_diff", "git_discovery"] ->
        git_scope_read_operands(args)

      _ ->
        :unclassified
    end
  end

  defp scope_read_operand_paths(_command, _command_class), do: :unclassified

  defp git_scope_read_operands(args) when is_list(args) do
    case Enum.split_while(args, &(&1 != "--")) do
      {_options, ["--" | paths]} -> Enum.reject(paths, &(&1 == ""))
      _ -> :unclassified
    end
  end

  defp scope_read_non_option_operands(args) when is_list(args) do
    {operands, _after_options?} =
      Enum.reduce(args, {[], false}, fn token, {operands, after_options?} ->
        cond do
          token == "--" -> {operands, true}
          after_options? -> {[token | operands], true}
          scope_read_option_token?(token) -> {operands, false}
          Regex.match?(~r/\A\d+\z/, token) -> {operands, false}
          true -> {[token | operands], false}
        end
      end)

    Enum.reverse(operands)
  end

  defp scope_read_non_option_operands(_args), do: []

  defp scope_read_option_token?(token) when is_binary(token),
    do: token == "--" or String.starts_with?(token, "-")

  defp scope_read_option_token?(_token), do: true

  defp normalize_scope_operand_path(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim_leading("./")
    |> String.trim_trailing("/")
  end

  defp normalize_scope_operand_path(_path), do: ""

  defp unwrap_shell_login_command(command) when is_binary(command) do
    normalized =
      command
      |> unescape_shell_argument_quotes()
      |> String.trim()

    cond do
      String.starts_with?(normalized, ~s(/bin/zsh -lc ")) and
          String.ends_with?(normalized, "\"") ->
        normalized
        |> String.trim_leading(~s(/bin/zsh -lc "))
        |> String.trim_trailing("\"")

      String.starts_with?(normalized, "/bin/zsh -lc '") and
          String.ends_with?(normalized, "'") ->
        normalized
        |> String.trim_leading("/bin/zsh -lc '")
        |> String.trim_trailing("'")

      true ->
        normalized
    end
  end

  defp unwrap_shell_login_command(_command), do: ""

  defp pure_scope_read_command?(command) when is_binary(command) do
    not command_chain_operator_outside_quotes?(command) and
      not String.contains?(command, ["$(", "`"]) and
      not unsafe_scope_read_option?(command) and
      Regex.match?(
        ~r/\A(?:sed\s+-n|(?:cat|head|tail|nl|rg|grep|ls)\s|git\s+(?:diff|log|ls-files)(?:\s|$))/,
        command
      )
  end

  defp pure_scope_read_command?(_command), do: false

  defp unsafe_scope_read_option?(command) when is_binary(command) do
    (String.starts_with?(command, "sed ") and not safe_sed_print_slice?(command)) or
      (String.starts_with?(command, "rg ") and
         Regex.match?(
           ~r/(?:^|\s)(?:-f(?:\S+)?|--(?:file|pre(?:-glob)?|ignore-file|hostname-bin)(?:=|\s|$))/,
           command
         )) or
      (String.starts_with?(command, "grep ") and
         Regex.match?(~r/(?:^|\s)(?:-f(?:\S+)?|--(?:file|exclude-from)(?:=|\s|$))/, command)) or
      (Regex.match?(~r/\Agit\s+(?:diff|log)(?:\s|$)/, command) and
         not (Regex.match?(~r/(?:^|\s)--no-ext-diff(?:\s|$)/, command) and
                Regex.match?(~r/(?:^|\s)--no-textconv(?:\s|$)/, command))) or
      (String.starts_with?(command, "git ") and
         Regex.match?(~r/(?:^|\s)--(?:ext-diff|output|textconv)(?:=|\s|$)/, command))
  end

  defp unsafe_scope_read_option?(_command), do: false

  defp safe_sed_print_slice?(command) when is_binary(command) do
    Regex.match?(
      ~r/\Ased\s+-n\s+(?:'\d+(?:,\d+)?p'|"\d+(?:,\d+)?p"|\d+(?:,\d+)?p)\s+(?:--\s+)?(?:'[^']+'|"[^"]+"|[A-Za-z0-9_.\/-]+)\z/,
      command
    )
  end

  defp safe_sed_print_slice?(_command), do: false

  defp scope_access_attrs(workspace) when is_binary(workspace) do
    case DispatchPreflight.read(workspace) do
      {:ok, preflight} when is_map(preflight) ->
        %{
          "issue" => Map.get(preflight, "issue"),
          "branch" => Map.get(preflight, "branch"),
          "dispatch_mode" => Map.get(preflight, "mode")
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      _ ->
        %{}
    end
  rescue
    _error -> %{}
  end

  defp scope_access_attrs(_workspace), do: %{}

  defp append_scope_access_event(workspace, event) when is_binary(workspace) and is_map(event) do
    path = Path.join(workspace, @delivery_event_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(event) <> "\n", [:append])
  end

  defp append_scope_access_event(_workspace, _event), do: :ok

  defp open_correction_blocks_review_classification?(command, workspace)
       when is_binary(command) and is_binary(workspace) do
    dispatch_preflight_mode(workspace) == "review_rework" and
      String.contains?(command, "review-feedback-classified") and
      Workspace.open_blocking_corrections_in_workspace(workspace) != []
  rescue
    _error -> false
  end

  defp open_correction_blocks_review_classification?(_command, _workspace), do: false

  defp delivery_inbox_command_substitution?(command) when is_binary(command) do
    normalized = unescape_shell_argument_quotes(command)

    delivery_inbox_create_command?(normalized) and
      shell_command_substitution?(normalized)
  end

  defp delivery_inbox_command_substitution?(_command), do: false

  defp unsafe_playwright_correction_validation?(command, workspace, worker_host)
       when is_binary(command) and is_binary(workspace) do
    playwright_test_command?(command) and
      open_playwright_browser_correction?(workspace, worker_host)
  rescue
    _error -> false
  end

  defp unsafe_playwright_correction_validation?(_command, _workspace, _worker_host), do: false

  defp playwright_test_command?(command) when is_binary(command) do
    command
    |> unescape_shell_argument_quotes()
    |> String.replace(~r/\s+/, " ")
    |> String.contains?("playwright test")
  end

  defp playwright_test_command?(_command), do: false

  defp open_playwright_browser_correction?(workspace, worker_host) when is_binary(workspace) do
    case Workspace.inspect_blocking_corrections_in_workspace(workspace, worker_host) do
      {:ok, corrections} ->
        Enum.any?(corrections, &DispatchPreflight.playwright_browser_correction?/1)

      {:error, _reason} ->
        false
    end
  end

  defp open_playwright_browser_correction?(_workspace, _worker_host), do: false

  defp symlinked_vitest_full_test_command?(command, workspace)
       when is_binary(command) and is_binary(workspace) do
    symlinked_node_modules?(workspace) and
      package_test_script_vitest?(workspace) and
      plain_pnpm_test_command?(command)
  end

  defp symlinked_vitest_full_test_command?(_command, _workspace), do: false

  defp dirty_validated_handoff_recheck_before_commit?(command, workspace)
       when is_binary(command) and is_binary(workspace) do
    dispatch_preflight_mode(workspace) == "review_rework" and
      dirty_validated_handoff_pending?(workspace) and
      dirty_validated_handoff_recheck_command?(command, workspace)
  rescue
    _error -> false
  end

  defp dirty_validated_handoff_recheck_before_commit?(_command, _workspace), do: false

  defp dirty_validated_handoff_pending?(workspace) when is_binary(workspace) do
    dirty_paths = meaningful_git_dirty_paths(workspace)

    dirty_paths != [] and dirty_paths_validated_after_last_change?(workspace, dirty_paths)
  end

  defp dirty_validated_handoff_pending?(_workspace), do: false

  defp dirty_paths_validated_after_last_change?(workspace, dirty_paths) do
    case latest_passed_validation_or_gate_event_at(workspace) do
      %DateTime{} = validated_at ->
        Enum.all?(dirty_paths, &dirty_path_not_newer_than?(workspace, &1, validated_at))

      :unknown ->
        true

      nil ->
        false
    end
  end

  defp dirty_path_not_newer_than?(workspace, path, %DateTime{} = validated_at) do
    case File.stat(Path.join(workspace, path), time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} when is_integer(mtime) ->
        DateTime.diff(DateTime.from_unix!(mtime), validated_at, :second) <= 0

      _ ->
        false
    end
  rescue
    _error -> false
  end

  defp dirty_validated_handoff_recheck_command?(command, workspace) do
    normalized =
      command
      |> unescape_shell_argument_quotes()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    git_diff_command?(normalized) or
      file_read_of_dirty_path?(normalized, workspace) or
      validation_command?(normalized)
  end

  defp git_diff_command?(command) when is_binary(command) do
    Regex.match?(~r/(^|[\s"'])git\s+diff(\s|["']|$)/, command)
  end

  defp file_read_of_dirty_path?(command, workspace) when is_binary(command) and is_binary(workspace) do
    simple_file_read_command?(command) and
      command
      |> paths_from_review_rework_text()
      |> Enum.any?(&(&1 in meaningful_git_dirty_paths(workspace)))
  end

  defp validation_command?(command) when is_binary(command) do
    Regex.match?(~r/(^|[\s"'])(?:corepack\s+)?(?:pnpm|npm|yarn|npx)\s+/, command) and
      String.contains?(command, ["test", "vitest", "lint", "type-check", "typecheck", "build"])
  end

  defp validation_command?(_command), do: false

  defp plain_pnpm_test_command?(command) when is_binary(command) do
    normalized =
      command
      |> unescape_shell_argument_quotes()
      |> String.replace(~r/\s+/, " ")

    Regex.match?(~r/(?:^|[\s'"])(?:corepack\s+)?pnpm\s+test(?:\s|["']|$)/, normalized) and
      not Regex.match?(~r/\s--configLoader\s+runner(?:\s|["']|$)/, normalized)
  end

  defp plain_pnpm_test_command?(_command), do: false

  defp symlinked_node_modules?(workspace) when is_binary(workspace) do
    case File.lstat(Path.join(workspace, "node_modules")) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  rescue
    _error -> false
  end

  defp symlinked_node_modules?(_workspace), do: false

  defp package_test_script_vitest?(workspace) when is_binary(workspace) do
    package_json = Path.join(workspace, "package.json")

    with {:ok, content} <- File.read(package_json),
         {:ok, %{"scripts" => %{"test" => test_script}}} <- Jason.decode(content) do
      is_binary(test_script) and Regex.match?(~r/(^|\s)vitest(\s|$)/, test_script)
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp package_test_script_vitest?(_workspace), do: false

  defp integration_check_show_ref_filter_allowed?(command, workspace)
       when is_binary(command) and is_binary(workspace) do
    with true <- dispatch_preflight_mode(workspace) == "integration_check",
         true <- show_ref_grep_command?(command),
         {:ok, preflight} <- DispatchPreflight.read(workspace) do
      allowed_refs = integration_check_allowed_ref_names(preflight)
      requested_refs = show_ref_grep_ref_names(command)

      requested_refs != [] and Enum.all?(requested_refs, &MapSet.member?(allowed_refs, &1))
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp integration_check_show_ref_filter_allowed?(_command, _workspace), do: false

  defp scoped_conflict_marker_scan_allowed?(command, workspace) when is_binary(command) and is_binary(workspace) do
    with true <- dispatch_preflight_mode(workspace) in ["review_rework", "integration_check"],
         true <- conflict_marker_grep_command?(command),
         {:ok, preflight} <- DispatchPreflight.read(workspace) do
      allowed_paths =
        preflight
        |> review_rework_allowed_read_paths(workspace)
        |> MapSet.new()

      command_paths =
        command
        |> paths_from_review_rework_text()
        |> Enum.uniq()

      command_paths != [] and
        Enum.all?(command_paths, &MapSet.member?(allowed_paths, &1))
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp scoped_conflict_marker_scan_allowed?(_command, _workspace), do: false

  defp scoped_file_grep_allowed?(command, workspace) when is_binary(command) and is_binary(workspace) do
    with true <- dispatch_preflight_mode(workspace) in ["review_rework", "integration_check"],
         true <- file_scoped_grep_command?(command),
         {:ok, preflight} <- DispatchPreflight.read(workspace) do
      allowed_paths =
        preflight
        |> review_rework_allowed_read_paths(workspace)
        |> MapSet.new()

      command_paths =
        command
        |> search_path_tokens()
        |> Enum.uniq()

      scoped_search_paths_allowed?(workspace, command_paths, allowed_paths)
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp scoped_file_grep_allowed?(_command, _workspace), do: false

  defp scoped_file_rg_allowed?(command, workspace) when is_binary(command) and is_binary(workspace) do
    with true <- dispatch_preflight_mode(workspace) in ["review_rework", "integration_check"],
         true <- file_scoped_rg_command?(command),
         {:ok, preflight} <- DispatchPreflight.read(workspace) do
      allowed_paths =
        preflight
        |> review_rework_allowed_read_paths(workspace)
        |> MapSet.new()

      command_paths =
        command
        |> search_path_tokens()
        |> Enum.uniq()

      scoped_search_paths_allowed?(workspace, command_paths, allowed_paths)
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp scoped_file_rg_allowed?(_command, _workspace), do: false

  defp scoped_search_paths_allowed?(workspace, command_paths, allowed_paths)
       when is_binary(workspace) and is_list(command_paths) do
    allowed_anchor? = Enum.any?(command_paths, &MapSet.member?(allowed_paths, &1))
    bounded_search? = length(command_paths) in 1..6
    bounded_exact_file_search? = bounded_search? and allowed_anchor?
    bounded_exact_test_search? = bounded_search? and Enum.all?(command_paths, &exact_test_file_path?(workspace, &1))

    bounded_exact_test_search? or
      (command_paths != [] and
         Enum.all?(command_paths, fn path ->
           MapSet.member?(allowed_paths, path) or
             (bounded_exact_file_search? and exact_test_file_path?(workspace, path))
         end))
  end

  defp scoped_search_paths_allowed?(_workspace, _command_paths, _allowed_paths), do: false

  defp exact_test_file_path?(workspace, path) when is_binary(workspace) and is_binary(path) do
    expanded_workspace = Path.expand(workspace)
    expanded_path = Path.expand(path, expanded_workspace)

    local_workspace_path?(workspace, path) and
      String.starts_with?(expanded_path, expanded_workspace <> "/") and
      review_rework_supported_file?(path) and
      (String.starts_with?(path, "tests/") or
         Regex.match?(~r/(^|\/)[^\/]+\.(test|spec)\.(ts|tsx|js|jsx|mjs|cjs)$/, path))
  end

  defp exact_test_file_path?(_workspace, _path), do: false

  defp review_rework_missing_referenced_read_allowed?(command, workspace)
       when is_binary(command) and is_binary(workspace) do
    with true <- dispatch_preflight_mode(workspace) == "review_rework",
         true <- simple_file_read_command?(command),
         {:ok, preflight} <- DispatchPreflight.read(workspace) do
      allowed_paths =
        preflight
        |> review_rework_allowed_read_paths(workspace)
        |> MapSet.new()

      reference_text = review_rework_reference_text(preflight, workspace)

      command_paths =
        command
        |> paths_from_review_rework_text()
        |> Enum.uniq()

      command_paths != [] and
        Enum.all?(command_paths, fn path ->
          MapSet.member?(allowed_paths, path) or
            missing_referenced_workspace_path?(workspace, path, reference_text)
        end)
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp review_rework_missing_referenced_read_allowed?(_command, _workspace), do: false

  defp simple_file_read_command?(command) when is_binary(command) do
    read_command =
      Regex.match?(~r/(^|\s|["'])sed\s+-n\s+\S+\s+/, command) or
        Regex.match?(~r/(^|\s|["'])(cat|head|tail|nl)\s+/, command)

    read_command and
      not Regex.match?(~r/\s(?:&&|\|\|)\s|;\s|\$\(|`/, command)
  end

  defp simple_file_read_command?(_command), do: false

  defp missing_referenced_workspace_path?(workspace, path, reference_text)
       when is_binary(workspace) and is_binary(path) and is_binary(reference_text) do
    local_workspace_path?(workspace, path) and
      review_rework_supported_file?(path) and
      not local_workspace_file?(workspace, path) and
      path_referenced_by_review_text?(path, reference_text)
  end

  defp missing_referenced_workspace_path?(_workspace, _path, _reference_text), do: false

  defp path_referenced_by_review_text?(path, reference_text) do
    path
    |> semantic_path_tokens()
    |> Enum.any?(&String.contains?(reference_text, &1))
  end

  defp semantic_path_tokens(path) when is_binary(path) do
    path
    |> Path.rootname()
    |> String.downcase()
    |> String.split(~r{[./\-_]+}, trim: true)
    |> Enum.reject(&(&1 in ["src", "app", "api", "lib", "test", "tests", "route", "handler", "index"]))
    |> Enum.filter(&(String.length(&1) >= 4))
    |> Enum.uniq()
  end

  defp semantic_path_tokens(_path), do: []

  defp review_rework_reference_text(preflight, workspace) do
    [
      inspect(preflight),
      review_rework_issue_brief_content(preflight, workspace)
    ]
    |> Enum.join("\n")
    |> String.downcase()
  end

  defp review_rework_issue_brief_content(
         %{"requirements" => %{"issue_brief" => %{"path" => path}}},
         workspace
       )
       when is_binary(path) and is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_path = Path.expand(path, expanded_workspace)

    with true <- String.starts_with?(expanded_path, expanded_workspace <> "/"),
         true <- File.regular?(expanded_path),
         {:ok, content} <- File.read(expanded_path) do
      content
    else
      _ -> ""
    end
  rescue
    _error -> ""
  end

  defp review_rework_issue_brief_content(_preflight, _workspace), do: ""

  defp conflict_marker_grep_command?(command) when is_binary(command) do
    String.contains?(command, "grep") and
      String.contains?(command, "-n") and
      String.contains?(command, "<<<<<<<") and
      String.contains?(command, "=======") and
      String.contains?(command, ">>>>>>>")
  end

  defp conflict_marker_grep_command?(_command), do: false

  defp show_ref_grep_command?(command) when is_binary(command) do
    normalized = String.replace(command, ~r/\s+/, " ")

    Regex.match?(~r/(^|[\s'"])git\s+show-ref\s+--heads\s+--remotes\s*\|\s*grep\s+-E\s+["']?refs\/\(heads\|remotes\/origin\)\/\(?[^"']+["']?/, normalized) and
      not Regex.match?(~r/\s(?:&&|\|\|)\s|;\s|\$\(|`/, normalized)
  end

  defp show_ref_grep_command?(_command), do: false

  defp show_ref_grep_ref_names(command) when is_binary(command) do
    ~r/refs\/\(heads\|remotes\/origin\)\/\(?([^"']+)/
    |> Regex.scan(command, capture: :all_but_first)
    |> Enum.flat_map(fn [refs] ->
      refs
      |> String.trim()
      |> String.trim_trailing(")")
      |> String.trim_trailing("$")
      |> String.split("|", trim: true)
    end)
    |> Enum.map(fn ref ->
      ref
      |> String.trim()
      |> String.trim_leading("^")
      |> String.trim_trailing("$")
      |> String.trim_trailing(")")
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp show_ref_grep_ref_names(_command), do: []

  defp file_scoped_grep_command?(command) when is_binary(command) do
    Regex.match?(~r/(^|\s|["'])grep\s+/, command) and
      String.contains?(command, "-n") and
      not Regex.match?(~r/(^|\s)-[^-\s]*[Rr][^-\s]*(\s|$)/, command) and
      not Regex.match?(~r/(^|\s)--recursive(\s|=|$)/, command) and
      not broad_search_path_token?(command) and
      not command_chain_operator_outside_quotes?(command) and
      not Regex.match?(~r/\$\(|`/, command)
  end

  defp file_scoped_grep_command?(_command), do: false

  defp file_scoped_rg_command?(command) when is_binary(command) do
    Regex.match?(~r/(^|\s|["'])rg\s+/, command) and
      (String.contains?(command, "-n") or String.contains?(command, "--line-number")) and
      not Regex.match?(~r/(^|\s)(--files|--glob|-g|--type|-t|--replace|-r)(\s|=|$)/, command) and
      not broad_search_path_token?(command) and
      not command_chain_operator_outside_quotes?(command) and
      not Regex.match?(~r/\$\(|`/, command)
  end

  defp file_scoped_rg_command?(_command), do: false

  defp broad_search_path_token?(command) when is_binary(command) do
    command
    |> search_path_tokens()
    |> Enum.any?(fn path ->
      normalized = normalize_requirement_path(path)
      root = normalized |> String.split("/", parts: 2) |> List.first()

      root in ["src", "app", "apps", "packages", "lib", "tests"] and
        not review_rework_supported_file?(normalized)
    end)
  end

  defp broad_search_path_token?(_command), do: false

  defp search_path_tokens(command) when is_binary(command) do
    ~r/(?:^|[\s"'])(\.?\/?(?:(?:src|app|apps|packages|lib|tests)(?:\/[A-Za-z0-9_\-.()\[\]@+]+)*|(?:opennext\.js|open-next\.config\.(?:ts|js|mjs)|next\.config\.(?:ts|js|mjs)|wrangler\.(?:toml|json|jsonc)|package\.json|tsconfig\.json|DESIGN\.md|README\.md|AGENTS\.md|vitest\.config\.[A-Za-z0-9]+)))(?=$|[\s"'])/
    |> Regex.scan(command, capture: :all_but_first)
    |> Enum.flat_map(fn
      [path] when is_binary(path) -> [normalize_requirement_path(path)]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp search_path_tokens(_command), do: []

  defp grep_pattern?(pattern) when is_binary(pattern), do: String.contains?(pattern, "grep")
  defp grep_pattern?(_pattern), do: false
  defp rg_pattern?(pattern) when is_binary(pattern), do: String.contains?(pattern, "rg")
  defp rg_pattern?(_pattern), do: false

  defp bounded_git_log_metadata_allowed?(command, workspace)
       when is_binary(command) and is_binary(workspace) do
    dispatch_preflight_mode(workspace) == "review_rework" and
      command
      |> worker_command_tokens()
      |> bounded_git_log_metadata_tokens?()
  end

  defp bounded_git_log_metadata_allowed?(_command, _workspace), do: false

  defp worker_command_tokens(command) do
    case OptionParser.split(command) do
      [shell, "-lc", inner]
      when shell in ["zsh", "bash", "sh", "/bin/zsh", "/bin/bash", "/bin/sh"] ->
        OptionParser.split(inner)

      tokens ->
        tokens
    end
  rescue
    _error -> []
  end

  defp bounded_git_log_metadata_tokens?(["git", "log" | args]) do
    count_args = Enum.filter(args, &Regex.match?(~r/^-\d{1,2}$/, &1))
    oneline_count = Enum.count(args, &(&1 == "--oneline"))
    decorate_count = Enum.count(args, &(&1 in ["--decorate", "--no-decorate"]))

    length(count_args) == 1 and
      oneline_count == 1 and
      decorate_count <= 1 and
      length(args) == 2 + decorate_count and
      Enum.all?(args, fn arg ->
        arg == "--oneline" or
          arg in ["--decorate", "--no-decorate"] or
          Regex.match?(~r/^-\d{1,2}$/, arg)
      end) and
      bounded_git_log_count?(hd(count_args))
  end

  defp bounded_git_log_metadata_tokens?(_tokens), do: false

  defp bounded_git_log_count?("-" <> count) do
    case Integer.parse(count) do
      {value, ""} -> value in 1..20
      _ -> false
    end
  end

  defp bounded_git_log_count?(_count), do: false

  defp integration_check_allowed_ref_names(preflight) when is_map(preflight) do
    requirements =
      case preflight do
        %{"requirements" => requirements} when is_map(requirements) -> requirements
        _ -> %{}
      end

    [
      "main",
      "master",
      preflight["branch"],
      get_in(preflight, ["review", "head_ref"]),
      requirements["base_branch"],
      requirements["branch"],
      requirements["integration_branch"]
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp integration_check_allowed_ref_names(_preflight), do: MapSet.new()

  defp command_for_forbidden_patterns(command) when is_binary(command) do
    normalized_command = unescape_shell_argument_quotes(command)

    cond do
      shell_command_substitution?(normalized_command) ->
        normalized_command

      delivery_event_append_command?(normalized_command) ->
        redact_delivery_event_append_metadata(normalized_command)

      delivery_inbox_create_command?(normalized_command) ->
        redact_delivery_inbox_create_metadata(normalized_command)

      true ->
        normalized_command
    end
  end

  defp command_for_forbidden_patterns(command), do: command

  defp shell_command_substitution?(command) when is_binary(command) do
    String.contains?(command, "$(") or String.contains?(command, "`")
  end

  defp shell_command_substitution?(_command), do: false

  defp delivery_event_append_command?(command) when is_binary(command) do
    String.contains?(command, ".codex/delivery/bin/orocsy.py") and
      String.contains?(command, " event append")
  end

  defp delivery_inbox_create_command?(command) when is_binary(command) do
    String.contains?(command, ".codex/delivery/bin/orocsy.py") and
      String.contains?(command, " inbox create")
  end

  defp redact_delivery_event_append_metadata(command) when is_binary(command) do
    ["command", "summary", "message", "details", "detail", "body", "tool", "step"]
    |> Enum.reduce(command, fn flag, acc ->
      acc
      |> String.replace(~r/(--#{flag}\s+)"(?:\\.|[^"\\])*"/, "\\1REDACTED")
      |> String.replace(~r/(--#{flag}\s+)'(?:\\.|[^'\\])*'/, "\\1REDACTED")
      |> String.replace(~r/(--#{flag}\s+)[^\s]+/, "\\1REDACTED")
    end)
  end

  defp redact_delivery_inbox_create_metadata(command) when is_binary(command) do
    ["summary", "finding", "required-correction"]
    |> Enum.reduce(command, fn flag, acc ->
      acc
      |> String.replace(~r/(--#{flag}=)"(?:\\.|[^"\\])*"/, "\\1REDACTED")
      |> String.replace(~r/(--#{flag}=)'(?:\\.|[^'\\])*'/, "\\1REDACTED")
      |> String.replace(~r/(--#{flag}=)[^\s]+/, "\\1REDACTED")
      |> String.replace(~r/(--#{flag}\s+)"(?:\\.|[^"\\])*"/, "\\1REDACTED")
      |> String.replace(~r/(--#{flag}\s+)'(?:\\.|[^'\\])*'/, "\\1REDACTED")
      |> String.replace(~r/(--#{flag}\s+)[^\s]+/, "\\1REDACTED")
    end)
  end

  defp gh_api_pattern?(pattern) do
    pattern in [
      "(^|\\s)gh\\s+api(\\s|$)",
      "(^|\\s|[\"'])gh\\s+api(\\s|$)"
    ]
  end

  defp handoff_gh_api_allowed?(command, workspace) when is_binary(command) and is_binary(workspace) do
    Regex.match?(~r/(^|[\s'"])gh\s+api(\s|$)/, command) and
      handoff_gh_api_command?(command) and durable_handoff_progress?(workspace)
  end

  defp handoff_gh_api_allowed?(_command, _workspace), do: false

  defp integration_check_readonly_gh_api_allowed?(command, workspace)
       when is_binary(command) and is_binary(workspace) do
    dispatch_preflight_mode(workspace) == "integration_check" and
      Regex.match?(~r/(^|[\s'"])gh\s+api(\s|$)/, command) and
      readonly_gh_api_method?(command) and
      handoff_gh_api_command?(command)
  end

  defp integration_check_readonly_gh_api_allowed?(_command, _workspace), do: false

  defp readonly_gh_api_method?(command) when is_binary(command) do
    normalized =
      command
      |> unescape_shell_argument_quotes()
      |> String.replace(~r/\s+/, " ")

    cond do
      Regex.match?(~r/(?:^|[\s'"])gh\s+api\s+graphql(\s|$)/, normalized) ->
        false

      Regex.match?(~r/\s(?:--method|-X)\s+(?:POST|PUT|PATCH|DELETE)(?:\s|$)/i, normalized) ->
        false

      Regex.match?(~r/\s(?:-f|-F|--field|--raw-field)\s+/, normalized) ->
        Regex.match?(~r/\s--method\s+GET(?:\s|$)/, normalized)

      true ->
        true
    end
  end

  defp readonly_gh_api_method?(_command), do: false

  defp handoff_gh_api_command?(command) do
    normalized =
      command
      |> unescape_shell_argument_quotes()
      |> String.replace(~r/\s+/, " ")

    cond do
      Regex.match?(~r/(?:^|[\s'"])gh\s+api\s+graphql(\s|$)/, normalized) ->
        handoff_gh_api_graphql_command?(normalized)

      true ->
        endpoints =
          ~r/(?:^|[\s'"])gh\s+api(?:\s+--method\s+GET)?\s+["']?([^\s"']+)/
          |> Regex.scan(normalized, capture: :all_but_first)
          |> Enum.map(fn [endpoint] -> endpoint end)

        endpoints != [] and Enum.all?(endpoints, &handoff_gh_api_endpoint?/1)
    end
  end

  defp handoff_gh_api_graphql_command?(command) do
    String.contains?(command, "repository(") and
      String.contains?(command, "pullRequest") and
      not Regex.match?(~r/\bmutation\b/i, command) and
      not Regex.match?(~r/\b(?:addComment|addPullRequestReview|create[A-Z]|update[A-Z]|delete[A-Z])\b/, command)
  end

  defp handoff_gh_api_endpoint?(endpoint) do
    allowed_patterns = [
      ~r/^repos\/[^\/\s]+\/[^\/\s]+\/branches\/[^\s"']+$/,
      ~r/^repos\/[^\/\s]+\/[^\/\s]+\/git\/refs(?:\/[^\s"']*)?$/,
      ~r/^repos\/[^\/\s]+\/[^\/\s]+\/git\/ref\/[^\s"']+$/,
      ~r/^repos\/[^\/\s]+\/[^\/\s]+\/pulls(?:\?[^\s"']*)?$/,
      ~r/^repos\/[^\/\s]+\/[^\/\s]+\/pulls\/\d+$/,
      ~r/^repos\/[^\/\s]+\/[^\/\s]+\/pulls\/\d+\/comments$/,
      ~r/^repos\/[^\/\s]+\/[^\/\s]+\/pulls\/\d+\/reviews$/,
      ~r/^repos\/[^\/\s]+\/[^\/\s]+\/issues\/\d+\/comments$/
    ]

    Enum.any?(allowed_patterns, &Regex.match?(&1, endpoint))
  end

  defp unescape_shell_argument_quotes(command) when is_binary(command) do
    String.replace(command, ~r/\\(["'])/, "\\1")
  end

  defp unescape_shell_argument_quotes(command), do: command

  defp durable_handoff_progress?(workspace) when is_binary(workspace) do
    events_path = Path.join(workspace, ".orocsy/delivery/events/events.jsonl")

    events_path
    |> File.stream!()
    |> Enum.any?(fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, %{"event" => "tool.finished", "status" => "passed", "tool" => "technical-miu-trace"}} ->
          meaningful_git_progress?(workspace)

        {:ok, %{"event" => "tool.finished", "status" => "passed"}} ->
          true

        {:ok, %{"event" => "gate.post-miu", "status" => "passed"}} ->
          true

        _ ->
          false
      end
    end)
  rescue
    _error -> false
  end

  defp latest_passed_validation_or_gate_event_at(workspace) when is_binary(workspace) do
    workspace
    |> Path.join(@delivery_event_path)
    |> cached_latest_passed_validation_or_gate_event_at()
  end

  defp latest_passed_validation_or_gate_event_at(_workspace), do: nil

  defp cached_latest_passed_validation_or_gate_event_at(events_path) when is_binary(events_path) do
    cache_key = {__MODULE__, :latest_passed_validation_or_gate_event_at, events_path}

    case Process.get(cache_key) do
      {signature, result} ->
        current_signature = delivery_event_file_signature(events_path)

        if current_signature == signature do
          result
        else
          scan_cached_latest_passed_validation_or_gate_event_at(events_path, cache_key, current_signature)
        end

      _ ->
        scan_cached_latest_passed_validation_or_gate_event_at(
          events_path,
          cache_key,
          delivery_event_file_signature(events_path)
        )
    end
  end

  defp scan_cached_latest_passed_validation_or_gate_event_at(events_path, cache_key, signature) do
    result =
      if signature == :missing do
        nil
      else
        events_path
        |> File.stream!()
        |> Enum.reduce([], fn line, acc -> [String.trim(line) | acc] |> Enum.take(40) end)
        |> Enum.reverse()
        |> Enum.reduce(nil, fn line, latest ->
          case passed_validation_or_gate_event_at(line) do
            nil -> latest
            timestamp -> timestamp
          end
        end)
      end

    Process.put(cache_key, {signature, result})
    result
  rescue
    _error ->
      Process.put(cache_key, {signature, nil})
      nil
  end

  defp passed_validation_or_gate_event_at(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"status" => "passed"} = event} ->
        event_name = Map.get(event, "event", "") |> to_string()
        tool = Map.get(event, "tool", "") |> to_string() |> String.downcase()
        text = inspect(event, limit: :infinity, printable_limit: :infinity) |> String.downcase()

        if passed_validation_or_gate_event?(event_name, tool, text) do
          event_timestamp(event) || :unknown
        end

      _ ->
        nil
    end
  end

  defp passed_validation_or_gate_event_at(_line), do: nil

  defp passed_validation_or_gate_event?(event_name, tool, text) do
    event_name in ["gate.post-miu", "gate.required-evidence", "gate.declared-scope"] or
      (event_name == "validation" and String.contains?(text, ["test", "vitest", "typecheck", "lint", "build"])) or
      (event_name == "tool.finished" and
         (String.contains?(tool, ["validation", "test", "vitest", "typecheck", "lint", "build"]) or
            String.contains?(text, ["validation", "test", "vitest", "typecheck", "lint", "build"])))
  end

  defp event_timestamp(event) when is_map(event) do
    ["ts", "timestamp", "created_at"]
    |> Enum.find_value(fn key ->
      case Map.get(event, key) do
        value when is_binary(value) -> parse_event_timestamp(value)
        _ -> nil
      end
    end)
  end

  defp parse_event_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp fresh_implementation_checkpoint_ready?(workspace) when is_binary(workspace) do
    case DispatchPreflight.read(workspace) do
      {:ok, %{"requirements" => %{"runtime_contract_status" => "structured"}}} ->
        false

      _ ->
        technical_miu_trace_event?(workspace) and meaningful_git_progress?(workspace)
    end
  rescue
    _error -> false
  end

  defp fresh_implementation_checkpoint_ready?(_workspace), do: false

  defp technical_miu_trace_event?(workspace) when is_binary(workspace) do
    workspace
    |> Path.join(@delivery_event_path)
    |> cached_technical_miu_trace_event?()
  end

  defp technical_miu_trace_event?(_workspace), do: false

  defp cached_technical_miu_trace_event?(events_path) when is_binary(events_path) do
    cache_key = {__MODULE__, :technical_miu_trace_event, events_path}

    case Process.get(cache_key) do
      :present ->
        true

      {signature, result} ->
        current_signature = delivery_event_file_signature(events_path)

        if current_signature == signature do
          result
        else
          scan_cached_technical_miu_trace_event(events_path, cache_key, current_signature)
        end

      _ ->
        scan_cached_technical_miu_trace_event(
          events_path,
          cache_key,
          delivery_event_file_signature(events_path)
        )
    end
  end

  defp scan_cached_technical_miu_trace_event(events_path, cache_key, signature) do
    result =
      signature != :missing and
        events_path
        |> File.stream!()
        |> Enum.any?(fn line ->
          case Jason.decode(String.trim(line)) do
            {:ok, %{"event" => "tool.finished", "status" => "passed", "tool" => "technical-miu-trace"}} -> true
            _ -> false
          end
        end)

    Process.put(cache_key, if(result, do: :present, else: {signature, false}))

    result
  rescue
    _error ->
      Process.put(cache_key, {signature, false})
      false
  end

  defp delivery_event_file_signature(events_path) do
    case File.stat(events_path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> {size, mtime}
      _ -> :missing
    end
  end

  defp meaningful_git_progress?(workspace) when is_binary(workspace) do
    meaningful_git_dirty_paths(workspace) != [] or git_ahead_of_base?(workspace)
  rescue
    _error -> false
  end

  defp meaningful_git_progress?(_workspace), do: false

  defp meaningful_git_dirty_paths(workspace) do
    case System.cmd("git", ["status", "--porcelain=v1"], cd: workspace, stderr_to_stdout: true) do
      {status, 0} ->
        status
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&porcelain_status_paths/1)
        |> Enum.reject(&generated_runtime_path?/1)

      {_error, _exit_code} ->
        []
    end
  rescue
    _error -> []
  end

  defp git_ahead_of_base?(workspace) do
    ["origin/main", "main"]
    |> Enum.filter(&git_ref_exists?(workspace, &1))
    |> case do
      [] ->
        false

      base_refs ->
        args = ["log", "-1", "--format=%H", "HEAD"] ++ Enum.flat_map(base_refs, &[~s(--not), &1])

        case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
          {output, 0} -> String.trim(output) != ""
          {_error, _exit_code} -> false
        end
    end
  rescue
    _error -> false
  end

  defp git_ref_exists?(workspace, ref) do
    case System.cmd("git", ["rev-parse", "--verify", "--quiet", ref], cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _exit_code} -> false
    end
  rescue
    _error -> false
  end

  defp generated_runtime_path?(path) when is_binary(path) do
    String.starts_with?(path, [".orocsy/", ".codex/"])
  end

  defp generated_runtime_path?(_path), do: false

  defp porcelain_status_paths(line) when byte_size(line) >= 4 do
    path =
      line
      |> String.slice(3..-1//1)
      |> String.replace_prefix(~s("), "")
      |> String.replace_suffix(~s("), "")

    case path do
      "" -> []
      path -> [path |> String.split(" -> ") |> List.last()]
    end
  end

  defp porcelain_status_paths(_line), do: []

  defp first_matching_command_pattern(command, patterns) when is_binary(command) do
    Enum.find(patterns, fn pattern ->
      cond do
        pattern == @review_rework_command_chain_pattern ->
          command_chain_operator_outside_quotes?(command)

        pattern == @review_rework_git_diff_base_pattern ->
          git_diff_base_branch_without_path_scope?(command)

        pattern == @review_rework_dirty_validated_handoff_recheck_pattern ->
          false

        true ->
          case Regex.compile(pattern) do
            {:ok, regex} -> Regex.match?(regex, command)
            {:error, _reason} -> false
          end
      end
    end)
  end

  defp command_chain_operator_outside_quotes?(command) when is_binary(command) do
    command
    |> String.graphemes()
    |> chain_operator_scan(nil, nil)
  end

  defp command_chain_operator_outside_quotes?(_command), do: false

  defp chain_operator_scan([], _quote, _previous), do: false

  defp chain_operator_scan(["\\" | rest], "'", _previous) do
    chain_operator_scan(rest, "'", "\\")
  end

  defp chain_operator_scan(["\\" | [_escaped | rest]], quote, _previous) do
    chain_operator_scan(rest, quote, "\\")
  end

  defp chain_operator_scan([char | rest], nil, previous) when char in ["'", "\""] do
    chain_operator_scan(rest, char, previous)
  end

  defp chain_operator_scan([char | rest], quote, previous) when char == quote do
    chain_operator_scan(rest, nil, previous)
  end

  defp chain_operator_scan([char | rest], nil, previous) do
    next = List.first(rest)

    cond do
      char in ["\n", "\r", ">", "<"] ->
        true

      char == ";" ->
        true

      char == "|" and previous not in ["|", "\\"] and next != "|" ->
        true

      char == "|" and next == "|" ->
        true

      char == "&" and next == "&" ->
        true

      char == "&" ->
        true

      true ->
        chain_operator_scan(rest, nil, char)
    end
  end

  defp chain_operator_scan([char | rest], quote, _previous), do: chain_operator_scan(rest, quote, char)

  defp git_diff_base_branch_without_path_scope?(command) when is_binary(command) do
    normalized = String.replace(command, ~r/\s+/, " ")

    with true <- Regex.match?(~r/(^|[\s"'])git\s+diff\s+/, normalized),
         false <- Regex.match?(~r/(^|[\s"'])git\s+diff\s+--stat(\s|$)/, normalized) do
      diff_args =
        normalized
        |> String.split(~r/(^|[\s"'])git\s+diff\s+/, parts: 2, include_captures: false)
        |> List.last()
        |> Kernel.||("")

      before_path_scope =
        diff_args
        |> String.split(" -- ", parts: 2)
        |> List.first()

      String.contains?(before_path_scope, ["origin/", "release/", "@{upstream}"]) or
        Regex.match?(~r/(^|\s)(main|develop)(\s|$|\.{2})/, before_path_scope)
    else
      _ -> false
    end
  end

  defp git_diff_base_branch_without_path_scope?(_command), do: false

  defp scope_audit_allowed?(command, workspace) when is_binary(command) and is_binary(workspace) do
    case CommandIntent.classify(command, allowed_base_refs: scope_audit_base_refs(workspace)) do
      {:ok, %{kind: :scope_audit}} -> true
      _ -> false
    end
  rescue
    _error -> false
  end

  defp scope_audit_allowed?(_command, _workspace), do: false

  defp scope_audit_base_refs(workspace) do
    configured =
      case DispatchPreflight.read(workspace) do
        {:ok, preflight} when is_map(preflight) ->
          [
            preflight["base_branch"],
            get_in(preflight, ["requirements", "base_branch"]),
            get_in(preflight, ["review", "base_ref"])
          ]

        _ ->
          []
      end

    (["main", "master"] ++ configured)
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(&base_ref_variants/1)
    |> Enum.uniq()
  end

  defp base_ref_variants("origin/" <> _branch = ref), do: [ref]
  defp base_ref_variants(ref), do: [ref, "origin/#{ref}"]

  defp command_text(%{} = payload) do
    payload
    |> command_candidate()
    |> normalize_command()
    |> case do
      nil -> function_call_command_text(payload)
      command -> command
    end
  end

  defp command_text(_payload), do: nil

  defp function_call_command_text(%{} = payload) do
    payload
    |> function_call_candidates()
    |> Enum.find_value(&exec_command_function_call_text/1)
  end

  defp function_call_command_text(_payload), do: nil

  defp function_call_candidates(%{} = payload) do
    [
      payload,
      map_path(payload, ["payload"]),
      map_path(payload, ["params"]),
      map_path(payload, ["params", "payload"]),
      map_path(payload, ["params", "msg"]),
      map_path(payload, ["params", "msg", "payload"]),
      map_path(payload, ["params", "item"]),
      map_path(payload, ["params", "item", "payload"])
    ]
    |> Enum.filter(&is_map/1)
  end

  defp exec_command_function_call_text(%{"type" => "function_call", "name" => name} = item)
       when is_binary(name) do
    if exec_command_function_name?(name) do
      item
      |> Map.get("arguments")
      |> decode_function_call_arguments()
      |> command_from_function_call_arguments()
      |> normalize_command()
    end
  end

  defp exec_command_function_call_text(_item), do: nil

  defp exec_command_function_name?(name) when is_binary(name) do
    name == "exec_command" or String.ends_with?(name, ".exec_command")
  end

  defp decode_function_call_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{"cmd" => arguments}
    end
  end

  defp decode_function_call_arguments(%{} = arguments), do: arguments
  defp decode_function_call_arguments(_arguments), do: nil

  defp command_from_function_call_arguments(%{} = arguments) do
    map_value(arguments, ["cmd", "command", "parsedCmd"])
  end

  defp command_from_function_call_arguments(_arguments), do: nil

  defp command_candidate(payload) do
    map_path(payload, ["params", "msg", "command"]) ||
      map_path(payload, ["params", "command"]) ||
      map_path(payload, ["params", "parsedCmd"]) ||
      map_path(payload, ["params", "cmd"]) ||
      map_path(payload, ["params", "item", "command"]) ||
      map_path(payload, ["params", "item", "parsedCmd"])
  end

  defp normalize_command(%{} = command) do
    binary_command = map_value(command, ["parsedCmd", "command", "cmd"])
    args = map_value(command, ["args", "argv"])

    cond do
      is_binary(binary_command) and is_list(args) -> normalize_command([binary_command | args])
      is_binary(binary_command) -> normalize_command(binary_command)
      is_list(args) -> normalize_command(args)
      true -> nil
    end
  end

  defp normalize_command(command) when is_binary(command) do
    command
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      command
      |> Enum.join(" ")
      |> normalize_command()
    end
  end

  defp normalize_command(_command), do: nil

  defp map_path(value, []), do: value

  defp map_path(%{} = map, [key | rest]) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> map_path(value, rest)
      :error -> nil
    end
  end

  defp map_path(_value, _path), do: nil

  defp map_value(%{} = map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_value(_map, _keys), do: nil

  defp turn_token_budget_violation(_payload, max_tokens)
       when not is_integer(max_tokens) or max_tokens <= 0,
       do: :ok

  defp turn_token_budget_violation(payload, max_tokens) when is_map(payload) do
    case total_tokens_from_payload(payload) do
      total_tokens when is_integer(total_tokens) and total_tokens > max_tokens ->
        {:error, total_tokens, max_tokens}

      _ ->
        :ok
    end
  end

  defp turn_token_budget_violation(_payload, _max_tokens), do: :ok

  defp total_tokens_from_payload(payload) when is_map(payload) do
    [
      ["params", "msg", "payload", "info", "total_token_usage"],
      ["params", "msg", "info", "total_token_usage"],
      ["params", "tokenUsage", "total"],
      ["tokenUsage", "total"],
      ["usage"]
    ]
    |> Enum.find_value(fn path ->
      payload
      |> map_path(path)
      |> total_tokens_from_usage()
    end)
  end

  defp total_tokens_from_payload(_payload), do: nil

  defp total_tokens_from_usage(%{} = usage) do
    explicit_total =
      usage
      |> map_value(["total_tokens", "totalTokens", "total", :total_tokens, :totalTokens, :total])
      |> integer_token_value()

    input_tokens =
      usage
      |> map_value(["input_tokens", "inputTokens", "prompt_tokens", :input_tokens, :inputTokens, :prompt_tokens])
      |> integer_token_value()

    output_tokens =
      usage
      |> map_value(["output_tokens", "outputTokens", "completion_tokens", :output_tokens, :outputTokens, :completion_tokens])
      |> integer_token_value()

    cond do
      is_integer(explicit_total) ->
        explicit_total

      is_integer(input_tokens) and is_integer(output_tokens) ->
        input_tokens + output_tokens

      true ->
        nil
    end
  end

  defp total_tokens_from_usage(_usage), do: nil

  defp integer_token_value(value) when is_integer(value), do: value

  defp integer_token_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_token_value(_value), do: nil

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_command?(auto_approve_requests, payload)
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_command?(auto_approve_requests, payload)
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve?(auto_approve_requests, :file_change)
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve?(auto_approve_requests, :file_change)
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve?(auto_approve_requests, :user_input)
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp auto_approvals("never", safe_command_patterns),
    do: %{all: true, file_change: true, safe_command_patterns: safe_command_patterns}

  defp auto_approvals(%{"granular" => %{"rules" => false}}, safe_command_patterns),
    do: %{all: false, file_change: true, safe_command_patterns: safe_command_patterns}

  defp auto_approvals(%{granular: %{rules: false}}, safe_command_patterns),
    do: %{all: false, file_change: true, safe_command_patterns: safe_command_patterns}

  defp auto_approvals(_approval_policy, safe_command_patterns),
    do: %{all: false, file_change: false, safe_command_patterns: safe_command_patterns}

  defp auto_approve?(%{all: true}, _kind), do: true
  defp auto_approve?(%{file_change: true}, :file_change), do: true
  defp auto_approve?(_auto_approvals, _kind), do: false

  defp auto_approve_command?(auto_approve_requests, payload) do
    auto_approve?(auto_approve_requests, :command) or
      safe_command_approval?(payload, Map.get(auto_approve_requests, :safe_command_patterns, []))
  end

  defp safe_command_approval?(payload, patterns) when is_list(patterns) do
    case command_text(payload) do
      command when is_binary(command) ->
        not is_nil(first_matching_command_pattern(command, patterns))

      _ ->
        false
    end
  end

  defp safe_command_approval?(_payload, _patterns), do: false

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    cond do
      tool_request_user_input_approval_prompt?(params) ->
        :approval_required

      tool_request_user_input_prompt?(params) ->
        :input_required

      true ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp tool_request_user_input_approval_prompt?(params) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, _answers, _decision} -> true
      :error -> false
    end
  end

  defp tool_request_user_input_prompt?(%{"questions" => questions}) when is_list(questions) do
    Enum.any?(questions, fn
      %{"id" => question_id} when is_binary(question_id) -> String.trim(question_id) != ""
      _ -> false
    end)
  end

  defp tool_request_user_input_prompt?(_params), do: false

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    (String.starts_with?(method, "turn/") && input_required_method?(method, payload)) or
      mcp_elicitation_request?(method)
  end

  defp needs_input?(_method, _payload), do: false

  defp mcp_elicitation_request?(method) when is_binary(method) do
    method
    |> String.downcase()
    |> String.contains?("elicitation/request")
  end

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
