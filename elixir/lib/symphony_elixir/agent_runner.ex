defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, DispatchPreflight, Linear.Issue, PromptBuilder, ReviewMonitor, Tracker, Workspace}

  @delivery_event_path ".orocsy/delivery/events/events.jsonl"
  @review_classification_path ".orocsy/delivery/state/review-feedback-classified.json"

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
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host),
               {:ok, _preflight} <- maybe_prepare_dispatch_preflight(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
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
    def review_classification_handoff_stop_for_test(workspace), do: review_classification_handoff_stop?(workspace)
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

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns, worker_host)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns, worker_host) do
    prompt = build_turn_prompt(issue, opts, workspace, turn_number, max_turns)
    checkpoint_present_at_turn_start = fresh_implementation_checkpoint_present?(workspace)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      if fresh_checkpoint_stop_completed?(turn_session, workspace, checkpoint_present_at_turn_start) do
        Logger.info("Stopping agent run for #{issue_context(issue)} after fresh implementation checkpoint; returning control to orchestrator")
        :ok
      else
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

      pushed_handoff_stop?(workspace) ->
        Logger.info("Stopping agent run for #{issue_context(issue)} after pushed validated handoff; returning control to orchestrator")
        {:done, issue}

      review_classification_handoff_stop?(workspace) ->
        Logger.info("Stopping agent run for #{issue_context(issue)} after no-code review classification handoff; returning control to orchestrator")
        {:done, issue}

      true ->
        continue_with_issue?(issue, issue_state_fetcher)
    end
  end

  defp pushed_handoff_stop?(workspace) do
    case DispatchPreflight.read(workspace) do
      {:ok, %{"mode" => mode}} when mode in ["review_rework", "integration_check"] ->
        workspace
        |> PromptBuilder.workspace_recovery_checkpoint()
        |> String.starts_with?("Pushed validated handoff checkpoint:")

      _ ->
        false
    end
  end

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
    with {:ok, %{"mode" => "fresh_implementation"}} <- DispatchPreflight.read(workspace) do
      technical_miu_trace_event?(workspace) and meaningful_git_progress?(workspace)
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp fresh_implementation_checkpoint_present?(_workspace), do: false

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
      - If the workspace is dirty or ahead and recent validation/gate events passed, treat that as a dirty handoff checkpoint. Run only `git status --short --branch`, `git diff --stat`, and a focused `git diff -- <dirty-file>` read, then run the smallest focused validation for the dirty files before any additional product edit, broad scan, or validation rerun.
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

    if is_binary(worker_host) and review_feedback_requires_local_worker?(issue) do
      Logger.info("Routing #{issue_context(issue)} to local worker because current review feedback requires dispatch preflight")
      nil
    else
      worker_host
    end
  end

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
