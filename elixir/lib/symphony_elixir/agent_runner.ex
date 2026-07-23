defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer

  alias SymphonyElixir.{
    Config,
    DispatchPreflight,
    HandoffCertificate,
    HandoffController,
    Linear.Issue,
    PromptBuilder,
    ReviewMonitor,
    RuntimeContract,
    RuntimeRequest,
    ScopeAccess,
    Tracker,
    ValidationController,
    Workspace
  }

  @delivery_event_path ".orocsy/delivery/events/events.jsonl"
  @review_classification_path ".orocsy/delivery/state/review-feedback-classified.json"
  @strict_review_rework_policy_violation_recoveries 1
  @runtime_controller_handoff_policy_pattern "playwright_browser_correction_requires_runtime_controller_handoff"

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host =
      issue
      |> selected_worker_host_for_issue(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            case reconcile_pending_runtime_transition(workspace, issue, opts) do
              {:stop, _transition_result} ->
                :ok

              {:continue, _transition_result} ->
                with {:ok, _preflight} <- maybe_prepare_dispatch_preflight(workspace, issue, worker_host) do
                  run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
                end

              {:error, _reason} = error ->
                error
            end
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_prepare_dispatch_preflight(_workspace, _issue, worker_host) when is_binary(worker_host),
    do: {:ok, %{"mode" => "remote_worker_preflight_skipped"}}

  defp maybe_prepare_dispatch_preflight(workspace, issue, nil) do
    DispatchPreflight.prepare(workspace, issue)
  end

  defp remote_worker_review_feedback?(%Issue{} = issue) do
    monitor = Config.settings!().review_monitor

    cond do
      not monitor.enabled ->
        {:ok, false}

      true ->
        case ReviewMonitor.inspect_issue(issue, monitor) do
          {:ok, %{feedback: feedback}} when is_list(feedback) -> {:ok, feedback != []}
          {:ok, _inspection} -> {:ok, false}
          {:error, _reason} -> {:ok, false}
        end
    end
  end

  defp remote_worker_review_feedback?(_issue), do: {:ok, false}

  if Mix.env() == :test do
    def remote_worker_review_feedback_for_test(issue), do: remote_worker_review_feedback?(issue)
    def selected_worker_host_for_test(issue, preferred_host), do: selected_worker_host_for_issue(issue, preferred_host, Config.settings!().worker.ssh_hosts)
    def pushed_handoff_stop_for_test(workspace, issue), do: pushed_handoff_stop?(workspace, issue)
    def review_classification_handoff_stop_for_test(workspace), do: review_classification_handoff_stop?(workspace)
    def policy_violation_recovery_budget_for_test(workspace), do: policy_violation_recovery_budget(workspace)

    def current_issue_for_runtime_transition_for_test(workspace, issue, fetcher),
      do: current_issue_for_runtime_transition(workspace, issue, fetcher)

    def reconcile_pending_runtime_transition_for_test(workspace, issue, opts),
      do: reconcile_pending_runtime_transition(workspace, issue, opts)

    def policy_violation_recovery_action_for_test(
          workspace,
          issue,
          command,
          pattern,
          recovery_count,
          max_policy_recoveries,
          worker_host \\ nil
        ),
        do:
          policy_violation_recovery_action(
            workspace,
            issue,
            command,
            pattern,
            recovery_count,
            max_policy_recoveries,
            worker_host
          )
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  @max_policy_violation_recoveries 2

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    run_codex_turns_with_policy_recovery(workspace, issue, codex_update_recipient, opts, worker_host, 0)
  end

  # A denied command used to kill the whole run and park the issue behind a
  # human-resolved correction, so the worker never learned which command was
  # denied and every redispatch replayed the same violation. Recover in-run
  # instead: restart the worker with an explicit policy-violation prelude naming
  # the denied command, bounded by @max_policy_violation_recoveries before the
  # existing parking path takes over.
  defp run_codex_turns_with_policy_recovery(workspace, issue, codex_update_recipient, opts, worker_host, recovery_count) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    max_policy_recoveries = policy_violation_recovery_budget(workspace)

    result =
      with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
        try do
          do_run_codex_turns(
            session,
            workspace,
            issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            1,
            max_turns,
            worker_host
          )
        after
          AppServer.stop_session(session)
          consume_policy_violation_patches_after_turn(workspace, opts)
        end
      end

    case result do
      {:error, {:forbidden_command, command, pattern}} ->
        case policy_violation_recovery_action(
               workspace,
               issue,
               command,
               pattern,
               recovery_count,
               max_policy_recoveries,
               worker_host
             ) do
          {:retry, attempt, scope_access} ->
            Logger.warning("Recovering denied-command policy violation for #{issue_context(issue)} attempt=#{attempt}/#{max_policy_recoveries} command=#{inspect(command)} pattern=#{inspect(pattern)}")

            record_policy_violation_event(workspace, issue, command, pattern, attempt, scope_access, worker_host)

            send_codex_update(codex_update_recipient, issue, %{
              event: :policy_violation_recovery,
              command: command,
              pattern: pattern,
              attempt: attempt,
              max_attempts: max_policy_recoveries,
              scope_access: scope_access,
              timestamp: DateTime.utc_now()
            })

            opts =
              Keyword.put(opts, :policy_violation, %{
                command: command,
                pattern: pattern,
                attempt: attempt,
                max_attempts: max_policy_recoveries,
                scope_access: scope_access
              })

            run_codex_turns_with_policy_recovery(
              workspace,
              issue,
              codex_update_recipient,
              opts,
              worker_host,
              attempt
            )

          {:parked, scope_access} ->
            record_policy_violation_event(
              workspace,
              issue,
              command,
              pattern,
              recovery_count + 1,
              scope_access,
              worker_host
            )

            :ok

          :stop ->
            result
        end

      other ->
        other
    end
  end

  defp policy_violation_recovery_budget(workspace) do
    if strict_review_rework_implementation_child?(workspace) do
      @strict_review_rework_policy_violation_recoveries
    else
      @max_policy_violation_recoveries
    end
  end

  defp consume_policy_violation_patches_after_turn(workspace, opts) when is_binary(workspace) and is_list(opts) do
    if Keyword.has_key?(opts, :policy_violation) do
      DispatchPreflight.consume_turn_policy_patches(workspace)
    end
  rescue
    _error -> :ok
  end

  defp consume_policy_violation_patches_after_turn(_workspace, _opts), do: :ok

  defp strict_review_rework_implementation_child?(workspace) when is_binary(workspace) do
    with {:ok, %{"mode" => "review_rework"} = preflight} <- DispatchPreflight.read(workspace),
         ticket_type when is_binary(ticket_type) <- get_in(preflight, ["requirements", "ticket_type"]),
         true <- String.downcase(String.trim(ticket_type)) == "implementation" do
      true
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp strict_review_rework_implementation_child?(_workspace), do: false

  defp policy_violation_recovery_action(_workspace, _issue, _command, _pattern, recovery_count, max_policy_recoveries, _worker_host)
       when recovery_count >= max_policy_recoveries,
       do: :stop

  defp policy_violation_recovery_action(
         _workspace,
         _issue,
         _command,
         @runtime_controller_handoff_policy_pattern,
         _recovery_count,
         _max_policy_recoveries,
         _worker_host
       ),
       do: :stop

  defp policy_violation_recovery_action(_workspace, _issue, _command, _pattern, recovery_count, _max_policy_recoveries, worker_host)
       when is_binary(worker_host),
       do: {:retry, recovery_count + 1, nil}

  defp policy_violation_recovery_action(workspace, issue, command, pattern, recovery_count, _max_policy_recoveries, nil)
       when is_binary(workspace) and is_binary(command) do
    attempt = recovery_count + 1
    policy = policy_violation_policy(workspace)

    case ScopeAccess.classify_command(command, policy) do
      %{} = request ->
        case ScopeAccess.Controller.decide(request, policy, workspace) do
          {:allow_once, patch} ->
            case ScopeAccess.Controller.write_policy_patch(workspace, patch) do
              {:ok, written_patch} ->
                {:retry, attempt, scope_access_with_decision(request, written_patch)}

              {:error, reason} ->
                Logger.warning("Failed to write scope access policy patch for #{issue_context(issue)} reason=#{inspect(reason)}")
                {:retry, attempt, scope_access_with_decision(request, ScopeAccess.decision_for(request) || %{})}
            end

          {decision, correction_attrs} when decision in [:block, :escalate] ->
            correction_attrs = put_scope_access_retry_fingerprint(correction_attrs, issue, request, policy)
            scope_access = scope_access_with_decision(request, correction_attrs)

            case Workspace.create_correction_in_workspace(workspace, issue, correction_attrs) do
              {:ok, _correction} ->
                Logger.warning("Parking #{issue_context(issue)} after denied #{request["operation"] || "unknown"} scope access command=#{inspect(command)} pattern=#{inspect(pattern)}")
                {:parked, scope_access}

              {:error, reason} ->
                Logger.warning("Failed to create scope access correction for #{issue_context(issue)} reason=#{inspect(reason)}")
                {:retry, attempt, scope_access}
            end
        end

      _ ->
        {:retry, attempt, nil}
    end
  rescue
    error ->
      Logger.warning("Failed to decide scope access recovery for #{issue_context(issue)} error=#{Exception.message(error)}")
      {:retry, recovery_count + 1, nil}
  end

  defp policy_violation_recovery_action(_workspace, _issue, _command, _pattern, recovery_count, _max_policy_recoveries, _worker_host) do
    {:retry, recovery_count + 1, nil}
  end

  defp policy_violation_policy(workspace) when is_binary(workspace) do
    case DispatchPreflight.read(workspace) do
      {:ok, preflight} when is_map(preflight) -> preflight
      _ -> %{}
    end
  rescue
    _error -> %{}
  end

  defp policy_violation_policy(_workspace), do: %{}

  defp put_scope_access_retry_fingerprint(correction_attrs, %Issue{} = issue, %{} = request, %{} = policy)
       when is_map(correction_attrs) do
    fingerprint =
      %{
        "issue" => issue.identifier,
        "issue_id" => issue.id,
        "source" => correction_source(correction_attrs),
        "head_sha" => policy_head_sha(policy),
        "policy_hash" => policy_hash(policy),
        "operation" => request["operation"],
        "paths" => request["paths"],
        "command_fingerprint" => request["command_fingerprint"]
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
      |> Map.new()

    if fingerprint == %{} do
      correction_attrs
    else
      guard =
        correction_attrs
        |> Map.get(:guard, %{})
        |> stringify_scope_access_decision()
        |> Map.put("retry_fingerprint", fingerprint)

      Map.put(correction_attrs, :guard, guard)
    end
  end

  defp put_scope_access_retry_fingerprint(correction_attrs, _issue, _request, _policy), do: correction_attrs

  defp correction_source(%{source: source}) when is_binary(source), do: source
  defp correction_source(%{"source" => source}) when is_binary(source), do: source
  defp correction_source(_correction_attrs), do: "symphony.runtime.scope-access"

  defp policy_head_sha(policy) when is_map(policy) do
    Map.get(policy, "head_sha") ||
      get_in(policy, ["review", "head_sha"]) ||
      get_in(policy, ["review", "head"])
  end

  defp policy_head_sha(_policy), do: nil

  defp policy_hash(policy) when is_map(policy) do
    Map.get(policy, "policy_hash") ||
      get_in(policy, ["requirements", "scope_bundle", "policy_hash"]) ||
      get_in(policy, ["scope_bundle", "policy_hash"])
  end

  defp policy_hash(_policy), do: nil

  defp scope_access_with_decision(%{} = request, %{} = decision) do
    decision_payload =
      decision
      |> stringify_scope_access_decision()
      |> Map.take([
        "decision",
        "decision_class",
        "reason_class",
        "status",
        "requires_policy_patch",
        "patch_id",
        "path",
        "target"
      ])

    Map.merge(request, decision_payload)
  end

  defp stringify_scope_access_decision(decision) when is_map(decision) do
    Map.new(decision, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp record_policy_violation_event(workspace, %Issue{identifier: identifier}, command, pattern, attempt, scope_access, nil)
       when is_binary(workspace) do
    event =
      %{
        "event" => "runtime.command-policy-violation",
        "status" => "warn",
        "tool" => "command-guard",
        "ts" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "issue" => identifier,
        "command" => command,
        "pattern" => pattern,
        "recovery_attempt" => attempt,
        "source" => "symphony.runtime.command-guard",
        "schema_version" => 1
      }
      |> put_if_present("scope_access", scope_access)

    path = Path.join(workspace, @delivery_event_path)
    File.write!(path, Jason.encode!(event) <> "\n", [:append])
    :ok
  rescue
    error ->
      Logger.warning("Failed to record command policy violation event: #{Exception.message(error)}")
      :ok
  end

  defp record_policy_violation_event(_workspace, _issue, _command, _pattern, _attempt, _scope_access, _worker_host), do: :ok

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns, worker_host) do
    prompt = build_turn_prompt(issue, opts, workspace, turn_number, max_turns)
    checkpoint_present_at_turn_start = fresh_implementation_checkpoint_present?(workspace)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue),
             turn_number: turn_number
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case process_runtime_transition_requests(workspace, issue, issue_state_fetcher) do
        {:error, _reason} = error ->
          error

        transition_result ->
          cond do
            runtime_transition_stop?(transition_result) ->
              Logger.info("Stopping agent run for #{issue_context(issue)} after runtime transition certification; returning control to orchestrator")
              :ok

            fresh_checkpoint_stop_completed?(turn_session, workspace, checkpoint_present_at_turn_start) ->
              Logger.info("Stopping agent run for #{issue_context(issue)} after fresh implementation checkpoint; returning control to orchestrator")
              :ok

            true ->
              next_action = post_turn_next_action(workspace, issue, issue_state_fetcher, worker_host)

              case next_action do
                {:continue, refreshed_issue} when turn_number < max_turns ->
                  Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

                  do_run_codex_turns(
                    app_session,
                    workspace,
                    refreshed_issue,
                    codex_update_recipient,
                    opts,
                    issue_state_fetcher,
                    turn_number + 1,
                    max_turns,
                    worker_host
                  )

                {:continue, refreshed_issue} ->
                  Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

                  :ok

                {:done, _refreshed_issue} ->
                  :ok

                {:error, reason} ->
                  {:error, reason}
              end
          end
      end
    end
  end

  defp fresh_checkpoint_stop_completed?(turn_session, workspace, false) when is_binary(workspace) do
    turn_session[:result] == :fresh_checkpoint_stop or fresh_implementation_checkpoint_present?(workspace)
  end

  defp fresh_checkpoint_stop_completed?(turn_session, _workspace, _checkpoint_present_at_turn_start) do
    turn_session[:result] == :fresh_checkpoint_stop
  end

  defp post_turn_next_action(workspace, issue, issue_state_fetcher, worker_host) do
    cond do
      Workspace.blocking_correction_in_workspace?(workspace, worker_host) ->
        Logger.info("Stopping agent run for #{issue_context(issue)} after open Orocsy blocking correction; returning control to orchestrator")
        {:done, issue}

      pushed_handoff_stop?(workspace, issue) ->
        Logger.info("Stopping agent run for #{issue_context(issue)} after pushed validated handoff; returning control to orchestrator")
        {:done, issue}

      review_classification_handoff_stop?(workspace) ->
        Logger.info("Stopping agent run for #{issue_context(issue)} after no-code review classification handoff; returning control to orchestrator")
        {:done, issue}

      true ->
        continue_with_issue?(issue, issue_state_fetcher)
    end
  end

  defp pushed_handoff_stop?(workspace, %Issue{} = issue) do
    case DispatchPreflight.read(workspace) do
      {:ok, %{"mode" => mode}} when mode in ["review_rework", "integration_check", "handoff_recovery"] ->
        match?({:ok, _certificate}, HandoffCertificate.current(issue, workspace))

      _ ->
        false
    end
  end

  defp pushed_handoff_stop?(_workspace, _issue), do: false

  defp review_classification_handoff_stop?(workspace) when is_binary(workspace) do
    with {:ok, %{"mode" => "review_rework"}} <- DispatchPreflight.read(workspace),
         {:ok, classification} <- read_review_classification_handoff(workspace),
         true <- clean_worktree?(workspace),
         {:ok, head_sha} <- current_head_sha(workspace),
         true <- classification_head_matches?(classification, head_sha) do
      no_code_review_classification?(classification) and resolved_review_classification?(classification)
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp review_classification_handoff_stop?(_workspace), do: false

  defp read_review_classification_handoff(workspace) when is_binary(workspace) do
    path = Path.join(workspace, @review_classification_path)

    cond do
      File.regular?(path) ->
        path
        |> File.read!()
        |> Jason.decode()

      true ->
        {:error, :missing_review_classification_handoff}
    end
  rescue
    error -> {:error, {:review_classification_handoff_read_failed, Exception.message(error)}}
  end

  defp no_code_review_classification?(classification) when is_map(classification) do
    code_edit =
      (classification["code_edit"] || "")
      |> to_string()
      |> String.downcase()

    code_edit in ["none", "no_code_change", "not_run_no_code_change"]
  end

  defp no_code_review_classification?(_classification), do: false

  defp resolved_review_classification?(%{"classification" => classification} = payload)
       when is_binary(classification) do
    normalized = normalize_review_classification(classification)

    normalized in ["already_resolved_in_current_head", "stale_resolved", "resolved"] and
      payload
      |> Map.get("feedback", [])
      |> feedback_classification_resolved?()
  end

  defp resolved_review_classification?(_payload), do: false

  defp feedback_classification_resolved?([]), do: true

  defp feedback_classification_resolved?(feedback) when is_list(feedback) do
    Enum.all?(feedback, fn
      %{"classification" => classification} ->
        normalize_review_classification(classification) in [
          "stale_resolved",
          "already_resolved",
          "already_resolved_in_current_head",
          "resolved",
          "outdated"
        ]

      _ ->
        false
    end)
  end

  defp feedback_classification_resolved?(_feedback), do: false

  defp current_head_sha(workspace) when is_binary(workspace) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        case String.trim(output) do
          "" -> {:error, :missing_head_sha}
          head_sha -> {:ok, head_sha}
        end

      {output, exit_code} ->
        {:error, {:git_head_failed, exit_code, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_head_exception, Exception.message(error)}}
  end

  defp classification_head_matches?(classification, head_sha) when is_map(classification) and is_binary(head_sha) do
    classification_head = classification["head"] || classification["head_sha"]
    is_binary(classification_head) and String.trim(classification_head) == head_sha
  end

  defp classification_head_matches?(_classification, _head_sha), do: false

  defp clean_worktree?(workspace) when is_binary(workspace) do
    case System.cmd("git", ["status", "--porcelain=v1"], cd: workspace, stderr_to_stdout: true) do
      {status, 0} -> String.trim(status) == ""
      {_output, _exit_code} -> false
    end
  rescue
    _error -> false
  end

  defp clean_worktree?(_workspace), do: false

  defp normalize_review_classification(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp fresh_implementation_checkpoint_present?(workspace) when is_binary(workspace) do
    with {:ok, %{"mode" => "fresh_implementation"} = preflight} <- DispatchPreflight.read(workspace),
         false <- structured_runtime_contract?(preflight) do
      technical_miu_trace_event?(workspace) and meaningful_git_progress?(workspace)
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp fresh_implementation_checkpoint_present?(_workspace), do: false

  defp structured_runtime_contract?(preflight) when is_map(preflight) do
    get_in(preflight, ["requirements", "runtime_contract_status"]) == "structured"
  end

  defp structured_runtime_contract?(_preflight), do: false

  defp process_runtime_transition_requests(workspace, %Issue{} = issue, issue_state_fetcher) do
    with {:ok, current_issue} <- current_issue_for_runtime_transition(workspace, issue, issue_state_fetcher) do
      validation_result = ValidationController.process_requests(current_issue, workspace)
      handoff_result = HandoffController.process_requests(current_issue, workspace)

      maybe_record_controller_block(workspace, current_issue, "validation", validation_result)
      maybe_record_controller_block(workspace, current_issue, "handoff", handoff_result)

      Logger.info("Processed runtime transition requests for #{issue_context(current_issue)} validation=#{inspect(validation_result)} handoff=#{inspect(handoff_result)}")

      {validation_result, handoff_result}
    end
  rescue
    error ->
      Logger.warning("Failed to process runtime transition requests for #{issue_context(issue)} error=#{Exception.message(error)}")

      {:error, {:runtime_transition_failed, Exception.message(error)}}
  end

  defp reconcile_pending_runtime_transition(workspace, %Issue{} = issue, opts)
       when is_binary(workspace) and is_list(opts) do
    if RuntimeRequest.pending?(workspace, ["miu.completion_requested", "handoff.requested"]) do
      issue_state_fetcher =
        Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

      transition_processor =
        Keyword.get(opts, :runtime_transition_processor, &process_runtime_transition_requests/3)

      case transition_processor.(workspace, issue, issue_state_fetcher) do
        {:error, _reason} = error ->
          error

        transition_result ->
          if runtime_transition_stop?(transition_result),
            do: {:stop, transition_result},
            else: {:continue, transition_result}
      end
    else
      {:continue, :none}
    end
  rescue
    error -> {:error, {:runtime_transition_reconciliation_failed, Exception.message(error)}}
  end

  defp current_issue_for_runtime_transition(workspace, %Issue{} = issue, issue_state_fetcher) do
    if RuntimeRequest.pending?(workspace, ["miu.completion_requested", "handoff.requested"]) do
      refresh_runtime_transition_issue(issue, issue_state_fetcher)
    else
      {:ok, issue}
    end
  end

  defp refresh_runtime_transition_issue(%Issue{id: issue_id}, issue_state_fetcher)
       when is_binary(issue_id) and is_function(issue_state_fetcher, 1) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = current_issue | _]} ->
        if active_issue_state?(current_issue.state) do
          {:ok, current_issue}
        else
          {:error, {:runtime_transition_issue_inactive, current_issue.state}}
        end

      {:ok, []} ->
        {:error, :runtime_transition_issue_unavailable}

      {:error, reason} ->
        {:error, {:runtime_transition_issue_refresh_failed, reason}}
    end
  end

  defp refresh_runtime_transition_issue(_issue, _issue_state_fetcher),
    do: {:error, :runtime_transition_issue_unavailable}

  defp runtime_transition_stop?({{:ok, certificate}, _handoff_result}) when is_map(certificate), do: true
  defp runtime_transition_stop?({_validation_result, {:ok, certificate}}) when is_map(certificate), do: true
  defp runtime_transition_stop?({{:error, _reason}, _handoff_result}), do: true
  defp runtime_transition_stop?({_validation_result, {:error, _reason}}), do: true
  defp runtime_transition_stop?({{:blocked, _reason}, _handoff_result}), do: true
  defp runtime_transition_stop?({_validation_result, {:blocked, _reason}}), do: true
  defp runtime_transition_stop?(_result), do: false

  defp maybe_record_controller_block(workspace, issue, controller, {:blocked, reason}) do
    _ =
      Workspace.create_correction_in_workspace(workspace, issue, %{
        source: "symphony.runtime.#{controller}-controller",
        source_status: "blocked",
        summary: "#{String.capitalize(controller)} controller requires operator action",
        findings: [inspect(reason)],
        required_corrections: [
          "Inspect the persisted controller evidence and choose a contract revision, explicit operator reset, or cancellation."
        ],
        next_action: "escalate",
        guard: %{"controller" => controller, "reason" => inspect(reason)}
      })

    :ok
  end

  defp maybe_record_controller_block(_workspace, _issue, _controller, _result), do: :ok

  defp technical_miu_trace_event?(workspace) when is_binary(workspace) do
    workspace
    |> Path.join(@delivery_event_path)
    |> File.stream!()
    |> Enum.any?(fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, %{"event" => "tool.finished", "status" => "passed", "tool" => "technical-miu-trace"}} -> true
        _ -> false
      end
    end)
  rescue
    _error -> false
  end

  defp technical_miu_trace_event?(_workspace), do: false

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

  defp build_turn_prompt(issue, opts, workspace, 1, _max_turns) do
    PromptBuilder.build_prompt(issue, Keyword.put(opts, :workspace, workspace))
  end

  defp build_turn_prompt(_issue, _opts, workspace, turn_number, max_turns) do
    checkpoint = PromptBuilder.workspace_recovery_checkpoint(workspace)

    guidance =
      """
      Continuation guidance:

      - The previous Codex turn completed normally, but the Linear issue is still in an active state.
      - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
      - Resume from the current workspace and workpad state instead of restarting from scratch.
      - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
      - If the workspace is dirty or ahead and recent validation/gate events passed, treat that as a dirty handoff checkpoint. Run only `git status --short --branch` and a focused `git diff -- <dirty-file>` read before handoff; do not run `git log` or `git diff --stat` — the runtime denies them and the checkpoint context above already lists commit/diffstat state. Do not rerun the same validation command before committing when the checkpoint already lists passed `gate.post-miu`/`tool.finished` evidence for the dirty files and the diff has not changed since that evidence; use the recorded evidence and proceed to commit, push, and review request. Rerun focused validation only when the evidence is missing, stale, or the focused diff is incomplete/invalid.
      - If no unmerged files remain and a dirty diff already exists, validation comes before more code changes. Only edit again when that focused validation fails and names the exact broken path or assertion.
      - After focused validation passes, immediately stage, commit, push the existing branch, and request/update PR review.
      - If the previous turn already produced validated local commits and only an external handoff step failed, such as git push, PR review comment, or Linear update, do not redo product code or broad implementation checks. Retry the pending handoff step once with bounded commands; if the network or provider is still unavailable, record an Orocsy correction/blocker with next action retry and stop.
      - Do not move review-rework issues to Done/Closed/terminal states from a continuation turn; a fresh review request is not the same thing as a clean review result.
      - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
      """

    if checkpoint == "" do
      guidance
    else
      checkpoint <> "\n\n" <> guidance
    end
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp selected_worker_host_for_issue(issue, preferred_host, configured_hosts) do
    worker_host = selected_worker_host(preferred_host, configured_hosts)

    cond do
      is_binary(worker_host) and structured_runtime_contract_issue?(issue) ->
        Logger.info("Routing #{issue_context(issue)} to local worker because structured runtime contracts require local controller certification")
        nil

      is_binary(worker_host) and review_feedback_requires_local_worker?(issue) ->
        Logger.info("Routing #{issue_context(issue)} to local worker because current review feedback requires dispatch preflight")
        nil

      true ->
        worker_host
    end
  end

  defp structured_runtime_contract_issue?(%Issue{description: description}) when is_binary(description) do
    match?({:ok, _compiled}, RuntimeContract.compile(description))
  end

  defp structured_runtime_contract_issue?(_issue), do: false

  defp review_feedback_requires_local_worker?(issue) do
    case remote_worker_review_feedback?(issue) do
      {:ok, true} -> true
      {:ok, false} -> false
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
