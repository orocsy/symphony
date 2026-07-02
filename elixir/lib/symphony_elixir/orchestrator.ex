defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, DispatchPreflight, PromptBuilder, RescueSupervisor, ReviewMonitor, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @review_rework_first_event_max_tokens 45_000
  @integration_check_first_event_max_tokens 2_000
  @integration_check_no_progress_min_tokens 5_000
  @recent_codex_update_limit 8
  @review_classification_path ".orocsy/delivery/state/review-feedback-classified.json"
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @durable_progress_event_names [
    "tool.finished",
    "gate.post-miu",
    "gate.required-evidence",
    "gate.declared-scope",
    "validation.blocker",
    "eval.recorded",
    "handoff.completed"
  ]
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    run_terminal_workspace_cleanup()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state =
          case reason do
            :normal ->
              cond do
                workflow_blocked_by_non_dispatchable_correction?(running_entry) ->
                  Logger.warning("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; open Orocsy correction blocks continuation until resolved")

                  state
                  |> complete_issue(issue_id)
                  |> release_issue_claim(issue_id)

                normal_completion_handoff_stop?(running_entry) ->
                  Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; pushed handoff checkpoint blocks continuation until review/Linear state changes")

                  state
                  |> complete_issue(issue_id)
                  |> release_issue_claim(issue_id)

                true ->
                  case normal_completion_no_progress_failure(running_entry) do
                    {:block, no_progress_reason, failure} ->
                      Logger.warning("Agent task completed for issue_id=#{issue_id} session_id=#{session_id} with no durable progress above token threshold; parking for workflow correction")

                      park_failed_issue(state, issue_id, running_entry, no_progress_reason, failure)

                    :ok ->
                      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

                      state
                      |> complete_issue(issue_id)
                      |> schedule_issue_retry(issue_id, 1, %{
                        identifier: running_entry.identifier,
                        delay_type: :continuation,
                        worker_host: Map.get(running_entry, :worker_host),
                        workspace_path: Map.get(running_entry, :workspace_path)
                      })
                  end
              end

            _ ->
              cond do
                provider_usage_limit_failure?(reason) ->
                  Logger.warning(
                    "Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)} after Codex provider usage limit; parking until worker quota is available"
                  )

                  state
                  |> handle_agent_failure(issue_id, running_entry, reason)

                agent_failure_must_park_before_open_correction?(reason, running_entry) ->
                  Logger.warning(
                    "Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)} with a blocking runtime failure; parking despite any retryable product correction"
                  )

                  state
                  |> handle_agent_failure(issue_id, running_entry, reason)

                workflow_blocked_by_open_correction?(running_entry) ->
                  Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; open Orocsy correction blocks retry until resolved")

                  state
                  |> complete_issue(issue_id)
                  |> release_issue_claim(issue_id)

                normal_completion_handoff_stop?(running_entry) ->
                  Logger.warning(
                    "Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)} after pushed handoff checkpoint; blocking retry until review/Linear state changes"
                  )

                  state
                  |> complete_issue(issue_id)
                  |> release_issue_claim(issue_id)

                true ->
                  Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")
                  handle_agent_failure(state, issue_id, running_entry, reason)
              end
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         :ok <- ReviewMonitor.run_once(),
         {:ok, rescued_issue_ids} <- RescueSupervisor.run_once(issues),
         true <- available_slots(state) > 0 do
      issues
      |> Enum.reject(&MapSet.member?(rescued_issue_ids, &1.id))
      |> choose_issues(state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state =
      state
      |> reconcile_no_durable_progress_running_issues()
      |> reconcile_stalled_running_issues()

    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  if Code.ensure_loaded?(Mix) and Mix.env() == :test do
    @doc false
    def reconcile_no_durable_progress_for_test(%State{} = state) do
      reconcile_no_durable_progress_running_issues(state)
    end

    @doc false
    def rescue_open_corrections_for_test(issues, %State{} = state) when is_list(issues) do
      _ = RescueSupervisor.run_once(issues)
      state
    end

    @doc false
    def complete_pushed_handoff_for_test(%Issue{} = issue) do
      maybe_complete_pushed_review_handoff(issue)
    end

    @doc false
    def handle_orchestration_review_pending_for_test(%Issue{} = issue) do
      maybe_handle_orchestration_review_pending(issue)
    end

    @doc false
    def complete_review_classification_handoff_for_test(%Issue{} = issue) do
      maybe_complete_review_classification_handoff(issue)
    end
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp reconcile_no_durable_progress_running_issues(%State{} = state) do
    codex_config = Config.settings!().codex
    timeout_ms = codex_config.durable_progress_timeout_ms
    first_event_max_tokens = codex_config.durable_progress_first_event_max_tokens

    cond do
      timeout_ms <= 0 or codex_config.durable_progress_min_tokens <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          park_issue_without_durable_progress(
            state_acc,
            issue_id,
            running_entry,
            now,
            timeout_ms,
            codex_config.durable_progress_min_tokens,
            first_event_max_tokens
          )
        end)
    end
  end

  defp park_issue_without_durable_progress(
         state,
         issue_id,
         running_entry,
         now,
         timeout_ms,
         min_tokens,
         first_event_max_tokens
       ) do
    elapsed_ms = runtime_elapsed_ms(running_entry, now)
    total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    min_tokens = effective_no_durable_progress_min_tokens(running_entry, min_tokens)
    first_event_max_tokens = effective_first_event_max_tokens(running_entry, first_event_max_tokens)
    first_event_progress_tokens = first_event_progress_tokens(running_entry, total_tokens)
    durable_progress_guard_tokens = durable_progress_guard_tokens(running_entry, total_tokens)
    cached_input_tokens = Map.get(running_entry, :codex_cached_input_tokens, 0)

    quiet_ms = durable_progress_quiet_ms(running_entry, now)
    pushed_handoff_wait_checkpoint? = pushed_handoff_wait_checkpoint?(running_entry)

    no_first_event? =
      not substantive_first_progress_observed?(running_entry) and
        not handoff_recovery_progress_observed?(running_entry) and
        not pushed_handoff_wait_checkpoint?

    first_event_budget_exceeded? =
      is_integer(first_event_max_tokens) and first_event_max_tokens > 0 and
        first_event_progress_tokens >= first_event_max_tokens and no_first_event?

    review_request_wait_checkpoint? =
      first_event_budget_exceeded? and review_request_wait_checkpoint?(running_entry)

    validation_failure = validation_failure_for_guard(running_entry)

    validation_blocker_guard? =
      validation_failure != nil and
        (first_event_budget_exceeded? or
           (is_integer(elapsed_ms) and is_integer(quiet_ms) and quiet_ms > timeout_ms and
              durable_progress_guard_tokens >= min_tokens))

    cond do
      review_request_wait_checkpoint? ->
        identifier = Map.get(running_entry, :identifier, issue_id)
        session_id = running_entry_session_id(running_entry)

        Logger.info(
          "Issue reached pending Codex review checkpoint before first durable event guard: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms} codex_total_tokens=#{total_tokens} first_event_progress_tokens=#{first_event_progress_tokens}; stopping worker without correction"
        )

        state
        |> terminate_running_issue(issue_id, false)
        |> complete_issue(issue_id)

      validation_blocker_guard? ->
        identifier = Map.get(running_entry, :identifier, issue_id)
        session_id = running_entry_session_id(running_entry)

        Logger.warning(
          "Issue hit validation blocker before durable progress guard: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} command=#{inspect(validation_failure.command)} elapsed_ms=#{elapsed_ms} quiet_ms=#{quiet_ms} codex_total_tokens=#{total_tokens}"
        )

        failure =
          validation_blocker_failure(
            validation_failure,
            elapsed_ms,
            quiet_ms,
            total_tokens,
            durable_progress_guard_tokens,
            cached_input_tokens,
            timeout_ms,
            min_tokens
          )

        reason =
          {:validation_failure_blocker, elapsed_ms, quiet_ms, durable_progress_guard_tokens, timeout_ms, min_tokens}

        park_running_issue(state, issue_id, running_entry, reason, failure)

      first_event_budget_exceeded? ->
        identifier = Map.get(running_entry, :identifier, issue_id)
        session_id = running_entry_session_id(running_entry)

        Logger.warning(
          "Issue exceeded first durable event token budget: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms} codex_total_tokens=#{total_tokens} first_event_progress_tokens=#{first_event_progress_tokens} first_event_max_tokens=#{first_event_max_tokens}; parking for workflow correction"
        )

        failure =
          missing_first_durable_event_failure(
            elapsed_ms,
            total_tokens,
            first_event_progress_tokens,
            first_event_max_tokens,
            Map.get(running_entry, :codex_cached_input_tokens, 0)
          )

        reason = {:missing_first_durable_event, elapsed_ms, first_event_progress_tokens, first_event_max_tokens}

        park_running_issue(state, issue_id, running_entry, reason, failure)

      is_integer(elapsed_ms) and is_integer(quiet_ms) and quiet_ms > timeout_ms and
          pushed_handoff_wait_checkpoint? ->
        identifier = Map.get(running_entry, :identifier, issue_id)
        session_id = running_entry_session_id(running_entry)

        Logger.info(
          "Issue reached pushed handoff review gate before no-durable-progress guard: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms} quiet_ms=#{quiet_ms}; stopping worker without correction"
        )

        state
        |> terminate_running_issue(issue_id, false)
        |> complete_issue(issue_id)

      is_integer(elapsed_ms) and is_integer(quiet_ms) and quiet_ms > timeout_ms and
          durable_progress_guard_tokens >= min_tokens ->
        identifier = Map.get(running_entry, :identifier, issue_id)
        session_id = running_entry_session_id(running_entry)

        Logger.warning(
          "Issue has no recent durable progress: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms} quiet_ms=#{quiet_ms} codex_total_tokens=#{total_tokens} durable_progress_guard_tokens=#{durable_progress_guard_tokens}; parking for workflow correction"
        )

        failure =
          elapsed_ms
          |> no_durable_progress_failure(
            quiet_ms,
            total_tokens,
            durable_progress_guard_tokens,
            cached_input_tokens,
            timeout_ms,
            min_tokens
          )
          |> maybe_recover_no_durable_progress_handoff(running_entry)

        reason =
          {:no_durable_progress, elapsed_ms, quiet_ms, durable_progress_guard_tokens, timeout_ms, min_tokens}

        park_running_issue(state, issue_id, running_entry, reason, failure)

      true ->
        state
    end
  end

  defp runtime_elapsed_ms(%{started_at: %DateTime{} = started_at}, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :millisecond))
  end

  defp runtime_elapsed_ms(_running_entry, _now), do: nil

  if Code.ensure_loaded?(Mix) and Mix.env() == :test do
    @doc false
    def durable_progress_quiet_ms_for_test(running_entry, now) do
      durable_progress_quiet_ms(running_entry, now)
    end

    @doc false
    def integrate_codex_update_for_test(running_entry, update) do
      integrate_codex_update(running_entry, update)
    end
  end

  defp durable_progress_quiet_ms(%{worker_host: worker_host}, _now)
       when is_binary(worker_host) and worker_host != "" do
    # Remote workspaces need a remote progress probe before they can be parked safely.
    nil
  end

  defp durable_progress_quiet_ms(
         %{workspace_path: workspace, started_at: %DateTime{} = started_at} = running_entry,
         %DateTime{} = now
       )
       when is_binary(workspace) do
    count_dispatch_preflight? = count_dispatch_preflight_progress?(%{workspace_path: workspace})

    observed_at =
      if File.dir?(workspace) do
        (runtime_validation_progress_times(running_entry) ++
           durable_progress_observed_times(running_entry, workspace, started_at, count_dispatch_preflight?))
        |> latest_datetime()
      end

    reference_at = observed_at || started_at
    max(0, DateTime.diff(now, reference_at, :millisecond))
  rescue
    error ->
      Logger.debug("Unable to inspect durable progress for workspace=#{workspace}: #{inspect(error)}")
      runtime_elapsed_ms(%{started_at: started_at}, now)
  end

  defp durable_progress_quiet_ms(_running_entry, _now), do: nil

  defp substantive_first_progress_observed?(%{workspace_path: workspace, started_at: %DateTime{} = started_at} = running_entry)
       when is_binary(workspace) do
    count_dispatch_preflight? = count_dispatch_preflight_progress?(%{workspace_path: workspace})

    File.dir?(workspace) and
      runtime_validation_progress_times(running_entry) ++
        substantive_first_progress_times(running_entry, workspace, started_at, count_dispatch_preflight?) != []
  rescue
    _error -> false
  end

  defp substantive_first_progress_observed?(_running_entry), do: false

  defp handoff_recovery_progress_observed?(%{workspace_path: workspace}) when is_binary(workspace) do
    local_handoff_recovery_workspace?(workspace)
  rescue
    _error -> false
  end

  defp handoff_recovery_progress_observed?(_running_entry), do: false

  defp local_handoff_recovery_workspace?(workspace) when is_binary(workspace) do
    meaningful_local_handoff_progress?(workspace) and
      case PromptBuilder.workspace_recovery_checkpoint(workspace) do
        "Dirty validated handoff checkpoint:" <> _ -> true
        "Local handoff recovery checkpoint:" <> _ -> true
        _ -> false
      end
  end

  defp meaningful_local_handoff_progress?(workspace) when is_binary(workspace) do
    meaningful_git_dirty_paths(workspace) != [] or
      not is_nil(git_ahead_commit_observed_at(workspace)) or
      not is_nil(git_upstream_progress_observed_at(workspace))
  rescue
    _error -> false
  end

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

  defp generated_runtime_path?(path) when is_binary(path) do
    String.starts_with?(path, [".orocsy/", ".codex/"])
  end

  defp generated_runtime_path?(_path), do: false

  defp durable_progress_observed_times(workspace, started_at, count_dispatch_preflight?) do
    review_classification_progress_times(workspace, started_at) ++
      git_durable_progress_times(workspace, started_at) ++
      event_durable_progress_times(workspace, started_at, count_dispatch_preflight?)
  end

  defp durable_progress_observed_times(running_entry, workspace, started_at, count_dispatch_preflight?) do
    if integration_check_running_entry?(running_entry) do
      integration_check_durable_progress_times(workspace, started_at, count_dispatch_preflight?)
    else
      durable_progress_observed_times(workspace, started_at, count_dispatch_preflight?)
    end
  end

  defp substantive_first_progress_times(running_entry, workspace, started_at, count_dispatch_preflight?) do
    if integration_check_running_entry?(running_entry) do
      integration_check_durable_progress_times(workspace, started_at, count_dispatch_preflight?)
    else
      review_classification_progress_times(workspace, started_at) ++
        event_durable_progress_times(workspace, started_at, count_dispatch_preflight?) ++
        git_substantive_progress_times(workspace, started_at)
    end
  end

  defp integration_check_durable_progress_times(workspace, started_at, count_dispatch_preflight?) do
    git_committed_or_upstream_progress_times(workspace, started_at) ++
      event_durable_progress_times(workspace, started_at, count_dispatch_preflight?)
  end

  defp git_durable_progress_times(workspace, started_at) do
    [
      git_dirty_observed_at(workspace),
      git_ahead_commit_observed_at(workspace),
      git_upstream_progress_observed_at(workspace),
      git_issue_branch_observed_at(workspace)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&datetime_at_or_after?(&1, started_at))
  end

  defp git_committed_or_upstream_progress_times(workspace, started_at) do
    [
      git_ahead_commit_observed_at(workspace),
      git_upstream_progress_observed_at(workspace)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&datetime_at_or_after?(&1, started_at))
  end

  defp git_substantive_progress_times(workspace, started_at) do
    [
      meaningful_git_dirty_observed_at(workspace),
      git_ahead_commit_observed_at(workspace),
      git_upstream_progress_observed_at(workspace)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&datetime_at_or_after?(&1, started_at))
  end

  defp runtime_validation_progress_times(%{
         started_at: %DateTime{} = started_at,
         last_validation_progress_at: %DateTime{} = progress_at
       }) do
    if datetime_at_or_after?(progress_at, started_at), do: [progress_at], else: []
  end

  defp runtime_validation_progress_times(_running_entry), do: []

  defp validation_failure_for_guard(%{started_at: %DateTime{} = started_at} = running_entry) do
    with %DateTime{} = failed_at <- Map.get(running_entry, :last_validation_failure_at),
         true <- datetime_at_or_after?(failed_at, started_at),
         false <- validation_failure_resolved_by_success?(running_entry, failed_at) do
      %{
        at: failed_at,
        command:
          Map.get(running_entry, :last_validation_failure_command) ||
            Map.get(running_entry, :last_validation_command) ||
            "unknown validation command",
        evidence: Map.get(running_entry, :last_validation_failure_evidence)
      }
    else
      _ -> nil
    end
  end

  defp validation_failure_for_guard(_running_entry), do: nil

  defp validation_failure_resolved_by_success?(running_entry, %DateTime{} = failed_at) do
    case Map.get(running_entry, :last_validation_progress_at) do
      %DateTime{} = progress_at -> datetime_at_or_after?(progress_at, failed_at)
      _ -> false
    end
  end

  defp git_dirty_observed_at(workspace) do
    case System.cmd("git", ["status", "--porcelain=v1"], cd: workspace, stderr_to_stdout: true) do
      {status, 0} ->
        status
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&porcelain_status_paths/1)
        |> Enum.map(&Path.join(workspace, &1))
        |> Enum.map(&file_mtime_datetime/1)
        |> Enum.reject(&is_nil/1)
        |> latest_datetime()

      {_error, _exit_code} ->
        nil
    end
  rescue
    _error -> nil
  end

  defp meaningful_git_dirty_observed_at(workspace) do
    workspace
    |> meaningful_git_dirty_paths()
    |> Enum.map(&Path.join(workspace, &1))
    |> Enum.map(&file_mtime_datetime/1)
    |> Enum.reject(&is_nil/1)
    |> latest_datetime()
  rescue
    _error -> nil
  end

  defp git_ahead_commit_observed_at(workspace) do
    base_refs =
      ["origin/main", "main"]
      |> Enum.filter(&git_ref_exists?(workspace, &1))

    if base_refs == [] do
      nil
    else
      args = ["log", "-1", "--format=%cI", "HEAD"] ++ Enum.flat_map(base_refs, &[~s(--not), &1])

      case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.trim()
          |> datetime_from_iso8601()

        {_error, _exit_code} ->
          nil
      end
    end
  rescue
    _error -> nil
  end

  defp git_issue_branch_observed_at(workspace) do
    with {branch_output, 0} <- System.cmd("git", ["branch", "--show-current"], cd: workspace, stderr_to_stdout: true),
         branch = String.trim(branch_output),
         true <- issue_branch_name?(branch),
         {log_path, 0} <-
           System.cmd("git", ["rev-parse", "--git-path", "logs/refs/heads/#{branch}"],
             cd: workspace,
             stderr_to_stdout: true
           ) do
      log_path
      |> String.trim()
      |> Path.expand(workspace)
      |> file_mtime_datetime()
    else
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp issue_branch_name?(branch) when branch in ["", "main", "master"], do: false
  defp issue_branch_name?(_branch), do: true

  defp git_upstream_progress_observed_at(workspace) do
    with true <- git_ref_exists?(workspace, "@{upstream}"),
         {counts, 0} <-
           System.cmd("git", ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
             cd: workspace,
             stderr_to_stdout: true
           ),
         [_ahead, behind] <- String.split(String.trim(counts), ~r/\s+/, trim: true),
         {behind_count, ""} <- Integer.parse(behind),
         true <- behind_count > 0,
         {upstream_ref, 0} <-
           System.cmd("git", ["rev-parse", "--symbolic-full-name", "@{upstream}"],
             cd: workspace,
             stderr_to_stdout: true
           ),
         ref = String.trim(upstream_ref),
         true <- String.starts_with?(ref, "refs/remotes/"),
         {log_path, 0} <-
           System.cmd("git", ["rev-parse", "--git-path", "logs/#{ref}"],
             cd: workspace,
             stderr_to_stdout: true
           ) do
      log_path
      |> String.trim()
      |> Path.expand(workspace)
      |> file_mtime_datetime()
    else
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp git_ref_exists?(workspace, ref) do
    case System.cmd("git", ["rev-parse", "--verify", "--quiet", ref], cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _exit_code} -> false
    end
  rescue
    _error -> false
  end

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

  defp file_mtime_datetime(path) do
    with {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix),
         {:ok, datetime} <- DateTime.from_unix(mtime) do
      datetime
    else
      _ -> nil
    end
  end

  defp event_durable_progress_times(workspace, started_at, count_dispatch_preflight?) do
    workspace
    |> durable_progress_event_paths()
    |> Enum.flat_map(&durable_progress_event_file_times(&1, started_at, count_dispatch_preflight?))
  end

  defp review_classification_progress_times(workspace, started_at) when is_binary(workspace) do
    path = Path.join(workspace, @review_classification_path)

    with true <- File.regular?(path),
         {:ok, classification} <- read_review_classification_handoff(workspace),
         true <- no_code_review_classification?(classification) and resolved_review_classification?(classification),
         {:ok, head_sha} <- git_output(workspace, ["rev-parse", "HEAD"]),
         true <- classification_head_matches?(classification, String.trim(head_sha)),
         %DateTime{} = observed_at <- file_mtime_datetime(path),
         true <- datetime_at_or_after?(observed_at, started_at) do
      [observed_at]
    else
      _ -> []
    end
  rescue
    _error -> []
  end

  defp review_classification_progress_times(_workspace, _started_at), do: []

  defp durable_progress_event_paths(workspace) do
    [
      Path.join(workspace, ".orocsy/delivery/events/events.jsonl"),
      Path.join(workspace, ".codex/delivery/events/events.jsonl")
    ]
  end

  defp durable_progress_event_file_times(path, started_at, count_dispatch_preflight?) do
    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.flat_map(&durable_progress_event_line_times(&1, started_at, count_dispatch_preflight?))
    else
      []
    end
  rescue
    _error -> []
  end

  defp durable_progress_event_line_times(line, started_at, count_dispatch_preflight?) when is_binary(line) do
    with {:ok, decoded} <- Jason.decode(line),
         true <- Map.get(decoded, "status") == "passed",
         true <- durable_progress_event?(decoded, count_dispatch_preflight?),
         %DateTime{} = datetime <- decoded |> Map.get("ts") |> datetime_from_iso8601(),
         true <- datetime_at_or_after?(datetime, started_at) do
      [datetime]
    else
      _ -> []
    end
  end

  defp durable_progress_event?(%{"source" => "symphony.runtime.dispatch-preflight"}, false), do: false

  defp durable_progress_event?(%{"event" => "tool.finished", "tool" => "first-turn-miu-handoff"}, _count_dispatch_preflight?),
    do: false

  defp durable_progress_event?(%{"event" => "tool.finished", "tool" => "technical-miu-trace"}, _count_dispatch_preflight?),
    do: false

  defp durable_progress_event?(%{"event" => event} = decoded, _count_dispatch_preflight?) when is_binary(event) do
    event in @durable_progress_event_names or
      String.starts_with?(event, "eval.") or
      String.starts_with?(event, "handoff.") or
      Map.get(decoded, "phase") == "eval"
  end

  defp durable_progress_event?(_decoded, _count_dispatch_preflight?), do: false

  defp effective_first_event_max_tokens(running_entry, configured) when is_integer(configured) and configured > 0 do
    cond do
      review_rework_running_entry?(running_entry) ->
        min(configured, @review_rework_first_event_max_tokens)

      integration_check_running_entry?(running_entry) ->
        min(configured, @integration_check_first_event_max_tokens)

      true ->
        configured
    end
  end

  defp effective_first_event_max_tokens(_running_entry, configured), do: configured

  defp first_event_progress_tokens(running_entry, total_tokens) when is_integer(total_tokens) do
    uncached_progress_tokens(running_entry, total_tokens)
  end

  defp first_event_progress_tokens(_running_entry, total_tokens), do: total_tokens

  defp durable_progress_guard_tokens(running_entry, total_tokens) when is_integer(total_tokens) do
    uncached_progress_tokens(running_entry, total_tokens)
  end

  defp durable_progress_guard_tokens(_running_entry, total_tokens), do: total_tokens

  defp uncached_progress_tokens(running_entry, total_tokens) do
    cached_input_tokens = Map.get(running_entry, :codex_cached_input_tokens, 0)
    initial_uncached_input_tokens = Map.get(running_entry, :codex_initial_uncached_input_tokens, 0)

    cached_adjusted_tokens =
      if is_integer(cached_input_tokens) and cached_input_tokens > 0 do
        max(total_tokens - cached_input_tokens, 0)
      else
        total_tokens
      end

    if is_integer(initial_uncached_input_tokens) and initial_uncached_input_tokens > 0 do
      max(cached_adjusted_tokens - initial_uncached_input_tokens, 0)
    else
      cached_adjusted_tokens
    end
  end

  defp count_dispatch_preflight_progress?(_running_entry), do: false

  defp effective_no_durable_progress_min_tokens(running_entry, configured)
       when is_integer(configured) and configured > 0 do
    if integration_check_running_entry?(running_entry) do
      min(configured, @integration_check_no_progress_min_tokens)
    else
      configured
    end
  end

  defp effective_no_durable_progress_min_tokens(_running_entry, configured), do: configured

  defp integration_check_running_entry?(%{workspace_path: workspace}) when is_binary(workspace) do
    case DispatchPreflight.read(workspace) do
      {:ok, %{"mode" => "integration_check"}} -> true
      _ -> false
    end
  rescue
    _error -> false
  end

  defp integration_check_running_entry?(_running_entry), do: false

  defp review_rework_running_entry?(%{workspace_path: workspace}) when is_binary(workspace) do
    case DispatchPreflight.read(workspace) do
      {:ok, %{"mode" => "review_rework"}} -> true
      _ -> false
    end
  rescue
    _error -> false
  end

  defp review_rework_running_entry?(_running_entry), do: false

  defp datetime_from_iso8601(value) when is_binary(value) and value != "" do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp datetime_from_iso8601(_value), do: nil

  defp datetime_at_or_after?(%DateTime{} = datetime, %DateTime{} = reference) do
    # Git commit dates and file mtimes are second-granularity on common filesystems,
    # so allow a tiny boundary tolerance for work produced in the same poll second.
    DateTime.diff(datetime, reference, :second) >= -2
  end

  defp latest_datetime(datetimes) do
    Enum.max_by(datetimes, &DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without codex activity"
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        case maybe_resolve_before_dispatch(state_acc, issue) do
          {:resolved, state_acc} -> state_acc
          {:blocked, state_acc} -> state_acc
          :not_ready -> dispatch_issue(state_acc, issue)
        end
      else
        state_acc
      end
    end)
  end

  defp maybe_resolve_before_dispatch(%State{} = state, %Issue{} = issue) do
    case maybe_complete_review_classification_handoff(issue) do
      {:completed, _handoff} ->
        {:resolved, complete_issue(state, issue.id)}

      {:blocked, _reason} ->
        {:blocked, state}

      :not_ready ->
        case maybe_complete_pushed_review_handoff(issue) do
          {:completed, _handoff} ->
            {:resolved, complete_issue(state, issue.id)}

          {:blocked, _reason} ->
            {:blocked, state}

          :not_ready ->
            case maybe_handle_orchestration_review_pending(issue) do
              {:completed, _handoff} ->
                {:resolved, complete_issue(state, issue.id)}

              {:blocked, _reason} ->
                {:blocked, state}

              :not_ready ->
                :not_ready
            end
        end
    end
  end

  defp maybe_complete_review_classification_handoff(%Issue{} = issue) do
    case review_classification_handoff_candidate(issue) do
      {:ok, candidate} -> complete_review_classification_handoff(issue, candidate)
      :not_ready -> :not_ready
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp maybe_complete_review_classification_handoff(_issue), do: :not_ready

  defp maybe_handle_orchestration_review_pending(%Issue{} = issue) do
    if Config.settings!().review_monitor.enabled do
      case orchestration_review_pending_candidate(issue) do
        {:ok, candidate} ->
          inspect_orchestration_review_pending(issue, candidate)

        :not_ready ->
          :not_ready

        {:error, reason} ->
          {:blocked, reason}
      end
    else
      :not_ready
    end
  end

  defp maybe_handle_orchestration_review_pending(_issue), do: :not_ready

  defp inspect_orchestration_review_pending(%Issue{} = issue, candidate) do
    issue = %{issue | branch_name: candidate.branch}
    monitor = handoff_review_monitor(candidate.workspace)

    case ReviewMonitor.inspect_issue(issue, monitor) do
      {:ok, %{pr: nil}} ->
        :not_ready

      {:ok, inspection} ->
        complete_inspected_orchestration_review_pending(issue, candidate, Map.new(inspection))

      {:error, reason} ->
        reason = {:orchestration_review_pending_inspection_failed, reason}
        park_pushed_handoff_blocker(issue, candidate, reason)
        {:blocked, reason}
    end
  end

  defp complete_inspected_orchestration_review_pending(%Issue{} = issue, candidate, inspection) do
    case pushed_handoff_head_status(candidate, inspection) do
      :current ->
        clean_review_status = clean_codex_review_status(inspection)

        cond do
          mergeability_conflict?(inspection) ->
            :not_ready

          pushed_review_feedback_status(inspection) == :has_review_feedback ->
            :not_ready

          codex_review_request_pending?(inspection) ->
            Logger.info(
              "Orchestration review guard is waiting for pending Codex review: #{issue_context(issue)} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"}"
            )

            {:blocked, :review_pending}

          clean_review_status == :missing ->
            Logger.info(
              "Orchestration review guard found clean PR with no clean Codex review yet; requesting review without worker: #{issue_context(issue)} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"}"
            )

            case request_pushed_handoff_codex_review(issue, candidate, inspection) do
              :ok ->
                {:blocked, :review_pending}

              {:error, reason} ->
                park_pushed_handoff_blocker(issue, candidate, reason)
                {:blocked, reason}
            end

          clean_review_status == :confirmed ->
            finish_clean_pushed_review_handoff(issue, candidate, inspection)

          true ->
            reason = {:clean_codex_review_lookup_failed, clean_review_status}
            park_pushed_handoff_blocker(issue, candidate, reason)
            {:blocked, reason}
        end

      {:stale, _reason} ->
        :not_ready
    end
  end

  defp orchestration_review_pending_candidate(%Issue{} = issue) do
    with true <- review_pending_issue_state?(issue.state),
         {:ok, workspace} <- Workspace.path_for_issue(issue),
         true <- File.dir?(workspace),
         {:ok, status} <- git_output(workspace, ["status", "--short", "--branch"]),
         true <- clean_pushed_tracking_status?(status),
         {:ok, branch} <- git_output(workspace, ["branch", "--show-current"]),
         branch <- String.trim(branch),
         true <- handoff_branch_name?(branch),
         {:ok, head_sha} <- git_output(workspace, ["rev-parse", "HEAD"]) do
      {:ok,
       %{
         workspace: workspace,
         checkpoint: "Orchestration review-pending guard",
         status: String.trim(status),
         branch: branch,
         head_sha: String.trim(head_sha),
         head_committed_at: git_head_committed_at(workspace)
       }}
    else
      false -> :not_ready
      "" -> :not_ready
      {:error, reason} -> {:error, reason}
      _ -> :not_ready
    end
  rescue
    error -> {:error, {:orchestration_review_pending_candidate_failed, Exception.message(error)}}
  end

  defp review_pending_issue_state?(state) when is_binary(state) do
    state = normalize_issue_state(state)
    state == "rework" or String.contains?(state, "review")
  end

  defp review_pending_issue_state?(_state), do: false

  defp clean_pushed_tracking_status?(status) when is_binary(status) do
    lines = String.split(status, "\n", trim: true)
    branch_line = List.first(lines) || ""
    dirty_lines = Enum.reject(lines, &String.starts_with?(&1, "##"))

    dirty_lines == [] and
      String.contains?(branch_line, "...") and
      not String.contains?(branch_line, ["ahead", "behind", "diverged"])
  end

  defp clean_pushed_tracking_status?(_status), do: false

  defp handoff_branch_name?(branch) when is_binary(branch) do
    branch = String.trim(branch)
    branch != "" and branch not in ["main", "master", "trunk", "develop", "dev"]
  end

  defp handoff_branch_name?(_branch), do: false

  defp complete_review_classification_handoff(%Issue{} = issue, candidate) do
    if Config.settings!().review_monitor.enabled do
      case inspect_review_classification_handoff(issue, candidate) do
        {:ok, inspection} ->
          complete_inspected_review_classification_handoff(issue, candidate, inspection)

        {:error, {:missing_pull_request, _candidate}} ->
          :not_ready

        {:error, reason} ->
          park_review_classification_handoff_blocker(issue, candidate, reason)
          {:blocked, reason}

        {:blocked, reason} ->
          {:blocked, reason}
      end
    else
      :not_ready
    end
  end

  defp complete_inspected_review_classification_handoff(%Issue{} = issue, candidate, inspection) do
    case pushed_handoff_head_status(candidate, inspection) do
      :current ->
        if integration_check_mergeability_rework_needed?(issue, inspection) do
          Logger.info(
            "No-code review classification handoff PR still has merge conflicts; dispatching integration check: #{issue_context(issue)} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"} mergeable_state=#{inspect(map_value(inspection, [:mergeable_state, "mergeable_state"]))}"
          )

          :not_ready
        else
          case pushed_review_feedback_status(inspection) do
            :clean -> complete_clean_review_classification_handoff(issue, candidate, inspection)
            :has_review_feedback -> complete_feedback_review_classification_handoff(issue, candidate, inspection)
          end
        end

      {:stale, _reason} ->
        :not_ready
    end
  end

  defp complete_clean_review_classification_handoff(%Issue{} = issue, candidate, inspection) do
    clean_review_status = clean_codex_review_status(inspection)

    cond do
      codex_review_request_pending?(inspection) ->
        Logger.info(
          "No-code review classification handoff is waiting for clean Codex review: #{issue_context(issue)} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"}"
        )

        {:blocked, :review_pending}

      clean_review_status == :confirmed ->
        finish_clean_review_classification_handoff(issue, candidate, inspection)

      clean_review_status == :missing ->
        request_review_classification_codex_review(issue, candidate, inspection)

      review_classification_review_request_recorded?(candidate.workspace) ->
        Logger.info(
          "No-code review classification handoff already requested Codex review and is waiting: #{issue_context(issue)} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"}"
        )

        {:blocked, :review_pending}

      true ->
        reason = {:clean_codex_review_lookup_failed, clean_review_status}
        park_review_classification_handoff_blocker(issue, candidate, reason)
        {:blocked, reason}
    end
  end

  defp complete_feedback_review_classification_handoff(%Issue{} = issue, candidate, inspection) do
    cond do
      codex_review_request_pending?(inspection) ->
        Logger.info(
          "No-code review classification handoff is waiting for fresh Codex review: #{issue_context(issue)} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"}"
        )

        {:blocked, :review_pending}

      review_classification_review_request_recorded?(candidate.workspace) ->
        case review_feedback_after_latest_request_status(inspection) do
          :feedback_after_request ->
            :not_ready

          :no_feedback_after_request ->
            Logger.info(
              "No-code review classification handoff already requested Codex review and no newer feedback has arrived: #{issue_context(issue)} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"}"
            )

            {:blocked, :review_pending}

          {:error, reason} ->
            reason = {:review_feedback_after_latest_request_lookup_failed, reason}
            park_review_classification_handoff_blocker(issue, candidate, reason)
            {:blocked, reason}
        end

      true ->
        request_review_classification_codex_review(issue, candidate, inspection)
    end
  end

  defp review_classification_handoff_candidate(%Issue{} = issue) do
    with {:ok, workspace} <- Workspace.path_for_issue(issue),
         true <- File.dir?(workspace),
         {:ok, classification} <- read_review_classification_handoff(workspace),
         true <- no_code_review_classification?(classification),
         true <- resolved_review_classification?(classification),
         {:ok, status} <- git_output(workspace, ["status", "--short", "--branch"]),
         {:ok, dirty_status} <- git_output(workspace, ["status", "--porcelain=v1"]),
         true <- String.trim(dirty_status) == "",
         {:ok, branch} <- git_output(workspace, ["branch", "--show-current"]),
         {:ok, head_sha} <- git_output(workspace, ["rev-parse", "HEAD"]),
         head_sha = String.trim(head_sha),
         true <- classification_head_matches?(classification, head_sha) do
      {:ok,
       %{
         workspace: workspace,
         classification: classification,
         status: String.trim(status),
         branch: first_present(classification["branch"], String.trim(branch)),
         head_sha: head_sha,
         pr_number: classification["pr"],
         checkpoint: review_classification_checkpoint(classification, status)
       }}
    else
      false -> :not_ready
      "" -> :not_ready
      {:error, :missing_review_classification_handoff} -> :not_ready
      {:error, reason} -> {:error, reason}
      _ -> :not_ready
    end
  rescue
    error -> {:error, {:review_classification_handoff_candidate_failed, Exception.message(error)}}
  end

  defp read_review_classification_handoff(workspace) when is_binary(workspace) do
    path = Path.join(workspace, @review_classification_path)

    cond do
      not File.regular?(path) ->
        {:error, :missing_review_classification_handoff}

      true ->
        path
        |> File.read!()
        |> Jason.decode()
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

  defp normalize_review_classification(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp classification_head_matches?(classification, head_sha) when is_map(classification) and is_binary(head_sha) do
    classification_head = classification["head"] || classification["head_sha"]
    is_binary(classification_head) and String.trim(classification_head) == head_sha
  end

  defp classification_head_matches?(_classification, _head_sha), do: false

  defp review_classification_checkpoint(classification, status) do
    feedback_count =
      classification
      |> Map.get("feedback", [])
      |> case do
        feedback when is_list(feedback) -> length(feedback)
        _ -> 0
      end

    """
    No-code review classification checkpoint:

    - Classification: #{classification["classification"] || "unknown"}
    - Reviewed head: `#{short_sha(classification["head"] || classification["head_sha"])}`
    - Feedback classified as resolved/stale: #{feedback_count}
    - Git status: #{String.trim(status)}
    - Next action: request or wait for a fresh Codex review without redispatching a product-code worker.
    """
    |> String.trim()
  end

  defp inspect_review_classification_handoff(%Issue{} = issue, %{branch: branch, workspace: workspace} = candidate) do
    monitor = handoff_review_monitor(workspace)
    issue = %{issue | branch_name: first_present(issue.branch_name, branch)}

    case ReviewMonitor.inspect_issue(issue, monitor) do
      {:ok, %{pr: nil}} ->
        {:error, {:missing_pull_request, candidate}}

      {:ok, inspection} ->
        {:ok, Map.new(inspection)}

      {:error, reason} ->
        reason = {:review_classification_handoff_inspection_failed, reason}
        park_review_classification_handoff_blocker(issue, candidate, reason)
        {:blocked, reason}
    end
  end

  defp review_classification_review_request_recorded?(workspace) do
    pushed_handoff_review_request_recorded?(workspace)
  end

  defp request_review_classification_codex_review(%Issue{} = issue, candidate, inspection) do
    repo = map_value(inspection, [:repo, "repo"])
    pr = map_value(inspection, [:pr, "pr"])
    body = review_classification_codex_review_body(issue, candidate, inspection)

    case ReviewMonitor.request_codex_review(repo, pr, body) do
      {:ok, _comment} ->
        record_review_classification_request_event(candidate.workspace, issue, candidate, inspection)
        _ = Tracker.create_comment(issue.id, review_classification_request_tracker_comment(issue, candidate, inspection))

        Logger.info(
          "Requested fresh Codex review directly for no-code review classification handoff: #{issue_context(issue)} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"}"
        )

        {:blocked, :review_pending}

      {:error, reason} ->
        reason = {:codex_review_request_failed, reason}
        park_review_classification_handoff_blocker(issue, candidate, reason)
        {:blocked, reason}
    end
  end

  defp review_classification_codex_review_body(%Issue{} = issue, candidate, inspection) do
    """
    @codex review

    Requested by Symphony after #{issue.identifier || issue.id || "this issue"} classified the current PR feedback as already resolved at #{short_sha(candidate.head_sha)} on PR #{pr_label(inspection)}. Please re-check the current head so older unresolved review threads can be cleared or replaced with fresh feedback.
    """
    |> String.trim()
  end

  defp review_classification_request_tracker_comment(%Issue{} = issue, candidate, inspection) do
    """
    Symphony requested a fresh Codex PR review directly from the no-code review classification checkpoint, without starting another product-code worker.

    - Issue: `#{issue.identifier}`
    - Branch: `#{candidate.branch}`
    - Commit: `#{short_sha(candidate.head_sha)}`
    - PR: #{pr_label(inspection)}
    - State kept: `#{issue.state}`
    - Next action: wait for Codex review; if new current-head feedback appears after this request, Symphony will redispatch bounded review rework.
    """
    |> String.trim()
  end

  defp record_review_classification_request_event(workspace, %Issue{} = issue, candidate, inspection)
       when is_binary(workspace) do
    event_dir = Path.join(workspace, ".orocsy/delivery/events")
    File.mkdir_p!(event_dir)

    event = %{
      "event" => "tool.finished",
      "status" => "passed",
      "tool" => "codex-review-requested",
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "issue" => issue.identifier,
      "branch" => candidate.branch,
      "head_sha" => candidate.head_sha,
      "pr_number" => map_value(inspection, [:pr_number, "pr_number"]),
      "pr_url" => map_value(inspection, [:pr_url, "pr_url"]),
      "mode" => "direct-review-classification-request"
    }

    File.write!(Path.join(event_dir, "events.jsonl"), Jason.encode!(event) <> "\n", [:append])
  rescue
    error ->
      Logger.debug("Unable to record review classification request event for #{issue_context(issue)}: #{Exception.message(error)}")
  end

  defp record_review_classification_request_event(_workspace, _issue, _candidate, _inspection), do: :ok

  defp finish_clean_review_classification_handoff(%Issue{} = issue, candidate, inspection) do
    with {:ok, target_state} <- handoff_review_state(),
         :ok <- Tracker.update_issue_state(issue.id, target_state) do
      _ = Tracker.create_comment(issue.id, review_classification_handoff_comment(issue, candidate, inspection, target_state))
      record_review_classification_handoff_event(candidate.workspace, issue, candidate, inspection, target_state)

      Logger.info(
        "Completed no-code review classification handoff without Codex worker: #{issue_context(issue)} state=#{target_state} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"}"
      )

      {:completed,
       %{
         target_state: target_state,
         workspace: candidate.workspace,
         branch: candidate.branch,
         head_sha: candidate.head_sha,
         pr_number: inspection.pr_number,
         pr_url: inspection.pr_url
       }}
    else
      {:error, reason} ->
        park_review_classification_handoff_blocker(issue, candidate, reason)
        {:blocked, reason}
    end
  end

  defp review_classification_handoff_comment(%Issue{} = issue, candidate, inspection, target_state) do
    """
    Symphony completed the no-code review classification handoff without starting another product-code worker because the current PR has a clean Codex result after the latest review request.

    - Issue: `#{issue.identifier}`
    - New state: `#{target_state}`
    - Branch: `#{candidate.branch}`
    - Commit: `#{short_sha(candidate.head_sha)}`
    - PR: #{pr_label(inspection)}

    Classification evidence:
    #{candidate.checkpoint}
    """
    |> String.trim()
  end

  defp record_review_classification_handoff_event(workspace, %Issue{} = issue, candidate, inspection, target_state)
       when is_binary(workspace) do
    event_dir = Path.join(workspace, ".orocsy/delivery/events")
    File.mkdir_p!(event_dir)

    event = %{
      "event" => "handoff.completed",
      "status" => "passed",
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "issue" => issue.identifier,
      "branch" => candidate.branch,
      "head_sha" => candidate.head_sha,
      "pr_number" => inspection.pr_number,
      "pr_url" => inspection.pr_url,
      "state" => target_state,
      "mode" => "direct-review-classification-handoff"
    }

    File.write!(Path.join(event_dir, "events.jsonl"), Jason.encode!(event) <> "\n", [:append])
  rescue
    error ->
      Logger.debug("Unable to record review classification handoff event for #{issue_context(issue)}: #{Exception.message(error)}")
  end

  defp park_review_classification_handoff_blocker(%Issue{} = issue, candidate, reason) do
    failure = %{
      action: :block,
      kind: "handoff-review",
      source_status: "blocked",
      next_action: "retry",
      summary:
        "Symphony stopped before starting a Codex worker because this issue has a no-code review classification checkpoint, but the runtime could not inspect, request, or update the PR/Linear handoff state with bounded context.",
      required_corrections: [
        "Retry the no-code review classification handoff when GitHub and Linear are available.",
        "Do not start a full Codex worker for this handoff-only checkpoint unless fresh current-head feedback arrives after the latest review request."
      ]
    }

    correction_result =
      Workspace.create_correction_in_workspace(
        candidate.workspace,
        issue,
        %{
          source: "symphony.runtime.review-classification-handoff",
          source_status: failure.source_status,
          summary: failure.summary,
          findings: [inspect(reason)],
          required_corrections: failure.required_corrections,
          next_action: failure.next_action
        }
      )

    case correction_result do
      {:ok, correction} -> maybe_comment_runtime_failure(issue, correction, failure)
      {:error, correction_reason} -> Logger.warning("Unable to write no-code review classification blocker for #{issue_context(issue)}: #{inspect(correction_reason)}")
    end
  end

  defp maybe_complete_pushed_review_handoff(%Issue{} = issue) do
    if in_progress_implementation_issue?(issue) do
      :not_ready
    else
      case pushed_review_handoff_candidate(issue) do
        {:ok, candidate} -> complete_pushed_review_handoff(issue, candidate)
        :not_ready -> :not_ready
        {:error, reason} -> {:blocked, reason}
      end
    end
  end

  defp maybe_complete_pushed_review_handoff(_issue), do: :not_ready

  defp in_progress_implementation_issue?(%Issue{} = issue) do
    issue_state(issue) == "in progress" and
      issue_ticket_type(issue) == "implementation" and
      not integration_check_issue?(issue)
  end

  defp in_progress_implementation_issue?(_issue), do: false

  defp issue_state(%Issue{state: state}) do
    state
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp issue_ticket_type(%Issue{} = issue) do
    text =
      issue.description
      |> to_string()
      |> String.downcase()

    cond do
      Regex.match?(~r/ticket\s+type\s*\n+\s*implementation/, text) -> "implementation"
      String.contains?(text, "ticket_type") and String.contains?(text, "implementation") -> "implementation"
      true -> ""
    end
  end

  defp complete_pushed_review_handoff(%Issue{} = issue, candidate) do
    if Config.settings!().review_monitor.enabled do
      case inspect_pushed_review_handoff(issue, candidate) do
        {:ok, inspection} ->
          complete_inspected_pushed_review_handoff(issue, candidate, inspection)

        {:error, {:missing_pull_request, _candidate}} ->
          :not_ready

        {:error, reason} ->
          park_pushed_handoff_blocker(issue, candidate, reason)
          {:blocked, reason}

        {:blocked, reason} ->
          {:blocked, reason}
      end
    else
      :not_ready
    end
  end

  defp complete_inspected_pushed_review_handoff(%Issue{} = issue, candidate, inspection) do
    case pushed_handoff_head_status(candidate, inspection) do
      :current ->
        if integration_check_mergeability_rework_needed?(issue, inspection) do
          Logger.info(
            "Pushed handoff PR still has merge conflicts; dispatching integration check: #{issue_context(issue)} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"} mergeable_state=#{inspect(map_value(inspection, [:mergeable_state, "mergeable_state"]))}"
          )

          :not_ready
        else
          case pushed_review_feedback_status(inspection) do
            :clean ->
              clean_review_status = clean_codex_review_status(inspection)

              cond do
                codex_review_request_pending?(inspection) ->
                  Logger.info(
                    "Pushed review handoff is waiting for clean Codex review before completing: #{issue_context(issue)} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"}"
                  )

                  {:blocked, :review_pending}

                clean_review_status == :missing ->
                  Logger.info(
                    "Pushed review handoff has no clean Codex review result yet; requesting review without redispatching a worker: #{issue_context(issue)} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"}"
                  )

                  case request_pushed_handoff_codex_review(issue, candidate, inspection) do
                    :ok ->
                      {:blocked, :review_pending}

                    {:error, reason} ->
                      park_pushed_handoff_blocker(issue, candidate, reason)
                      {:blocked, reason}
                  end

                clean_review_status == :confirmed ->
                  finish_clean_pushed_review_handoff(issue, candidate, inspection)

                true ->
                  reason = {:clean_codex_review_lookup_failed, clean_review_status}
                  park_pushed_handoff_blocker(issue, candidate, reason)
                  {:blocked, reason}
              end

            :has_review_feedback ->
              cond do
                codex_review_request_pending?(inspection) ->
                  Logger.info(
                    "Pushed review handoff is waiting for fresh Codex review before redispatch: #{issue_context(issue)} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"}"
                  )

                  {:blocked, :review_pending}

                pushed_handoff_codex_review_request_needed?(candidate, inspection) ->
                  case request_pushed_handoff_codex_review(issue, candidate, inspection) do
                    :ok ->
                      Logger.info(
                        "Requested fresh Codex review directly for pushed handoff: #{issue_context(issue)} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"}"
                      )

                      {:blocked, :review_pending}

                    {:error, reason} ->
                      park_pushed_handoff_blocker(issue, candidate, reason)
                      {:blocked, reason}
                  end

                pushed_handoff_review_request_recorded?(candidate.workspace) ->
                  case review_feedback_after_latest_request_status(inspection) do
                    :feedback_after_request ->
                      :not_ready

                    :no_feedback_after_request ->
                      Logger.info(
                        "Pushed review handoff already requested Codex review and is waiting for review state to change: #{issue_context(issue)} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"}"
                      )

                      {:blocked, :review_pending}

                    {:error, reason} ->
                      reason = {:review_feedback_after_latest_request_lookup_failed, reason}
                      park_pushed_handoff_blocker(issue, candidate, reason)
                      {:blocked, reason}
                  end

                true ->
                  :not_ready
              end
          end
        end

      {:stale, reason} ->
        park_pushed_handoff_blocker(issue, candidate, reason)
        {:blocked, reason}
    end
  end

  defp integration_check_mergeability_rework_needed?(%Issue{} = issue, inspection) when is_map(inspection) do
    integration_check_issue?(issue) and mergeability_conflict?(inspection)
  end

  defp integration_check_mergeability_rework_needed?(_issue, _inspection), do: false

  defp integration_check_issue?(%Issue{} = issue) do
    text =
      [issue.title, issue.description]
      |> Enum.map(&to_string/1)
      |> Enum.join("\n")
      |> String.downcase()

    String.contains?(text, ["integration-check", "integration check", "final pr handoff", "merge conflict"])
  end

  defp mergeability_conflict?(inspection) when is_map(inspection) do
    state =
      inspection
      |> map_value([:mergeable_state, "mergeable_state"])
      |> to_string()
      |> String.downcase()

    mergeable = map_value(inspection, [:mergeable, "mergeable"])

    state in ["dirty", "conflicting", "conflict", "merge_conflict"] or
      (mergeable == false and state in ["dirty", "conflicting"])
  end

  defp mergeability_conflict?(_inspection), do: false

  defp pushed_handoff_head_status(%{head_sha: candidate_head}, inspection) do
    live_head = inspection_head_sha(inspection)

    cond do
      !is_binary(candidate_head) or String.trim(candidate_head) == "" ->
        {:stale, {:pushed_handoff_missing_local_head, live_head}}

      !is_binary(live_head) or String.trim(live_head) == "" ->
        {:stale, {:pushed_handoff_missing_live_pr_head, candidate_head}}

      candidate_head == live_head ->
        :current

      true ->
        {:stale, {:pushed_handoff_head_mismatch, candidate_head, live_head}}
    end
  end

  defp inspection_head_sha(inspection) when is_map(inspection) do
    Map.get(inspection, :head_sha) || Map.get(inspection, "head_sha")
  end

  defp inspection_head_sha(_inspection), do: nil

  defp finish_clean_pushed_review_handoff(%Issue{} = issue, candidate, inspection) do
    with {:ok, target_state} <- handoff_review_state(),
         :ok <- Tracker.update_issue_state(issue.id, target_state) do
      _ = Tracker.create_comment(issue.id, direct_handoff_comment(issue, candidate, inspection, target_state))
      record_direct_handoff_event(candidate.workspace, issue, candidate, inspection, target_state)

      Logger.info(
        "Completed pushed review handoff without Codex worker: #{issue_context(issue)} state=#{target_state} branch=#{candidate.branch} pr=#{inspection.pr_url || inspection.pr_number || "unknown"}"
      )

      {:completed,
       %{
         target_state: target_state,
         workspace: candidate.workspace,
         branch: candidate.branch,
         head_sha: candidate.head_sha,
         pr_number: inspection.pr_number,
         pr_url: inspection.pr_url
       }}
    else
      {:error, reason} ->
        park_pushed_handoff_blocker(issue, candidate, reason)
        {:blocked, reason}
    end
  end

  defp pushed_review_handoff_candidate(%Issue{} = issue) do
    with {:ok, workspace} <- Workspace.path_for_issue(issue),
         true <- File.dir?(workspace),
         checkpoint when is_binary(checkpoint) and checkpoint != "" <- PromptBuilder.workspace_recovery_checkpoint(workspace),
         true <- String.starts_with?(checkpoint, "Pushed validated handoff checkpoint:"),
         {:ok, status} <- git_output(workspace, ["status", "--short", "--branch"]),
         {:ok, branch} <- git_output(workspace, ["branch", "--show-current"]),
         {:ok, head_sha} <- git_output(workspace, ["rev-parse", "HEAD"]) do
      {:ok,
       %{
         workspace: workspace,
         checkpoint: checkpoint,
         status: String.trim(status),
         branch: String.trim(branch),
         head_sha: String.trim(head_sha),
         head_committed_at: git_head_committed_at(workspace)
       }}
    else
      false -> :not_ready
      "" -> :not_ready
      {:error, reason} -> {:error, reason}
      _ -> :not_ready
    end
  rescue
    error -> {:error, {:pushed_handoff_candidate_failed, Exception.message(error)}}
  end

  defp inspect_pushed_review_handoff(%Issue{} = issue, %{branch: branch, workspace: workspace} = candidate) do
    monitor = handoff_review_monitor(workspace)
    issue = %{issue | branch_name: first_present(issue.branch_name, branch)}

    case ReviewMonitor.inspect_issue(issue, monitor) do
      {:ok, %{pr: nil}} ->
        {:error, {:missing_pull_request, candidate}}

      {:ok, inspection} ->
        {:ok, Map.new(inspection)}

      {:error, reason} ->
        reason = {:pushed_handoff_review_inspection_failed, reason}
        park_pushed_handoff_blocker(issue, candidate, reason)
        {:blocked, reason}
    end
  end

  defp pushed_review_feedback_status(%{feedback: feedback}) when is_list(feedback) do
    if feedback == [] do
      :clean
    else
      :has_review_feedback
    end
  end

  defp pushed_review_feedback_status(_inspection), do: :has_review_feedback

  defp codex_review_request_pending?(%{repo: repo, pr: pr, feedback: feedback}) do
    case ReviewMonitor.codex_review_request_pending?(repo, pr, feedback) do
      {:ok, pending?} ->
        pending?

      {:error, reason} ->
        Logger.debug("Unable to inspect pending Codex review request: #{inspect(reason)}")
        false
    end
  end

  defp codex_review_request_pending?(_inspection), do: false

  defp clean_codex_review_status(%{repo: repo, pr: pr}) do
    case ReviewMonitor.clean_codex_review_after_latest_request?(repo, pr) do
      {:ok, true} ->
        :confirmed

      {:ok, false} ->
        :missing

      {:error, reason} ->
        Logger.debug("Unable to inspect clean Codex review result: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp clean_codex_review_status(_inspection), do: :missing

  defp review_feedback_after_latest_request_status(%{repo: repo, pr: pr, feedback: feedback}) do
    case ReviewMonitor.review_feedback_after_latest_codex_request?(repo, pr, feedback) do
      {:ok, true} -> :feedback_after_request
      {:ok, false} -> :no_feedback_after_request
      {:error, reason} -> {:error, reason}
    end
  end

  defp review_feedback_after_latest_request_status(_inspection), do: :no_feedback_after_request

  defp pushed_handoff_codex_review_request_needed?(%{head_committed_at: %DateTime{} = head_at}, inspection) do
    feedback = map_value(inspection, [:feedback, "feedback"])

    case latest_review_feedback_at(feedback) do
      %DateTime{} = feedback_at -> DateTime.compare(head_at, feedback_at) == :gt
      _ -> false
    end
  end

  defp pushed_handoff_codex_review_request_needed?(_candidate, _inspection), do: false

  defp request_pushed_handoff_codex_review(%Issue{} = issue, candidate, inspection) do
    repo = map_value(inspection, [:repo, "repo"])
    pr = map_value(inspection, [:pr, "pr"])
    body = pushed_handoff_codex_review_body(issue, candidate, inspection)

    case ReviewMonitor.request_codex_review(repo, pr, body) do
      {:ok, _comment} ->
        record_review_request_event(candidate.workspace, issue, candidate, inspection)
        _ = Tracker.create_comment(issue.id, direct_review_request_tracker_comment(issue, candidate, inspection))
        :ok

      {:error, reason} ->
        {:error, {:codex_review_request_failed, reason}}
    end
  end

  defp pushed_handoff_codex_review_body(%Issue{} = issue, candidate, inspection) do
    """
    @codex review

    Requested by Symphony after pushed handoff commit #{short_sha(candidate.head_sha)} for #{issue.identifier || issue.id || "this issue"} on PR #{pr_label(inspection)}.
    """
    |> String.trim()
  end

  defp direct_review_request_tracker_comment(%Issue{} = issue, candidate, inspection) do
    """
    Symphony requested a fresh Codex PR review directly from the pushed handoff checkpoint, without starting another Codex worker.

    - Issue: `#{issue.identifier}`
    - Branch: `#{candidate.branch}`
    - Commit: `#{short_sha(candidate.head_sha)}`
    - PR: #{pr_label(inspection)}
    - State kept: `#{issue.state}`
    - Next action: wait for Codex review; if current-head feedback remains after this request, Symphony will keep the issue in rework.
    """
    |> String.trim()
  end

  defp record_review_request_event(workspace, %Issue{} = issue, candidate, inspection)
       when is_binary(workspace) do
    event_dir = Path.join(workspace, ".orocsy/delivery/events")
    File.mkdir_p!(event_dir)

    event = %{
      "event" => "tool.finished",
      "status" => "passed",
      "tool" => "codex-review-requested",
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "issue" => issue.identifier,
      "branch" => candidate.branch,
      "head_sha" => candidate.head_sha,
      "pr_number" => map_value(inspection, [:pr_number, "pr_number"]),
      "pr_url" => map_value(inspection, [:pr_url, "pr_url"]),
      "mode" => "direct-pushed-review-request"
    }

    File.write!(Path.join(event_dir, "events.jsonl"), Jason.encode!(event) <> "\n", [:append])
  rescue
    error ->
      Logger.debug("Unable to record review request event for #{issue_context(issue)}: #{Exception.message(error)}")
  end

  defp record_review_request_event(_workspace, _issue, _candidate, _inspection), do: :ok

  defp pushed_handoff_review_request_recorded?(workspace) when is_binary(workspace) do
    workspace
    |> durable_progress_event_paths()
    |> Enum.any?(&review_request_event_recorded?/1)
  end

  defp pushed_handoff_review_request_recorded?(_workspace), do: false

  defp review_request_event_recorded?(path) do
    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.any?(&review_request_event_line?/1)
    else
      false
    end
  rescue
    _error -> false
  end

  defp review_request_event_line?(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"event" => "tool.finished", "status" => "passed", "tool" => tool}}
      when tool in ["github-pr-created-and-codex-review-requested", "codex-review-requested"] ->
        true

      {:ok, %{"event" => event, "status" => "passed"}}
      when event in ["github-pr-created-and-codex-review-requested", "codex-review-requested"] ->
        true

      _ ->
        false
    end
  end

  defp review_request_event_line?(_line), do: false

  defp handoff_review_state do
    Config.settings!().review_monitor.states
    |> Enum.find_value(fn state ->
      state = state |> to_string() |> String.trim()
      if state == "", do: nil, else: state
    end)
    |> case do
      nil -> {:error, :missing_review_state}
      state -> {:ok, state}
    end
  end

  defp handoff_review_monitor(workspace) do
    monitor = Config.settings!().review_monitor

    repo =
      case monitor.repo do
        repo when is_binary(repo) and repo != "" -> repo
        _ -> git_remote_repo(workspace)
      end

    %{monitor | repo: repo}
  end

  defp git_remote_repo(workspace) do
    with {:ok, remote_url} <- git_output(workspace, ["remote", "get-url", "origin"]) do
      remote_url
      |> String.trim()
      |> String.replace_prefix("https://github.com/", "")
      |> String.replace_prefix("git@github.com:", "")
      |> String.replace_suffix(".git", "")
    else
      _ -> nil
    end
  end

  defp git_output(workspace, args) when is_binary(workspace) and is_list(args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, exit_code} -> {:error, {:git_failed, args, exit_code, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_exception, args, Exception.message(error)}}
  end

  defp git_head_committed_at(workspace) when is_binary(workspace) do
    case git_output(workspace, ["log", "-1", "--format=%cI", "HEAD"]) do
      {:ok, output} -> output |> String.trim() |> datetime_from_iso8601()
      _ -> nil
    end
  end

  defp git_head_committed_at(_workspace), do: nil

  defp latest_review_feedback_at(feedback) when is_list(feedback) do
    feedback
    |> Enum.map(&review_feedback_created_at/1)
    |> Enum.reject(&is_nil/1)
    |> latest_datetime()
  end

  defp latest_review_feedback_at(_feedback), do: nil

  defp review_feedback_created_at(%{type: :thread, payload: thread}), do: thread |> thread_latest_comment() |> payload_created_at()
  defp review_feedback_created_at(%{type: :comment, payload: comment}), do: payload_created_at(comment)
  defp review_feedback_created_at(%{type: :review, payload: review}), do: payload_created_at(review)
  defp review_feedback_created_at(%{"type" => "thread", "payload" => thread}), do: thread |> thread_latest_comment() |> payload_created_at()
  defp review_feedback_created_at(%{"type" => "comment", "payload" => comment}), do: payload_created_at(comment)
  defp review_feedback_created_at(%{"type" => "review", "payload" => review}), do: payload_created_at(review)
  defp review_feedback_created_at(_feedback), do: nil

  defp thread_latest_comment(%{"comments" => %{"nodes" => comments}}) when is_list(comments), do: List.last(comments) || %{}
  defp thread_latest_comment(%{comments: %{nodes: comments}}) when is_list(comments), do: List.last(comments) || %{}
  defp thread_latest_comment(_thread), do: %{}

  defp payload_created_at(%{} = payload) do
    payload
    |> map_value([:createdAt, "createdAt", :created_at, "created_at", :submitted_at, "submitted_at"])
    |> datetime_from_iso8601()
  end

  defp payload_created_at(_payload), do: nil

  defp first_present(primary, fallback) when is_binary(primary) do
    case String.trim(primary) do
      "" -> fallback
      value -> value
    end
  end

  defp first_present(_primary, fallback), do: fallback

  defp direct_handoff_comment(%Issue{} = issue, candidate, inspection, target_state) do
    """
    Symphony completed the pushed review handoff without starting a new Codex worker because the existing workspace is clean, pushed, validated, and the current PR has no active current-head feedback.

    - Issue: `#{issue.identifier}`
    - New state: `#{target_state}`
    - Branch: `#{candidate.branch}`
    - Commit: `#{short_sha(candidate.head_sha)}`
    - PR: #{pr_label(inspection)}

    Validation evidence:
    #{candidate.checkpoint}
    """
    |> String.trim()
  end

  defp pr_label(%{pr_url: url}) when is_binary(url) and url != "", do: url
  defp pr_label(%{pr_number: number}) when not is_nil(number), do: "##{number}"
  defp pr_label(_inspection), do: "unknown"

  defp short_sha(sha) when is_binary(sha) and byte_size(sha) >= 10, do: binary_part(sha, 0, 10)
  defp short_sha(sha) when is_binary(sha), do: sha
  defp short_sha(_sha), do: "unknown"

  defp record_direct_handoff_event(workspace, %Issue{} = issue, candidate, inspection, target_state)
       when is_binary(workspace) do
    event_dir = Path.join(workspace, ".orocsy/delivery/events")
    File.mkdir_p!(event_dir)

    event = %{
      "event" => "handoff.completed",
      "status" => "passed",
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "issue" => issue.identifier,
      "branch" => candidate.branch,
      "head_sha" => candidate.head_sha,
      "pr_number" => inspection.pr_number,
      "pr_url" => inspection.pr_url,
      "state" => target_state,
      "mode" => "direct-pushed-review-handoff"
    }

    File.write!(Path.join(event_dir, "events.jsonl"), Jason.encode!(event) <> "\n", [:append])
  rescue
    error ->
      Logger.debug("Unable to record direct handoff event for #{issue_context(issue)}: #{Exception.message(error)}")
  end

  defp park_pushed_handoff_blocker(%Issue{} = issue, candidate, reason) do
    failure = %{
      action: :block,
      kind: "handoff-review",
      source_status: "blocked",
      next_action: "retry",
      summary:
        "Symphony stopped before starting a Codex worker because this issue is at a pushed validated handoff checkpoint, but the runtime could not inspect or update the PR/Linear handoff state with bounded context.",
      required_corrections: [
        "Retry the PR/Linear handoff inspection when GitHub and Linear are available.",
        "Do not start a full Codex worker for this handoff-only checkpoint unless current PR feedback requires code changes."
      ]
    }

    correction_result =
      Workspace.create_correction_in_workspace(
        candidate.workspace,
        issue,
        %{
          source: "symphony.runtime.handoff-review",
          source_status: failure.source_status,
          summary: failure.summary,
          findings: [inspect(reason)],
          required_corrections: failure.required_corrections,
          next_action: failure.next_action
        }
      )

    case correction_result do
      {:ok, correction} -> maybe_comment_runtime_failure(issue, correction, failure)
      {:error, correction_reason} -> Logger.warning("Unable to write pushed handoff blocker for #{issue_context(issue)}: #{inspect(correction_reason)}")
    end
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !issue_blocked_by_non_terminal?(issue, terminal_states) and
      workflow_correction_gate_allows_dispatch?(issue) and
      !review_rework_review_request_pending?(issue) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp review_rework_review_request_pending?(%Issue{state: state_name} = issue)
       when is_binary(state_name) do
    monitor = Config.settings!().review_monitor

    cond do
      not monitor.enabled ->
        false

      normalize_issue_state(state_name) != normalize_issue_state(monitor.rework_state) ->
        false

      true ->
        review_request_pending_for_issue?(issue, monitor)
    end
  end

  defp review_rework_review_request_pending?(_issue), do: false

  defp review_request_pending_for_issue?(%Issue{} = issue, monitor) do
    case ReviewMonitor.inspect_issue(issue, monitor) do
      {:ok, %{repo: repo, pr: pr, feedback: feedback}} when is_list(feedback) ->
        case ReviewMonitor.codex_review_request_pending?(repo, pr, feedback) do
          {:ok, true} ->
            Logger.info("Review rework dispatch is waiting for pending Codex review: #{issue_context(issue)}")

            true

          {:ok, false} ->
            false

          {:error, reason} ->
            Logger.debug("Unable to inspect pending Codex review request before dispatch: #{inspect(reason)}")
            false
        end

      {:ok, _inspection} ->
        false

      {:error, reason} ->
        Logger.debug("Unable to inspect review feedback before dispatch: #{inspect(reason)}")
        false
    end
  end

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      issue_allowed_by_tracker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp issue_allowed_by_tracker?(%Issue{} = issue) do
    allowlist = Config.settings!().tracker.issue_allowlist || []

    allowlist =
      allowlist
      |> Enum.map(&(to_string(&1) |> String.trim()))
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    MapSet.size(allowlist) == 0 or
      MapSet.member?(allowlist, issue.id || "") or
      MapSet.member?(allowlist, issue.identifier || "")
  end

  defp issue_allowed_by_tracker?(_issue), do: false

  defp issue_blocked_by_non_terminal?(
         %Issue{blocked_by: blockers},
         terminal_states
       )
       when is_list(blockers) do
    Enum.any?(blockers, fn
      %{state: blocker_state} when is_binary(blocker_state) ->
        !terminal_issue_state?(blocker_state, terminal_states)

      _ ->
        true
    end)
  end

  defp issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_cached_input_tokens: 0,
            codex_initial_uncached_input_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            codex_last_reported_cached_input_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    cond do
      not workflow_correction_gate_allows_dispatch?(issue, metadata) ->
        Logger.warning("Retry blocked by open Orocsy correction for #{issue_context(issue)}; waiting for correction resolution")
        {:noreply, release_issue_claim(state, issue.id)}

      true ->
        case maybe_resolve_before_dispatch(state, issue) do
          {:resolved, state} ->
            {:noreply, release_issue_claim(state, issue.id)}

          {:blocked, state} ->
            {:noreply, release_issue_claim(state, issue.id)}

          :not_ready ->
            handle_unresolved_active_retry(state, issue, attempt, metadata)
        end
    end
  end

  defp handle_unresolved_active_retry(state, issue, attempt, metadata) do
    cond do
      retry_candidate_issue?(issue, terminal_state_set()) and
        dispatch_slots_available?(issue, state) and
          worker_slots_available?(state, metadata[:worker_host]) ->
        {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host])}

      true ->
        Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

        {:noreply,
         schedule_issue_retry(
           state,
           issue.id,
           attempt + 1,
           Map.merge(metadata, %{
             identifier: issue.identifier,
             error: "no available orchestrator slots"
           })
         )}
    end
  end

  defp handle_agent_failure(%State{} = state, issue_id, running_entry, reason) do
    next_attempt = planned_retry_attempt(running_entry)

    failure =
      reason
      |> classify_agent_failure()
      |> maybe_recover_token_budget_handoff(running_entry)

    cond do
      failure.action == :block ->
        park_failed_issue(state, issue_id, running_entry, reason, failure)

      next_attempt > Config.settings!().agent.max_failed_worker_retries ->
        park_failed_issue(state, issue_id, running_entry, reason, failure_retry_exhausted(failure, next_attempt))

      true ->
        schedule_issue_retry(state, issue_id, next_attempt, %{
          identifier: Map.get(running_entry, :identifier),
          error: "agent exited: #{inspect(reason)}",
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path)
        })
    end
  end

  defp planned_retry_attempt(running_entry) do
    case next_retry_attempt_from_running(running_entry) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt
      _ -> 1
    end
  end

  defp agent_failure_must_park_before_open_correction?(reason, running_entry) do
    reason
    |> classify_agent_failure()
    |> maybe_recover_token_budget_handoff(running_entry)
    |> Map.get(:action)
    |> Kernel.==(:block)
  end

  defp normal_completion_no_progress_failure(running_entry) do
    codex_config = Config.settings!().codex
    timeout_ms = codex_config.durable_progress_timeout_ms
    min_tokens = effective_no_durable_progress_min_tokens(running_entry, codex_config.durable_progress_min_tokens)

    with true <- is_integer(timeout_ms) and timeout_ms > 0,
         true <- is_integer(min_tokens) and min_tokens > 0,
         workspace when is_binary(workspace) <- Map.get(running_entry, :workspace_path),
         {:ok, %{} = summary} <- latest_worker_summary_for_running_entry(workspace, running_entry),
         true <- summary["status"] == "blocked_no_durable_progress",
         summary_counted_tokens when is_integer(summary_counted_tokens) <- integer_like(summary["counted_guard_tokens"]) do
      elapsed_ms = worker_summary_elapsed_ms(summary) || runtime_elapsed_ms(running_entry, DateTime.utc_now()) || 0
      total_tokens = integer_like(summary["total_tokens"]) || Map.get(running_entry, :codex_total_tokens, 0)
      cached_input_tokens = integer_like(summary["cached_input_tokens"]) || Map.get(running_entry, :codex_cached_input_tokens, 0)

      counted_tokens =
        normal_completion_guard_tokens(
          workspace,
          running_entry,
          summary,
          summary_counted_tokens,
          total_tokens,
          min_tokens
        )

      first_event_max_tokens = effective_first_event_max_tokens(running_entry, codex_config.durable_progress_first_event_max_tokens)
      first_event_tokens = max(counted_tokens, first_event_progress_tokens(running_entry, total_tokens))
      validation_failure = validation_failure_for_guard(running_entry)

      cond do
        normal_completion_first_event_budget_exceeded?(
          running_entry,
          first_event_tokens,
          first_event_max_tokens
        ) ->
          failure =
            missing_first_durable_event_failure(
              elapsed_ms,
              total_tokens,
              first_event_tokens,
              first_event_max_tokens,
              cached_input_tokens
            )

          reason = {:missing_first_durable_event, elapsed_ms, first_event_tokens, first_event_max_tokens}

          {:block, reason, failure}

        validation_failure != nil and counted_tokens >= min_tokens ->
          failure =
            validation_blocker_failure(
              validation_failure,
              elapsed_ms,
              elapsed_ms,
              total_tokens,
              counted_tokens,
              cached_input_tokens,
              timeout_ms,
              min_tokens
            )

          reason =
            {:validation_failure_blocker, elapsed_ms, elapsed_ms, counted_tokens, timeout_ms, min_tokens}

          {:block, reason, failure}

        counted_tokens >= min_tokens ->
          failure =
            elapsed_ms
            |> no_durable_progress_failure(
              elapsed_ms,
              total_tokens,
              counted_tokens,
              cached_input_tokens,
              timeout_ms,
              min_tokens
            )
            |> maybe_recover_no_durable_progress_handoff(running_entry)

          reason = {:normal_completion_no_durable_progress, elapsed_ms, elapsed_ms, counted_tokens, timeout_ms, min_tokens}

          {:block, reason, failure}

        true ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  defp normal_completion_guard_tokens(
         workspace,
         running_entry,
         summary,
         summary_counted_tokens,
         total_tokens,
         min_tokens
       ) do
    accumulated_tokens = accumulated_worker_summary_counted_tokens(workspace, running_entry, summary)

    counted_tokens =
      [summary_counted_tokens, accumulated_tokens]
      |> Enum.filter(&is_integer/1)
      |> Enum.max(fn -> 0 end)

    if counted_tokens < min_tokens and total_tokens >= min_tokens and normal_completion_cached_loop_summary?(summary) do
      total_tokens
    else
      counted_tokens
    end
  end

  defp normal_completion_cached_loop_summary?(%{} = summary) do
    phases =
      summary
      |> Map.get("top_phases", [])
      |> Enum.flat_map(fn
        %{"phase" => phase} when is_binary(phase) -> [phase]
        _ -> []
      end)

    loop_signatures =
      summary
      |> Map.get("loop_signatures", [])
      |> Enum.filter(&is_binary/1)

    Enum.any?(loop_signatures, &(&1 in ["read_loop", "handoff_loop", "review_loop", "validation_loop"])) or
      Enum.any?(phases, &(&1 in ["code_read", "command", "handoff", "review_handoff", "validation"]))
  end

  defp normal_completion_first_event_budget_exceeded?(running_entry, first_event_tokens, first_event_max_tokens) do
    pushed_handoff_wait_checkpoint? = pushed_handoff_wait_checkpoint?(running_entry)

    no_first_event? =
      not substantive_first_progress_observed?(running_entry) and
        not handoff_recovery_progress_observed?(running_entry) and
        not pushed_handoff_wait_checkpoint?

    is_integer(first_event_max_tokens) and first_event_max_tokens > 0 and
      first_event_tokens >= first_event_max_tokens and no_first_event? and
      not review_request_wait_checkpoint?(running_entry)
  end

  defp latest_worker_summary_for_running_entry(workspace, running_entry)
       when is_binary(workspace) and is_map(running_entry) do
    case running_entry_session_id(running_entry) do
      session_id when is_binary(session_id) and session_id != "n/a" ->
        newest_worker_summary_result(
          latest_worker_summary_for_session(workspace, session_id),
          latest_worker_summary_for_issue(workspace, running_entry)
        )

      _ ->
        latest_worker_summary_for_issue(workspace, running_entry)
    end
  end

  defp latest_worker_summary_for_running_entry(_workspace, _running_entry), do: :error

  defp newest_worker_summary_result({:ok, %{} = session_summary}, {:ok, %{} = issue_summary}) do
    if worker_summary_after?(issue_summary, session_summary) do
      {:ok, issue_summary}
    else
      {:ok, session_summary}
    end
  end

  defp newest_worker_summary_result({:ok, %{} = summary}, _issue_result), do: {:ok, summary}
  defp newest_worker_summary_result(_session_result, {:ok, %{} = summary}), do: {:ok, summary}
  defp newest_worker_summary_result(_session_result, _issue_result), do: :error

  defp worker_summary_after?(%{} = candidate, %{} = current) do
    with %DateTime{} = candidate_time <- worker_summary_sort_time(candidate),
         %DateTime{} = current_time <- worker_summary_sort_time(current) do
      DateTime.compare(candidate_time, current_time) == :gt
    else
      _ -> false
    end
  end

  defp worker_summary_after?(_candidate, _current), do: false

  defp worker_summary_sort_time(%{} = summary) do
    (summary["ended_at"] || summary["started_at"])
    |> datetime_from_iso8601()
  end

  defp worker_summary_sort_time(_summary), do: nil

  defp latest_worker_summary_for_session(workspace, session_id)
       when is_binary(workspace) and is_binary(session_id) do
    path = Path.join(workspace, ".orocsy/delivery/token-telemetry/workers.jsonl")

    case File.read(path) do
      {:ok, content} ->
        summary =
          content
          |> String.split("\n", trim: true)
          |> Enum.reverse()
          |> Enum.find_value(fn line ->
            with {:ok, %{} = summary} <- Jason.decode(line),
                 true <- summary["worker_session_id"] == session_id do
              summary
            else
              _ -> nil
            end
          end)

        case summary do
          %{} = summary -> {:ok, summary}
          nil -> :error
        end

      {:error, _reason} ->
        :error
    end
  rescue
    _error -> :error
  end

  defp latest_worker_summary_for_session(_workspace, _session_id), do: :error

  defp latest_worker_summary_for_issue(workspace, running_entry)
       when is_binary(workspace) and is_map(running_entry) do
    path = Path.join(workspace, ".orocsy/delivery/token-telemetry/workers.jsonl")

    case File.read(path) do
      {:ok, content} ->
        summary =
          content
          |> String.split("\n", trim: true)
          |> Enum.reverse()
          |> Enum.find_value(fn line ->
            with {:ok, %{} = summary} <- Jason.decode(line),
                 true <- worker_summary_matches_running_entry?(summary, running_entry) do
              summary
            else
              _ -> nil
            end
          end)

        case summary do
          %{} = summary -> {:ok, summary}
          nil -> :error
        end

      {:error, _reason} ->
        :error
    end
  rescue
    _error -> :error
  end

  defp latest_worker_summary_for_issue(_workspace, _running_entry), do: :error

  defp accumulated_worker_summary_counted_tokens(workspace, running_entry, %{} = current_summary)
       when is_binary(workspace) and is_map(running_entry) do
    path = Path.join(workspace, ".orocsy/delivery/token-telemetry/workers.jsonl")
    thread_id = current_summary["thread_id"]

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reduce(0, fn line, total ->
          with {:ok, %{} = summary} <- Jason.decode(line),
               true <- summary["status"] == "blocked_no_durable_progress",
               true <- worker_summary_same_thread?(summary, thread_id),
               true <- worker_summary_matches_running_entry?(summary, running_entry),
               counted_tokens when is_integer(counted_tokens) <- integer_like(summary["counted_guard_tokens"]) do
            total + counted_tokens
          else
            _ -> total
          end
        end)

      {:error, _reason} ->
        0
    end
  rescue
    _error -> 0
  end

  defp accumulated_worker_summary_counted_tokens(_workspace, _running_entry, _current_summary), do: 0

  defp worker_summary_same_thread?(%{} = summary, thread_id) when is_binary(thread_id) and thread_id != "" do
    summary["thread_id"] == thread_id
  end

  defp worker_summary_same_thread?(%{} = summary, _thread_id) do
    is_binary(summary["worker_session_id"])
  end

  defp worker_summary_matches_running_entry?(%{} = summary, running_entry) do
    worker_summary_issue_matches?(summary, running_entry) and
      worker_summary_started_after_running_entry?(summary, running_entry)
  end

  defp worker_summary_matches_running_entry?(_summary, _running_entry), do: false

  defp worker_summary_issue_matches?(%{} = summary, running_entry) do
    issue = Map.get(running_entry, :issue)
    issue_id = if match?(%Issue{}, issue), do: issue.id
    identifier = Map.get(running_entry, :identifier)

    (is_binary(issue_id) and summary["linear_issue_id"] == issue_id) or
      (is_binary(identifier) and summary["issue"] == identifier)
  end

  defp worker_summary_started_after_running_entry?(%{"started_at" => started_at}, running_entry) do
    with %DateTime{} = summary_started <- datetime_from_iso8601(started_at),
         %DateTime{} = running_started <- Map.get(running_entry, :started_at) do
      DateTime.diff(summary_started, running_started, :second) >= -5
    else
      _ -> false
    end
  end

  defp worker_summary_started_after_running_entry?(_summary, _running_entry), do: false

  defp worker_summary_elapsed_ms(%{"started_at" => started_at, "ended_at" => ended_at}) do
    with %DateTime{} = started <- datetime_from_iso8601(started_at),
         %DateTime{} = ended <- datetime_from_iso8601(ended_at) do
      max(0, DateTime.diff(ended, started, :millisecond))
    else
      _ -> nil
    end
  end

  defp worker_summary_elapsed_ms(_summary), do: nil

  defp park_failed_issue(%State{} = state, issue_id, running_entry, reason, failure) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    workspace_path = Map.get(running_entry, :workspace_path)
    worker_host = Map.get(running_entry, :worker_host)
    issue = Map.get(running_entry, :issue)

    correction_result =
      if is_binary(workspace_path) do
        correction_attrs =
          %{
            source: "symphony.runtime.#{failure.kind}",
            source_status: failure.source_status,
            summary: failure.summary,
            findings: runtime_failure_findings(reason, running_entry),
            required_corrections: failure.required_corrections,
            next_action: failure.next_action
          }
          |> maybe_put_failure_guard(failure)

        Workspace.create_correction_in_workspace(
          workspace_path,
          issue || identifier,
          correction_attrs,
          worker_host
        )
      else
        {:error, :missing_workspace_path}
      end

    case correction_result do
      {:ok, correction} ->
        Logger.warning("Parked issue after worker failure: issue_id=#{issue_id} issue_identifier=#{identifier} correction=#{correction["correction_id"]} next_action=#{correction["next_action"]}")
        maybe_comment_runtime_failure(issue, correction, failure)

      {:error, correction_reason} ->
        Logger.warning("Unable to write Orocsy correction for issue_id=#{issue_id} issue_identifier=#{identifier}: #{inspect(correction_reason)}")
        maybe_comment_runtime_failure(issue, nil, failure)
    end

    state
    |> release_issue_claim(issue_id)
    |> Map.update!(:retry_attempts, &Map.delete(&1, issue_id))
  end

  defp maybe_put_failure_guard(attrs, %{guard: guard}) when is_map(guard), do: Map.put(attrs, :guard, guard)
  defp maybe_put_failure_guard(attrs, _failure), do: attrs

  defp runtime_failure_findings(reason, running_entry) do
    guard_reason = "Guard reason: #{failure_reason_text(reason)}"
    validation_findings = validation_failure_findings(running_entry)

    case Map.get(running_entry, :recent_codex_events, []) do
      events when is_list(events) and events != [] ->
        [
          "Recent Codex worker evidence:\n" <>
            (events
             |> Enum.take(-@recent_codex_update_limit)
             |> Enum.map_join("\n", &"- #{redact_runtime_evidence(&1)}")),
          validation_findings,
          guard_reason
        ]
        |> List.flatten()

      _ ->
        validation_findings ++ [guard_reason]
    end
  end

  defp validation_failure_findings(running_entry) do
    case validation_failure_for_guard(running_entry) do
      %{command: command, at: %DateTime{} = failed_at, evidence: evidence} ->
        [
          "Validation command failed: #{command}",
          "Validation failure observed at: #{DateTime.to_iso8601(failed_at)}",
          if(is_binary(evidence) and evidence != "", do: "Validation failure evidence: #{redact_runtime_evidence(evidence)}")
        ]
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp park_running_issue(%State{} = state, issue_id, running_entry, reason, failure) do
    state = terminate_running_issue(state, issue_id, false)
    park_failed_issue(state, issue_id, running_entry, reason, failure)
  end

  defp classify_agent_failure(reason) do
    text = failure_reason_text(reason)
    normalized = String.downcase(text)

    cond do
      provider_usage_limit_failure_text?(normalized) ->
        %{
          action: :block,
          kind: "provider-usage-limit",
          source_status: "blocked",
          next_action: "block",
          summary: "Symphony stopped because the Codex worker reported usageLimitExceeded before producing code/test progress or validation evidence.",
          required_corrections: [
            "Confirm Codex worker quota/credits are available for the same account/session used by Symphony.",
            "Resolve this runtime correction only after worker capacity is available, then redispatch through Symphony so the original product correction is implemented by a worker.",
            "Do not run validation-only retries, request review, or merge while this runtime correction and any original code/test correction remain open."
          ]
        }

      permission_or_input_failure?(normalized) ->
        %{
          action: :block,
          kind: "permission",
          source_status: "blocked",
          next_action: "block",
          summary: "Symphony stopped because the Codex worker requested approval, interactive input, or a command denied by the non-interactive automation guard.",
          required_corrections: [
            "Review the requested approval/input/forbidden command and decide whether the worker prompt or workflow config should allow a narrower safe path.",
            "Resolve this Orocsy correction before redispatching the issue."
          ]
        }

      token_budget_failure?(normalized) ->
        %{
          action: :block,
          kind: "token-budget",
          source_status: "blocked",
          next_action: "block",
          summary: "Symphony stopped a Codex worker after it exceeded the configured live turn token budget.",
          required_corrections: [
            "Inspect the workspace and latest worker messages for repeated context scans, missing stop conditions, or dirty validated work that only needs handoff.",
            "Commit, push, or trim the smallest safe checkpoint before redispatching."
          ]
        }

      transient_environment_failure?(normalized) ->
        %{
          action: :retry,
          kind: "environment",
          source_status: "retryable",
          next_action: "retry",
          summary: "Symphony hit a retryable environment, network, or provider failure while running the worker.",
          required_corrections: [
            "Verify network/provider availability and credentials.",
            "Resolve this Orocsy correction and redispatch when the environment is healthy."
          ]
        }

      true ->
        %{
          action: :retry,
          kind: "worker",
          source_status: "retryable",
          next_action: "block",
          summary: "Symphony worker exited unexpectedly and exceeded the safe retry policy.",
          required_corrections: [
            "Inspect the worker log and workspace state.",
            "Resolve this Orocsy correction after identifying the smallest safe recovery step."
          ]
        }
    end
  end

  defp maybe_recover_token_budget_handoff(%{kind: "token-budget"} = failure, running_entry) do
    if local_handoff_progress_for_recovery?(running_entry) do
      %{
        failure
        | action: :retry,
          kind: "token-budget-handoff",
          source_status: "retryable",
          next_action: "retry",
          summary:
            "Symphony stopped a Codex worker after it exceeded the configured live turn token budget, but the workspace contains fresh local handoff progress from this run. Symphony will retry once through a constrained handoff-recovery prompt instead of parking the issue as unfinished product work.",
          required_corrections: [
            "Resume from the existing workspace and inspect only the focused local diff/local commits first.",
            "Run focused validation for the changed files, then push the existing branch and update PR/Linear handoff before any broad rediscovery.",
            "If the next turn hits the token budget again without new local progress, park with a blocking correction."
          ]
      }
    else
      failure
    end
  end

  defp maybe_recover_token_budget_handoff(failure, _running_entry), do: failure

  defp maybe_recover_no_durable_progress_handoff(%{kind: "no-durable-progress"} = failure, running_entry) do
    if local_handoff_progress_for_recovery?(running_entry) do
      %{
        failure
        | action: :retry,
          kind: "no-durable-progress-handoff",
          source_status: "retryable",
          next_action: "retry",
          summary:
            "Symphony stopped a Codex worker after a quiet high-token period, but the workspace contains fresh local handoff progress from this run. Symphony will retry through the constrained dirty-handoff prompt instead of treating the issue as unfinished product work.",
          required_corrections: [
            "Resume from the existing workspace and inspect only the focused local diff/local commits first.",
            "Run focused validation for the changed files, then push the existing branch and update PR/Linear handoff before any broad rediscovery.",
            "If the next turn hits the durable-progress guard again without new local progress, park with a blocking correction."
          ]
      }
    else
      failure
    end
  end

  defp maybe_recover_no_durable_progress_handoff(failure, _running_entry), do: failure

  defp local_handoff_progress_for_recovery?(running_entry) do
    fresh_local_handoff_progress?(running_entry) or
      stale_handoff_recovery_retry_available?(running_entry)
  end

  defp stale_handoff_recovery_retry_available?(%{workspace_path: workspace} = running_entry) when is_binary(workspace) do
    handoff_recovery_progress_observed?(running_entry) and
      not handoff_recovery_retry_attempted_after_local_progress?(workspace)
  rescue
    _error -> false
  end

  defp stale_handoff_recovery_retry_available?(_running_entry), do: false

  defp fresh_local_handoff_progress?(%{workspace_path: workspace, started_at: %DateTime{} = started_at})
       when is_binary(workspace) do
    File.dir?(workspace) and git_substantive_progress_times(workspace, started_at) != []
  rescue
    _error -> false
  end

  defp fresh_local_handoff_progress?(_running_entry), do: false

  defp handoff_recovery_retry_attempted_after_local_progress?(workspace) when is_binary(workspace) do
    with %DateTime{} = progress_at <- local_handoff_progress_observed_at(workspace) do
      workspace
      |> handoff_recovery_correction_created_times()
      |> Enum.any?(&datetime_at_or_after?(&1, progress_at))
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp local_handoff_progress_observed_at(workspace) do
    [
      meaningful_git_dirty_observed_at(workspace),
      git_ahead_commit_observed_at(workspace),
      git_upstream_progress_observed_at(workspace)
    ]
    |> Enum.reject(&is_nil/1)
    |> latest_datetime()
  end

  defp handoff_recovery_correction_created_times(workspace) do
    workspace
    |> Path.join(".orocsy/delivery/inbox/correction_*.json")
    |> Path.wildcard()
    |> Enum.flat_map(&handoff_recovery_correction_created_time/1)
  end

  defp handoff_recovery_correction_created_time(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = correction} <- Jason.decode(body),
         true <- handoff_recovery_correction?(correction),
         %DateTime{} = created_at <- correction |> Map.get("created_at") |> datetime_from_iso8601() do
      [created_at]
    else
      _ -> []
    end
  end

  defp handoff_recovery_correction?(%{} = correction) do
    source = correction["source"] || ""
    kind = correction["kind"] || ""

    String.contains?(source, "no-durable-progress-handoff") or
      String.contains?(source, "token-budget-handoff") or
      String.ends_with?(kind, "-handoff")
  end

  defp handoff_recovery_correction?(_correction), do: false

  defp no_durable_progress_failure(
         elapsed_ms,
         quiet_ms,
         total_tokens,
         durable_progress_guard_tokens,
         cached_input_tokens,
         timeout_ms,
         min_tokens
       ) do
    %{
      action: :block,
      kind: "no-durable-progress",
      source_status: "blocked",
      next_action: "block",
      summary:
        "Symphony stopped a Codex worker because it used #{durable_progress_guard_tokens} counted tokens over #{elapsed_ms}ms and had no recent durable progress for #{quiet_ms}ms. Total reported tokens were #{total_tokens}, including #{cached_input_tokens} cached input tokens. High token usage is allowed when the worker continues to produce dirty files, commits, or passed MIU/gate evidence; this guard only parks the high-token/no-recent-progress case.",
      required_corrections: [
        "Inspect the workspace and worker log to confirm whether the turn was rediscovering context, blocked on hidden tool state, or missing a code-level MIU handoff.",
        "Add or refresh a Technical MIU handoff with current file paths, target code shape, data lifetime, concurrency rule, exact tests, and validation commands before redispatching.",
        "If the worker actually produced useful local work that was not visible to the watchdog, commit or record the durable evidence before resolving the correction."
      ],
      guard: %{
        elapsed_ms: elapsed_ms,
        quiet_ms: quiet_ms,
        total_tokens: total_tokens,
        durable_progress_guard_tokens: durable_progress_guard_tokens,
        cached_input_tokens: cached_input_tokens,
        timeout_ms: timeout_ms,
        min_tokens: min_tokens
      }
    }
  end

  defp validation_blocker_failure(
         %{command: command, at: %DateTime{} = failed_at, evidence: evidence},
         elapsed_ms,
         quiet_ms,
         total_tokens,
         durable_progress_guard_tokens,
         cached_input_tokens,
         timeout_ms,
         min_tokens
       ) do
    %{
      action: :retry,
      kind: "validation-blocker",
      source_status: "retryable",
      next_action: "retry",
      summary:
        "Symphony stopped a Codex worker because validation command `#{command}` failed and the worker did not record a durable Orocsy validation blocker before the runtime progress guard fired.",
      required_corrections: [
        "Redispatch a bounded worker from the failed validation command and evidence; inspect only the files needed to explain that failure before editing.",
        "Fix the smallest product or workflow issue that makes `#{command}` pass, or record a scoped validation.blocker event if the failure belongs to another ticket.",
        "Do not treat this as dirty-handoff/no-progress recovery; the latest durable signal is the failed validation command."
      ],
      guard: %{
        failed_at: DateTime.to_iso8601(failed_at),
        command: command,
        evidence: truncate_runtime_evidence(evidence || "", 1_000),
        elapsed_ms: elapsed_ms,
        quiet_ms: quiet_ms,
        total_tokens: total_tokens,
        durable_progress_guard_tokens: durable_progress_guard_tokens,
        cached_input_tokens: cached_input_tokens,
        timeout_ms: timeout_ms,
        min_tokens: min_tokens
      }
    }
  end

  defp missing_first_durable_event_failure(
         elapsed_ms,
         total_tokens,
         first_event_progress_tokens,
         first_event_max_tokens,
         cached_input_tokens
       ) do
    %{
      action: :block,
      kind: "missing-first-durable-event",
      source_status: "blocked",
      next_action: "block",
      summary:
        "Symphony stopped a Codex worker because it used #{first_event_progress_tokens} counted tokens before recording the first durable Orocsy progress event. Total reported tokens were #{total_tokens}, including #{cached_input_tokens} cached input tokens. Creating an issue branch or recording first-turn-miu-handoff/technical-miu-trace only proves the worker is alive; workers must produce scoped file progress, a commit, a focused test/gate/eval result, review classification, or a blocker classification before the first-event token budget is exhausted.",
      required_corrections: [
        "Inspect the worker log to confirm why it did not record real durable progress before broad context reads or implementation work.",
        "Shrink the first-turn prompt or workflow instructions, or make the worker record a blocker event when the issue shape is unclear.",
        "Redispatch only after the first durable event can be recorded before expensive code/doc exploration."
      ],
      guard: %{
        elapsed_ms: elapsed_ms,
        total_tokens: total_tokens,
        first_event_progress_tokens: first_event_progress_tokens,
        cached_input_tokens: cached_input_tokens,
        first_event_max_tokens: first_event_max_tokens
      }
    }
  end

  defp failure_retry_exhausted(failure, next_attempt) do
    %{
      failure
      | source_status: "retry-exhausted",
        summary:
          "#{failure.summary} The worker reached retry attempt #{next_attempt}, which exceeds agent.max_failed_worker_retries=#{Config.settings!().agent.max_failed_worker_retries}; Symphony is parking the issue instead of spending more tokens."
    }
  end

  defp permission_or_input_failure?(text) do
    String.contains?(text, [
      "approval_required",
      "turn_input_required",
      "mcp_elicitation",
      "elicitation/request",
      "forbidden_command",
      "permission denied",
      "requires approval"
    ])
  end

  defp token_budget_failure?(text) do
    String.contains?(text, "turn_token_budget_exceeded")
  end

  defp provider_usage_limit_failure?(reason) do
    reason
    |> failure_reason_text()
    |> String.downcase()
    |> provider_usage_limit_failure_text?()
  end

  defp provider_usage_limit_failure_text?(text) do
    String.contains?(text, [
      "usagelimitexceeded",
      "usage limit",
      "has_credits\":false",
      "has_credits\" => false",
      "balance\":\"0",
      "balance\" => \"0"
    ])
  end

  defp transient_environment_failure?(text) do
    String.contains?(text, [
      "turn_timeout",
      "response_timeout",
      "port_exit",
      "linear_api_request",
      "timeout",
      "timed out",
      "network",
      "econn",
      "nxdomain",
      "could not resolve",
      "connection refused",
      "failed to set up container"
    ])
  end

  defp maybe_comment_runtime_failure(%Issue{id: issue_id} = issue, correction, failure)
       when is_binary(issue_id) do
    body = runtime_failure_comment(issue, correction, failure)

    case Tracker.create_comment(issue_id, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Unable to add Linear runtime blocker comment for #{issue_context(issue)}: #{inspect(reason)}")
    end
  end

  defp maybe_comment_runtime_failure(_issue, _correction, _failure), do: :ok

  defp runtime_failure_comment(issue, correction, failure) do
    correction_line =
      case correction do
        %{"artifacts" => %{"markdown" => path}, "correction_id" => correction_id} ->
          "- Orocsy correction: `#{correction_id}` at `#{path}`"

        _ ->
          "- Orocsy correction: not written; inspect the Symphony supervisor log."
      end

    evidence = runtime_failure_evidence_block(correction)

    """
    Symphony runtime parked this issue because a worker hit a configured failure guard.

    - Issue: `#{issue.identifier}`
    - Runtime class: `#{failure.kind}`
    - Status: `#{failure.source_status}`
    - Next action: `#{failure.next_action}`
    #{correction_line}

    #{evidence}

    #{failure.summary}
    """
    |> String.trim()
  end

  defp runtime_failure_evidence_block(%{"findings" => [finding | _]}) when is_binary(finding) do
    evidence =
      finding
      |> redact_runtime_evidence()
      |> truncate_runtime_evidence()

    """
    <details>
    <summary>Runtime evidence</summary>

    ```text
    #{evidence}
    ```
    </details>
    """
    |> String.trim()
  end

  defp runtime_failure_evidence_block(_correction), do: ""

  defp redact_runtime_evidence(value) when is_binary(value) do
    value
    |> redact_pattern(Regex.compile!(("lin" <> "_api_") <> "[A-Za-z0-9]+"), ("lin" <> "_api_") <> "[REDACTED]")
    |> redact_pattern(Regex.compile!("gh[pousr]_[A-Za-z0-9_]+"), "gh_[REDACTED]")
    |> redact_pattern(Regex.compile!(("sk" <> "_") <> "(live|test)_[A-Za-z0-9]+"), ("sk" <> "_") <> "\\1_[REDACTED]")
    |> redact_assignment("OPENAI" <> "_API" <> "_KEY")
    |> redact_assignment("LINEAR" <> "_API" <> "_KEY")
    |> redact_assignment("GITHUB" <> "_TOKEN")
    |> redact_assignment("GH" <> "_TOKEN")
  end

  defp redact_pattern(value, regex, replacement) do
    Regex.replace(regex, value, replacement)
  end

  defp redact_assignment(value, name) do
    Regex.replace(Regex.compile!("(" <> Regex.escape(name) <> ")=\\S+"), value, "\\1=[REDACTED]")
  end

  defp truncate_runtime_evidence(value, max_bytes \\ 2_000)

  defp truncate_runtime_evidence(value, max_bytes) when is_binary(value) and byte_size(value) > max_bytes do
    binary_part(value, 0, max_bytes) <> "... (truncated)"
  end

  defp truncate_runtime_evidence(value, _max_bytes), do: value

  defp failure_reason_text(reason) do
    reason
    |> inspect(limit: 50, printable_limit: 4_000)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          codex_cached_input_tokens: Map.get(metadata, :codex_cached_input_tokens, 0),
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_cached_input_tokens = Map.get(running_entry, :codex_cached_input_tokens, 0)
    codex_initial_uncached_input_tokens = initial_uncached_input_tokens(running_entry, token_delta)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    last_reported_cached_input = Map.get(running_entry, :codex_last_reported_cached_input_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    previous_validation_command = Map.get(running_entry, :last_validation_command)
    detected_command = command_from_codex_update(update)

    validation_command =
      cond do
        validation_command?(detected_command) -> detected_command
        is_binary(detected_command) -> nil
        true -> previous_validation_command
      end

    validation_success_at = validation_progress_timestamp(update, validation_command)

    validation_progress_at =
      validation_success_at ||
        Map.get(running_entry, :last_validation_progress_at)

    validation_failure =
      cond do
        failure = validation_failure_snapshot(update, validation_command) ->
          failure

        validation_success_at != nil ->
          nil

        true ->
          validation_failure_from_running(running_entry)
      end

    validation_failure_at = if validation_failure, do: validation_failure.at
    validation_failure_command = if validation_failure, do: validation_failure.command
    validation_failure_evidence = if validation_failure, do: validation_failure.evidence

    recent_codex_events =
      running_entry
      |> Map.get(:recent_codex_events, [])
      |> append_recent_codex_event(update, previous_validation_command)

    {last_codex_timestamp, last_codex_message, last_codex_event} =
      if display_codex_update?(update) do
        {timestamp, summarize_codex_update(update), event}
      else
        {
          Map.get(running_entry, :last_codex_timestamp),
          Map.get(running_entry, :last_codex_message),
          Map.get(running_entry, :last_codex_event)
        }
      end

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: last_codex_timestamp,
        last_codex_message: last_codex_message,
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: last_codex_event,
        last_validation_command: validation_command,
        last_validation_progress_at: validation_progress_at,
        last_validation_failure_at: validation_failure_at,
        last_validation_failure_command: validation_failure_command,
        last_validation_failure_evidence: validation_failure_evidence,
        recent_codex_events: recent_codex_events,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_cached_input_tokens: codex_cached_input_tokens + token_delta.cached_input_tokens,
        codex_initial_uncached_input_tokens: codex_initial_uncached_input_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        codex_last_reported_cached_input_tokens: max(last_reported_cached_input, token_delta.cached_input_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp append_recent_codex_event(events, update, previous_validation_command) when is_list(events) do
    case recent_codex_event_summary(update, previous_validation_command) do
      nil -> events
      summary -> Enum.take(events ++ [summary], -@recent_codex_update_limit)
    end
  end

  defp append_recent_codex_event(_events, update, previous_validation_command) do
    append_recent_codex_event([], update, previous_validation_command)
  end

  defp initial_uncached_input_tokens(running_entry, token_delta) do
    existing = Map.get(running_entry, :codex_initial_uncached_input_tokens, 0)

    cond do
      is_integer(existing) and existing > 0 ->
        existing

      is_integer(token_delta.input_reported) and token_delta.input_reported > 0 ->
        cached_input = if is_integer(token_delta.cached_input_reported), do: token_delta.cached_input_reported, else: 0
        max(token_delta.input_reported - cached_input, 0)

      true ->
        0
    end
  end

  defp recent_codex_event_summary(update, previous_validation_command) when is_map(update) do
    command = command_from_codex_update(update) || previous_validation_command
    text = compact_codex_update_text(update)
    event = update[:event] || Map.get(update, "event")
    timestamp = update[:timestamp] || Map.get(update, "timestamp")
    outcome = codex_update_outcome(text)

    cond do
      is_nil(command) and is_nil(outcome) and not errorish_text?(text) ->
        nil

      true ->
        [
          timestamp_to_text(timestamp),
          "event=#{event || "unknown"}",
          if(command, do: "command=#{command}", else: nil),
          outcome,
          if(errorish_text?(text), do: "detail=#{truncate_runtime_evidence(text, 320)}", else: nil)
        ]
        |> Enum.reject(&blank_recent_part?/1)
        |> Enum.join(" ")
    end
  end

  defp recent_codex_event_summary(_update, _previous_validation_command), do: nil

  defp validation_progress_timestamp(%{timestamp: %DateTime{} = timestamp} = update, command) when is_binary(command) do
    if validation_command?(command) and codex_update_success?(compact_codex_update_text(update)) do
      timestamp
    end
  end

  defp validation_progress_timestamp(update, command) when is_binary(command) do
    if validation_command?(command) and codex_update_success?(compact_codex_update_text(update)) do
      DateTime.utc_now()
    end
  end

  defp validation_progress_timestamp(_update, _command), do: nil

  defp validation_failure_snapshot(update, command) when is_binary(command) do
    text = compact_codex_update_text(update)

    if validation_command?(command) and codex_update_failure?(text) do
      %{
        at: codex_update_timestamp(update),
        command: command,
        evidence: truncate_runtime_evidence(text, 1_000)
      }
    end
  end

  defp validation_failure_snapshot(_update, _command), do: nil

  defp validation_failure_from_running(running_entry) do
    case Map.get(running_entry, :last_validation_failure_at) do
      %DateTime{} = at ->
        %{
          at: at,
          command:
            Map.get(running_entry, :last_validation_failure_command) ||
              Map.get(running_entry, :last_validation_command) ||
              "unknown validation command",
          evidence: Map.get(running_entry, :last_validation_failure_evidence)
        }

      _ ->
        nil
    end
  end

  defp codex_update_timestamp(%{timestamp: %DateTime{} = timestamp}), do: timestamp
  defp codex_update_timestamp(%{"timestamp" => %DateTime{} = timestamp}), do: timestamp
  defp codex_update_timestamp(_update), do: DateTime.utc_now()

  defp validation_command?(command) when is_binary(command) do
    normalized = String.downcase(command)

    String.match?(
      normalized,
      ~r/(^|\s)(pnpm|npm|yarn|bun|mix|npx|corepack)\b.*\b(test|typecheck|type-check|check|lint|build|eslint|tsc|vitest|jest|playwright|credo|dialyzer)\b/
    ) or
      String.match?(normalized, ~r/\b(tsc|eslint|vitest|jest|playwright|mix test|next\s+build)\b/)
  end

  defp validation_command?(_command), do: false

  defp codex_update_success?(text) when is_binary(text) do
    String.match?(text, ~r/(exit[_ ]?(code|status)|status)[\"':\s]+0\b/i) or
      String.match?(text, ~r/process exited with code 0/i) or
      (String.match?(text, ~r/\b(success|passed|completed)\b/i) and not errorish_text?(text))
  end

  defp codex_update_success?(_text), do: false

  defp codex_update_failure?(text) when is_binary(text) do
    not codex_update_success?(text) and
      (String.match?(text, ~r/(exit[_ ]?(code|status)|status)[\"':\s]+(1|2|126|127|128)\b/i) or
         String.match?(text, ~r/process exited with code [1-9]\d*/i) or
         errorish_text?(text))
  end

  defp codex_update_failure?(_text), do: false

  defp codex_update_outcome(text) when is_binary(text) do
    cond do
      codex_update_success?(text) -> "outcome=passed"
      String.match?(text, ~r/(exit[_ ]?(code|status)|status)[\"':\s]+(1|2|126|127|128)\b/i) -> "outcome=failed"
      String.match?(text, ~r/process exited with code [1-9]\d*/i) -> "outcome=failed"
      errorish_text?(text) -> "outcome=error"
      true -> nil
    end
  end

  defp codex_update_outcome(_text), do: nil

  defp command_from_codex_update(update) when is_map(update) do
    update
    |> codex_update_payload_candidates()
    |> Enum.find_value(fn payload ->
      [
        map_path(payload, ["params", "msg", "command"]),
        map_path(payload, ["params", "command"]),
        map_path(payload, ["params", "parsedCmd"]),
        map_path(payload, ["params", "cmd"]),
        map_path(payload, ["params", "item", "command"]),
        map_path(payload, ["params", "item", "parsedCmd"]),
        payload |> map_path(["params", "payload"]) |> function_call_command_text(),
        payload |> map_path(["params", "item", "payload"]) |> function_call_command_text(),
        payload |> map_path(["params", "msg", "payload"]) |> function_call_command_text(),
        function_call_command_text(payload)
      ]
      |> Enum.find_value(&normalize_runtime_command/1)
    end)
  end

  defp command_from_codex_update(_update), do: nil

  defp codex_update_payload_candidates(update) when is_map(update) do
    update
    |> do_codex_update_payload_candidates([])
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp do_codex_update_payload_candidates(%{} = payload, seen) do
    if Enum.any?(seen, &(&1 === payload)) do
      seen
    else
      nested_payloads =
        [
          map_path(payload, ["payload"]),
          map_path(payload, ["details"]),
          map_path(payload, ["params"]),
          map_path(payload, ["params", "payload"]),
          map_path(payload, ["params", "msg"]),
          map_path(payload, ["params", "msg", "payload"]),
          map_path(payload, ["params", "item"]),
          map_path(payload, ["params", "item", "payload"])
        ]
        |> Enum.filter(&is_map/1)

      Enum.reduce(nested_payloads, [payload | seen], &do_codex_update_payload_candidates/2)
    end
  end

  defp do_codex_update_payload_candidates(_payload, seen), do: seen

  defp function_call_command_text(%{"type" => "function_call", "name" => name} = item) when is_binary(name) do
    if name == "exec_command" or String.ends_with?(name, ".exec_command") do
      item
      |> Map.get("arguments")
      |> decode_function_arguments()
      |> command_from_function_arguments()
    end
  end

  defp function_call_command_text(_item), do: nil

  defp decode_function_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{"cmd" => arguments}
    end
  end

  defp decode_function_arguments(%{} = arguments), do: arguments
  defp decode_function_arguments(_arguments), do: nil

  defp command_from_function_arguments(%{} = arguments), do: map_value(arguments, ["cmd", "command", "parsedCmd"])
  defp command_from_function_arguments(_arguments), do: nil

  defp normalize_runtime_command(%{} = command) do
    binary_command = map_value(command, ["parsedCmd", "command", "cmd"])
    args = map_value(command, ["args", "argv"])

    cond do
      is_binary(binary_command) and is_list(args) -> normalize_runtime_command([binary_command | args])
      is_binary(binary_command) -> normalize_runtime_command(binary_command)
      is_list(args) -> normalize_runtime_command(args)
      true -> nil
    end
  end

  defp normalize_runtime_command(command) when is_binary(command) do
    command
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_runtime_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      command
      |> Enum.join(" ")
      |> normalize_runtime_command()
    end
  end

  defp normalize_runtime_command(_command), do: nil

  defp compact_codex_update_text(update) do
    update
    |> inspect(limit: 80, printable_limit: 1_600)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp errorish_text?(text) when is_binary(text) do
    String.match?(text, ~r/\b(error|failed|failure|fatal|panic|exception|unauthorized|forbidden|permission denied|command not found|not found|timed out|timeout)\b/i)
  end

  defp errorish_text?(_text), do: false

  defp timestamp_to_text(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp timestamp_to_text(timestamp) when is_binary(timestamp), do: timestamp
  defp timestamp_to_text(_timestamp), do: "unknown-time"

  defp blank_recent_part?(part), do: is_nil(part) or part == ""

  defp map_path(value, []), do: value

  defp map_path(%{} = map, [key | rest]) when is_binary(key) do
    case fetch_map_key(map, key) do
      {:ok, value} -> map_path(value, rest)
      :error -> nil
    end
  end

  defp map_path(_value, _path), do: nil

  defp map_value(%{} = map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      case fetch_map_key(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp map_value(_map, _keys), do: nil

  defp fetch_map_key(%{} = map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Map.fetch(map, String.to_atom(key))
    end
  end

  defp fetch_map_key(%{} = map, key), do: Map.fetch(map, key)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp display_codex_update?(%{} = update) do
    payload = update[:payload] || Map.get(update, "payload") || update

    cond do
      background_plugin_warning?(payload) -> false
      benign_mcp_startup_status?(payload) -> false
      true -> true
    end
  end

  defp display_codex_update?(_update), do: true

  defp background_plugin_warning?(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)
    level = Map.get(payload, "level") || Map.get(payload, :level)
    level_text = if is_binary(level) or is_atom(level), do: to_string(level), else: ""
    warning? = method in ["warning", :warning] or String.match?(level_text, ~r/^warn/i)

    warning? and
      payload
      |> inspect(limit: 80, printable_limit: 2_000)
      |> String.match?(~r/(failed to warm featured plugin ids cache|plugins\/featured|ignoring interface\.defaultPrompt)/i)
  end

  defp background_plugin_warning?(_payload), do: false

  defp benign_mcp_startup_status?(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    method == "mcpServer/startupStatus/updated" and not errorish_payload?(payload)
  end

  defp benign_mcp_startup_status?(_payload), do: false

  defp errorish_payload?(payload) do
    payload
    |> inspect(limit: 80, printable_limit: 2_000)
    |> String.match?(~r/\b(error|failed|failure|fatal|panic|exception|unauthorized|forbidden)\b/i)
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp normal_completion_handoff_stop?(%{workspace_path: workspace}) when is_binary(workspace) do
    case DispatchPreflight.read(workspace) do
      {:ok, %{"mode" => mode}} when mode in ["review_rework", "integration_check", "handoff_recovery"] ->
        pushed_validated_handoff_stop?(workspace) or review_classification_handoff_stop?(workspace)

      _ ->
        false
    end
  rescue
    _error -> false
  end

  defp normal_completion_handoff_stop?(_running_entry), do: false

  defp pushed_validated_handoff_stop?(workspace) when is_binary(workspace) do
    workspace
    |> PromptBuilder.workspace_recovery_checkpoint()
    |> String.starts_with?("Pushed validated handoff checkpoint:")
  end

  defp pushed_validated_handoff_stop?(_workspace), do: false

  defp review_classification_handoff_stop?(workspace) when is_binary(workspace) do
    with {:ok, classification} <- read_review_classification_handoff(workspace),
         {:ok, dirty_status} <- git_output(workspace, ["status", "--porcelain=v1"]),
         true <- String.trim(dirty_status) == "",
         {:ok, head_sha} <- git_output(workspace, ["rev-parse", "HEAD"]),
         true <- classification_head_matches?(classification, String.trim(head_sha)) do
      no_code_review_classification?(classification) and resolved_review_classification?(classification)
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp review_classification_handoff_stop?(_workspace), do: false

  defp pushed_handoff_wait_checkpoint?(%{workspace_path: workspace} = running_entry) when is_binary(workspace) do
    normal_completion_handoff_stop?(running_entry) and pushed_handoff_review_request_recorded?(workspace)
  rescue
    _error -> false
  end

  defp pushed_handoff_wait_checkpoint?(_running_entry), do: false

  defp review_request_wait_checkpoint?(%{issue: %Issue{} = issue, workspace_path: workspace})
       when is_binary(workspace) do
    with {:ok, %{"mode" => "review_rework"}} <- DispatchPreflight.read(workspace),
         %{enabled: true} = monitor <- handoff_review_monitor(workspace) do
      review_request_pending_for_issue?(issue, monitor)
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp review_request_wait_checkpoint?(_running_entry), do: false

  defp workflow_blocked_by_open_correction?(issue_or_running_entry, metadata \\ %{})

  defp workflow_blocked_by_open_correction?(%Issue{} = issue, metadata) when is_map(metadata) do
    issue
    |> correction_block_check_targets(metadata)
    |> Enum.any?(&correction_block_check_target_blocked?/1)
  end

  defp workflow_blocked_by_open_correction?(%{issue: %Issue{} = issue} = running_entry, _metadata) do
    workflow_blocked_by_open_correction?(issue, %{
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  defp workflow_blocked_by_open_correction?(%{identifier: identifier} = running_entry, _metadata)
       when is_binary(identifier) do
    metadata = %{
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    }

    identifier
    |> correction_block_check_targets(metadata)
    |> Enum.any?(&correction_block_check_target_blocked?/1)
  end

  defp workflow_blocked_by_open_correction?(_issue_or_running_entry, _metadata), do: false

  defp workflow_blocked_by_non_dispatchable_correction?(issue_or_running_entry, metadata \\ %{})

  defp workflow_blocked_by_non_dispatchable_correction?(%{issue: %Issue{} = issue} = running_entry, _metadata) do
    metadata = %{
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    }

    workflow_blocked_by_open_correction?(issue, metadata) and
      not workflow_correction_gate_allows_dispatch?(issue, metadata)
  end

  defp workflow_blocked_by_non_dispatchable_correction?(%{identifier: identifier} = running_entry, _metadata)
       when is_binary(identifier) do
    metadata = %{
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    }

    workflow_blocked_by_open_correction?(identifier, metadata) and
      not workflow_correction_gate_allows_dispatch?(identifier, metadata)
  end

  defp workflow_blocked_by_non_dispatchable_correction?(issue_or_identifier, metadata) do
    workflow_blocked_by_open_correction?(issue_or_identifier, metadata) and
      not workflow_correction_gate_allows_dispatch?(issue_or_identifier, metadata)
  end

  defp workflow_correction_gate_allows_dispatch?(issue_or_identifier, metadata \\ %{})

  defp workflow_correction_gate_allows_dispatch?(issue_or_identifier, metadata) when is_map(metadata) do
    blocked_targets =
      issue_or_identifier
      |> correction_block_check_targets(metadata)
      |> Enum.filter(&correction_block_check_target_blocked?/1)

    blocked_targets == [] or Enum.all?(blocked_targets, &correction_block_check_target_dispatchable_retry?/1)
  end

  defp workflow_correction_gate_allows_dispatch?(_issue_or_identifier, _metadata), do: true

  defp correction_block_check_targets(issue_or_identifier, metadata) when is_map(metadata) do
    worker_host = normalize_worker_host(Map.get(metadata, :worker_host))
    workspace_path = normalize_workspace_path(Map.get(metadata, :workspace_path))

    cond do
      is_binary(workspace_path) ->
        [{:workspace, workspace_path, worker_host}]

      is_binary(worker_host) ->
        [{:issue, issue_or_identifier, worker_host}]

      true ->
        Config.settings!().worker.ssh_hosts
        |> Enum.map(&normalize_worker_host/1)
        |> Enum.reject(&is_nil/1)
        |> then(&[nil | &1])
        |> Enum.uniq()
        |> Enum.map(&{:issue, issue_or_identifier, &1})
    end
  end

  defp correction_block_check_target_blocked?({:workspace, workspace_path, worker_host}) do
    Workspace.blocking_correction_in_workspace?(workspace_path, worker_host)
  end

  defp correction_block_check_target_blocked?({:issue, issue_or_identifier, worker_host}) do
    Workspace.blocking_correction_for_issue?(issue_or_identifier, worker_host)
  end

  defp correction_block_check_target_dispatchable_retry?({:workspace, workspace_path, nil}) do
    workspace_path
    |> Workspace.open_blocking_corrections_in_workspace()
    |> dispatchable_retry_corrections?()
  rescue
    _error -> false
  end

  defp correction_block_check_target_dispatchable_retry?({:issue, issue_or_identifier, nil}) do
    with {:ok, workspace_path} <- Workspace.path_for_issue(issue_or_identifier, nil) do
      correction_block_check_target_dispatchable_retry?({:workspace, workspace_path, nil})
    else
      _ -> false
    end
  end

  defp correction_block_check_target_dispatchable_retry?(_target), do: false

  defp dispatchable_retry_corrections?(corrections) when is_list(corrections) do
    corrections != [] and Enum.all?(corrections, &dispatchable_retry_correction?/1)
  end

  defp dispatchable_retry_corrections?(_corrections), do: false

  defp dispatchable_retry_correction?(%{} = correction) do
    normalize_correction_value(correction["status"]) == "open" and
      normalize_correction_value(correction["next_action"]) == "retry" and
      is_nil(correction["resolved_at"]) and
      actionable_code_or_test_correction?(correction)
  end

  defp dispatchable_retry_correction?(_correction), do: false

  defp actionable_code_or_test_correction?(%{} = correction) do
    text =
      [
        correction["summary"],
        correction["findings"],
        correction["required_corrections"]
      ]
      |> correction_string_values()
      |> Enum.join(" ")
      |> String.downcase()

    Regex.match?(~r{\b(?:src|app|apps|packages|lib|tests)/[a-z0-9_\-./\[\]]+\.(?:ts|tsx|js|jsx|mjs|cjs|css|scss|json|md)\b}, text) and
      Regex.match?(~r/\b(edit|fix|change|modify|update|implement|rerun|run|test|validation|failure|failed|error)\b/, text)
  end

  defp actionable_code_or_test_correction?(_correction), do: false

  defp correction_string_values(values) when is_list(values), do: Enum.flat_map(values, &correction_string_values/1)
  defp correction_string_values(value) when is_binary(value), do: [value]
  defp correction_string_values(_value), do: []

  defp normalize_correction_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_correction_value(_value), do: ""

  defp normalize_worker_host(worker_host) when is_binary(worker_host) do
    case String.trim(worker_host) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_worker_host(_worker_host), do: nil

  defp normalize_workspace_path(workspace_path) when is_binary(workspace_path) do
    case String.trim(workspace_path) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_workspace_path(_workspace_path), do: nil

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      ),
      compute_token_delta(
        running_entry,
        :cached_input,
        usage,
        :codex_last_reported_cached_input_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total, cached_input] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        cached_input_tokens: cached_input.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported,
        cached_input_reported: cached_input.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp get_token_usage(usage, :cached_input),
    do:
      payload_get(usage, [
        "cached_input_tokens",
        :cached_input_tokens,
        "cachedInputTokens",
        :cachedInputTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
