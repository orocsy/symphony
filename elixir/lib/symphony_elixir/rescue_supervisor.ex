defmodule SymphonyElixir.RescueSupervisor do
  @moduledoc """
  Performs bounded rescue triage for parked Orocsy corrections.
  """

  require Logger

  alias SymphonyElixir.{Config, IssueRequirements, ReviewMonitor, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue

  @hydrated_retry_loop_limit 2
  @review_rework_loop_limit 2
  @worker_prompt_fix_version "runtime-review-rework-observable-validation-policy-v15"

  @spec run_once([Issue.t()]) :: {:ok, MapSet.t(String.t())}
  def run_once(issues) when is_list(issues) do
    rescued =
      issues
      |> Enum.flat_map(&rescue_issue/1)
      |> MapSet.new()

    {:ok, rescued}
  end

  def run_once(_issues), do: {:ok, MapSet.new()}

  defp rescue_issue(%Issue{} = issue) do
    with {:ok, workspace} <- Workspace.path_for_issue(issue) do
      corrections = Workspace.open_blocking_corrections_in_workspace(workspace)

      cond do
        worker_prompt_defect_correction?(corrections) ->
          handle_worker_prompt_defect_corrections(issue, workspace, corrections)

        runtime_dispatch_config_correction?(corrections) ->
          handle_worker_prompt_defect_corrections(issue, workspace, corrections)

        corrections != [] and runtime_progress_correction?(corrections) ->
          classify_runtime_progress_block(issue, workspace, corrections)

        corrections == [] ->
          classify_resolved_review_rework_loop(issue, workspace)

        true ->
          []
      end
    else
      _ -> []
    end
  end

  defp rescue_issue(_issue), do: []

  defp classify_runtime_progress_block(%Issue{} = issue, workspace, corrections) do
    progress_corrections = runtime_progress_corrections(corrections)
    progress_correction_ids = correction_id_list(progress_corrections)

    case inspect_review_if_enabled(issue) do
      {:ok, %{pr_number: pr_number, pr_url: pr_url, head_sha: head_sha, feedback: feedback} = inspection} when feedback != [] ->
        cond do
          fresh_review_feedback_after_latest_codex_request?(inspection) ->
            classification = "review_rework_needed"

            summary =
              "#{classification}: fresh Codex review feedback arrived after the latest review request; prior review-rework loop evidence is stale."

            :ok = Workspace.resolve_blocking_corrections_by_id_in_workspace(workspace, progress_correction_ids, summary)
            :ok = Tracker.update_issue_state(issue.id, Config.settings!().review_monitor.rework_state)
            _ = Tracker.create_comment(issue.id, review_rework_comment(issue, progress_corrections, classification, pr_number, pr_url, head_sha))

            Logger.info("Rescue supervisor classified #{issue.identifier} as #{classification} after fresh review feedback for PR ##{pr_number}")

            [issue.id]

          codex_review_request_pending?(inspection) ->
            Logger.info("Rescue supervisor kept #{issue.identifier} parked because a fresh Codex review request is pending")
            [issue.id]

          review_rework_retry_loop_exhausted_without_new_progress?(workspace) ->
            classification = "worker_prompt_defect"

            summary =
              "#{classification}: repeated review-rework runtime progress retries did not complete the dirty handoff under #{@worker_prompt_fix_version}."

            :ok = Workspace.classify_blocking_corrections_by_id_in_workspace(workspace, progress_correction_ids, classification, summary)
            _ = Tracker.create_comment(issue.id, review_retry_loop_block_comment(issue, progress_corrections, pr_number, pr_url, head_sha))

            Logger.warning("Rescue supervisor classified #{issue.identifier} as #{classification}; leaving review-rework correction open")

            [issue.id]

          true ->
            classification = "review_rework_needed"
            summary = "#{classification}: PR ##{pr_number} has current-head review feedback."

            :ok = Workspace.resolve_blocking_corrections_by_id_in_workspace(workspace, progress_correction_ids, summary)
            :ok = Tracker.update_issue_state(issue.id, Config.settings!().review_monitor.rework_state)
            _ = Tracker.create_comment(issue.id, review_rework_comment(issue, progress_corrections, classification, pr_number, pr_url, head_sha))

            Logger.info("Rescue supervisor classified #{issue.identifier} as #{classification} for PR ##{pr_number}")

            [issue.id]
        end

      {:ok, _inspection} ->
        classify_hydrated_retry(issue, workspace, corrections)

      {:error, reason} ->
        Logger.debug("Rescue supervisor could not inspect PR state for #{issue.identifier}: #{inspect(reason)}")
        []
    end
  end

  defp classify_resolved_review_rework_loop(%Issue{} = issue, workspace) do
    with true <- review_rework_retry_loop_exhausted_without_new_progress?(workspace),
         {:ok, %{pr_number: pr_number, pr_url: pr_url, head_sha: head_sha, feedback: feedback} = inspection} when feedback != [] <-
           inspect_review_if_enabled(issue),
         false <- fresh_review_feedback_after_latest_codex_request?(inspection),
         false <- codex_review_request_pending?(inspection),
         {:ok, correction} <-
           Workspace.create_correction_in_workspace(workspace, issue, %{
             source: "symphony.runtime.review-rework-retry-loop",
             source_status: "blocked",
             summary: "Repeated review-rework runtime progress retries produced no uncommitted or unpushed workspace progress.",
             findings: ["review_rework_needed loop exhausted without workspace progress"],
             next_action: "block"
           }) do
      classification = "worker_prompt_defect"

      summary =
        "#{classification}: repeated review-rework runtime progress retries did not complete the dirty handoff under #{@worker_prompt_fix_version}."

      :ok = Workspace.classify_blocking_corrections_in_workspace(workspace, classification, summary)
      _ = Tracker.create_comment(issue.id, review_retry_loop_block_comment(issue, [correction], pr_number, pr_url, head_sha))

      Logger.warning("Rescue supervisor classified #{issue.identifier} as #{classification}; synthesized review-rework loop correction")

      [issue.id]
    else
      _ -> []
    end
  end

  defp classify_resolved_review_rework_loop(_issue, _workspace), do: []

  defp handle_worker_prompt_defect_corrections(%Issue{} = issue, workspace, corrections) do
    cond do
      current_worker_prompt_defect_correction?(corrections) and
          durable_workspace_progress_after_corrections?(workspace, corrections) ->
        resolve_worker_prompt_defect_after_later_progress(issue, workspace, corrections)

      current_worker_prompt_defect_correction?(corrections) and
          fresh_review_feedback_after_latest_codex_request?(issue) ->
        resolve_worker_prompt_defect_after_fresh_review_feedback(issue, workspace, corrections)

      current_worker_prompt_defect_correction?(corrections) ->
        [issue.id]

      stale_worker_prompt_mixed_runtime_progress_corrections?(corrections) ->
        summary =
          worker_prompt_runtime_fix_summary()

        :ok = Workspace.resolve_blocking_corrections_in_workspace(workspace, summary)
        _ = Tracker.create_comment(issue.id, stale_worker_prompt_defect_resolved_comment(issue, corrections))

        Logger.info("Rescue supervisor resolved mixed stale worker_prompt_defect/runtime-progress corrections for #{issue.identifier}; runtime dispatch preflight is active")

        []

      Enum.all?(corrections, &worker_prompt_defect_correction?/1) ->
        summary =
          worker_prompt_runtime_fix_summary()

        :ok = Workspace.resolve_blocking_corrections_in_workspace(workspace, summary)
        _ = Tracker.create_comment(issue.id, stale_worker_prompt_defect_resolved_comment(issue, corrections))

        Logger.info("Rescue supervisor resolved stale worker_prompt_defect corrections for #{issue.identifier}; runtime prompt fix is active")

        []

      true ->
        [issue.id]
    end
  end

  defp resolve_worker_prompt_defect_after_later_progress(%Issue{} = issue, workspace, corrections) do
    summary =
      "worker_prompt_defect_resolved_by_later_workspace_progress: branch, commit, or handoff evidence advanced after the correction was created."

    :ok = Workspace.resolve_blocking_corrections_in_workspace(workspace, summary)

    case inspect_review_if_enabled(issue) do
      {:ok, %{pr_number: pr_number, pr_url: pr_url, head_sha: head_sha, feedback: feedback}} when feedback != [] ->
        :ok = Tracker.update_issue_state(issue.id, Config.settings!().review_monitor.rework_state)
        _ = Tracker.create_comment(issue.id, later_progress_review_rework_comment(issue, corrections, pr_number, pr_url, head_sha))
        [issue.id]

      {:ok, _inspection} ->
        _ = Tracker.create_comment(issue.id, later_progress_resolved_comment(issue, corrections))
        []

      {:error, reason} ->
        Logger.debug("Rescue supervisor resolved later progress for #{issue.identifier} but could not inspect PR state: #{inspect(reason)}")
        _ = Tracker.create_comment(issue.id, later_progress_resolved_comment(issue, corrections))
        []
    end
  end

  defp resolve_worker_prompt_defect_after_fresh_review_feedback(%Issue{} = issue, workspace, corrections) do
    summary =
      "worker_prompt_defect_resolved_by_fresh_review_feedback: Codex review feedback arrived after the latest review request, so the issue needs a new bounded review-rework dispatch."

    :ok = Workspace.resolve_blocking_corrections_in_workspace(workspace, summary)

    case inspect_review_if_enabled(issue) do
      {:ok, %{pr_number: pr_number, pr_url: pr_url, head_sha: head_sha, feedback: feedback}} when feedback != [] ->
        :ok = Tracker.update_issue_state(issue.id, Config.settings!().review_monitor.rework_state)
        _ = Tracker.create_comment(issue.id, fresh_review_feedback_rework_comment(issue, corrections, pr_number, pr_url, head_sha))
        [issue.id]

      {:ok, _inspection} ->
        _ = Tracker.create_comment(issue.id, later_progress_resolved_comment(issue, corrections))
        []

      {:error, reason} ->
        Logger.debug("Rescue supervisor resolved fresh review feedback for #{issue.identifier} but could not inspect PR state: #{inspect(reason)}")
        _ = Tracker.create_comment(issue.id, later_progress_resolved_comment(issue, corrections))
        []
    end
  end

  defp classify_hydrated_retry(%Issue{} = issue, workspace, corrections) do
    case IssueRequirements.from_issue(issue, workspace) do
      {:ok, requirements} ->
        cond do
          hydrated_dispatch_preflight_before_corrections?(workspace, corrections) and
              not workspace_has_uncommitted_or_unpushed_progress?(workspace) ->
            classification = "worker_prompt_defect"

            summary =
              "#{classification}: runtime progress correction happened after hydrated dispatch preflight, so requirements hydration is not new retry evidence under #{@worker_prompt_fix_version}."

            :ok = Workspace.classify_blocking_corrections_in_workspace(workspace, classification, summary)
            _ = Tracker.create_comment(issue.id, hydrated_preflight_block_comment(issue, corrections, requirements))

            Logger.warning("Rescue supervisor classified #{issue.identifier} as #{classification}; hydrated dispatch preflight already ran")

            [issue.id]

          hydrated_retry_loop_exhausted?(workspace) and not workspace_has_uncommitted_or_unpushed_progress?(workspace) ->
            classification = "worker_prompt_defect"

            summary =
              "#{classification}: repeated runtime progress retries produced no branch, file, or commit progress under #{@worker_prompt_fix_version}."

            :ok = Workspace.classify_blocking_corrections_in_workspace(workspace, classification, summary)
            _ = Tracker.create_comment(issue.id, retry_loop_block_comment(issue, corrections, requirements))

            Logger.warning("Rescue supervisor classified #{issue.identifier} as #{classification}; leaving correction open")

            [issue.id]

          true ->
            classification = "retry_with_hydrated_requirements"
            summary = "#{classification}: no current PR feedback found and issue requirements are parseable."

            :ok = Workspace.resolve_blocking_corrections_in_workspace(workspace, summary)
            _ = Tracker.create_comment(issue.id, hydrated_retry_comment(issue, corrections, requirements))

            Logger.info("Rescue supervisor classified #{issue.identifier} as #{classification}")

            []
        end

      {:error, reason} ->
        Logger.debug("Rescue supervisor left #{issue.identifier} blocked because requirements could not be hydrated: #{inspect(reason)}")
        []
    end
  end

  defp hydrated_dispatch_preflight_before_corrections?(workspace, corrections) when is_binary(workspace) do
    with %DateTime{} = correction_created_at <- latest_correction_created_at(corrections) do
      workspace
      |> Path.join(".orocsy/delivery/events/events.jsonl")
      |> dispatch_preflight_event_before?(correction_created_at)
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp hydrated_dispatch_preflight_before_corrections?(_workspace, _corrections), do: false

  defp dispatch_preflight_event_before?(path, correction_created_at) do
    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.any?(&dispatch_preflight_event_line_before?(&1, correction_created_at))
    else
      false
    end
  rescue
    _error -> false
  end

  defp dispatch_preflight_event_line_before?(line, correction_created_at) do
    with {:ok, decoded} <- Jason.decode(line),
         true <- Map.get(decoded, "source") == "symphony.runtime.dispatch-preflight",
         true <- Map.get(decoded, "status") == "passed",
         %DateTime{} = ts <- decoded |> Map.get("ts") |> datetime_from_iso8601() do
      not datetime_after?(ts, correction_created_at)
    else
      _ -> false
    end
  end

  defp hydrated_retry_loop_exhausted?(workspace) when is_binary(workspace) do
    workspace
    |> correction_history()
    |> Enum.count(fn correction ->
      runtime_progress_correction?([correction]) and
        String.contains?(correction["resolution_summary"] || "", "retry_with_hydrated_requirements")
    end)
    |> Kernel.>=(@hydrated_retry_loop_limit)
  end

  defp hydrated_retry_loop_exhausted?(_workspace), do: false

  defp review_rework_loop_exhausted?(workspace) when is_binary(workspace) do
    workspace
    |> correction_history()
    |> Enum.count(fn correction ->
      runtime_progress_correction?([correction]) and
        String.contains?(correction["resolution_summary"] || "", "review_rework_needed")
    end)
    |> Kernel.>=(@review_rework_loop_limit)
  end

  defp review_rework_loop_exhausted?(_workspace), do: false

  defp review_rework_retry_loop_exhausted_without_new_progress?(workspace) when is_binary(workspace) do
    case latest_uncommitted_or_unpushed_progress_at(workspace) do
      %DateTime{} = progress_at ->
        review_rework_runtime_progress_corrections_at_or_after(workspace, progress_at) >= @review_rework_loop_limit

      _ ->
        review_rework_loop_exhausted?(workspace)
    end
  rescue
    _error -> false
  end

  defp review_rework_retry_loop_exhausted_without_new_progress?(_workspace), do: false

  defp fresh_review_feedback_after_latest_codex_request?(%Issue{} = issue) do
    case inspect_review_if_enabled(issue) do
      {:ok, inspection} ->
        fresh_review_feedback_after_latest_codex_request?(inspection)

      {:error, reason} ->
        Logger.debug("Rescue supervisor could not inspect fresh review feedback for #{issue.identifier}: #{inspect(reason)}")
        false
    end
  end

  defp fresh_review_feedback_after_latest_codex_request?(%{repo: repo, pr: pr, feedback: feedback})
       when feedback != [] do
    case ReviewMonitor.review_feedback_after_latest_codex_request?(repo, pr, feedback) do
      {:ok, fresh?} ->
        fresh?

      {:error, reason} ->
        Logger.debug("Rescue supervisor could not compare review feedback/request timestamps: #{inspect(reason)}")
        false
    end
  end

  defp fresh_review_feedback_after_latest_codex_request?(_inspection), do: false

  defp codex_review_request_pending?(%{repo: repo, pr: pr, feedback: feedback})
       when feedback != [] do
    case ReviewMonitor.codex_review_request_pending?(repo, pr, feedback) do
      {:ok, pending?} ->
        pending?

      {:error, reason} ->
        Logger.debug("Rescue supervisor could not compare pending review request timestamps: #{inspect(reason)}")
        false
    end
  end

  defp codex_review_request_pending?(_inspection), do: false

  defp inspect_review_if_enabled(%Issue{} = issue) do
    monitor = Config.settings!().review_monitor

    if monitor.enabled do
      ReviewMonitor.inspect_issue(issue, monitor)
    else
      {:ok, %{pr: nil, pr_number: nil, pr_url: nil, head_sha: nil, feedback: [], feedback_source: :disabled}}
    end
  end

  defp review_rework_runtime_progress_corrections_at_or_after(workspace, %DateTime{} = progress_at) do
    workspace
    |> correction_history()
    |> Enum.count(fn correction ->
      runtime_progress_correction?([correction]) and correction_created_at_or_after?(correction, progress_at)
    end)
  end

  defp correction_created_at_or_after?(correction, %DateTime{} = progress_at) do
    correction
    |> Map.get("created_at")
    |> datetime_from_iso8601()
    |> datetime_at_or_after?(progress_at)
  end

  defp correction_history(workspace) do
    workspace
    |> Path.join(".orocsy/delivery/inbox/correction_*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      with {:ok, body} <- File.read(path),
           {:ok, %{} = correction} <- Jason.decode(body) do
        [correction]
      else
        _ -> []
      end
    end)
  end

  defp workspace_has_uncommitted_or_unpushed_progress?(workspace) when is_binary(workspace) do
    git_dirty?(workspace) or git_ahead_of_upstream?(workspace)
  end

  defp workspace_has_uncommitted_or_unpushed_progress?(_workspace), do: false

  defp durable_workspace_progress_after_corrections?(workspace, corrections) when is_binary(workspace) do
    case latest_correction_created_at(corrections) do
      %DateTime{} = correction_created_at ->
        git_dirty_after?(workspace, correction_created_at) or
          git_head_commit_after?(workspace, correction_created_at) or
          handoff_event_after?(workspace, correction_created_at)

      _ ->
        false
    end
  end

  defp durable_workspace_progress_after_corrections?(_workspace, _corrections), do: false

  defp latest_uncommitted_or_unpushed_progress_at(workspace) do
    [
      git_dirty_observed_at(workspace),
      git_unpushed_head_commit_observed_at(workspace)
    ]
    |> Enum.reject(&is_nil/1)
    |> latest_datetime()
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

      {_output, _exit_code} ->
        nil
    end
  rescue
    _error -> nil
  end

  defp git_unpushed_head_commit_observed_at(workspace) do
    upstream =
      case System.cmd("git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
             cd: workspace,
             stderr_to_stdout: true
           ) do
        {value, 0} -> String.trim(value)
        {_output, _exit_code} -> nil
      end

    with upstream when is_binary(upstream) and upstream != "" <- upstream,
         {count, 0} <- System.cmd("git", ["rev-list", "--count", "#{upstream}..HEAD"], cd: workspace, stderr_to_stdout: true),
         {value, _rest} <- Integer.parse(String.trim(count)),
         true <- value > 0,
         {head_date, 0} <- System.cmd("git", ["log", "-1", "--format=%cI", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      head_date
      |> String.trim()
      |> datetime_from_iso8601()
    else
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp latest_correction_created_at(corrections) when is_list(corrections) do
    corrections
    |> Enum.flat_map(fn correction ->
      correction
      |> Map.get("created_at")
      |> datetime_from_iso8601()
      |> case do
        %DateTime{} = datetime -> [datetime]
        _ -> []
      end
    end)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp latest_correction_created_at(_corrections), do: nil

  defp git_head_commit_after?(workspace, correction_created_at) do
    args =
      if git_ref_exists?(workspace, "origin/main") do
        ["log", "-1", "--format=%cI", "HEAD", "--not", "origin/main"]
      else
        ["log", "-1", "--format=%cI", "HEAD"]
      end

    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> datetime_from_iso8601()
        |> datetime_after?(correction_created_at)

      {_output, _exit_code} ->
        false
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

  defp git_dirty_after?(workspace, correction_created_at) do
    case System.cmd("git", ["status", "--porcelain=v1"], cd: workspace, stderr_to_stdout: true) do
      {status, 0} ->
        status
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&porcelain_status_paths/1)
        |> Enum.map(&Path.join(workspace, &1))
        |> Enum.any?(&file_mtime_at_or_after?(&1, correction_created_at))

      {_output, _exit_code} ->
        false
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

  defp file_mtime_at_or_after?(path, reference) do
    with {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix),
         {:ok, datetime} <- DateTime.from_unix(mtime) do
      datetime_at_or_after?(datetime, reference)
    else
      _ -> false
    end
  end

  defp file_mtime_datetime(path) do
    with {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix),
         {:ok, datetime} <- DateTime.from_unix(mtime) do
      datetime
    else
      _ -> nil
    end
  end

  defp handoff_event_after?(workspace, correction_created_at) do
    workspace
    |> Path.join(".orocsy/delivery/events/events.jsonl")
    |> handoff_event_file_after?(correction_created_at)
  end

  defp handoff_event_file_after?(path, correction_created_at) do
    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.any?(&handoff_event_line_after?(&1, correction_created_at))
    else
      false
    end
  rescue
    _error -> false
  end

  defp handoff_event_line_after?(line, correction_created_at) do
    with {:ok, decoded} <- Jason.decode(line),
         true <- Map.get(decoded, "status") == "passed",
         event when event in ["handoff.completed", "gate.post-miu", "gate.required-evidence"] <- Map.get(decoded, "event"),
         %DateTime{} = ts <- decoded |> Map.get("ts") |> datetime_from_iso8601() do
      datetime_after?(ts, correction_created_at)
    else
      _ -> false
    end
  end

  defp datetime_from_iso8601(value) when is_binary(value) and value != "" do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp datetime_from_iso8601(_value), do: nil

  defp datetime_after?(%DateTime{} = datetime, %DateTime{} = reference) do
    DateTime.compare(datetime, reference) == :gt
  end

  defp datetime_after?(_datetime, _reference), do: false

  defp datetime_at_or_after?(%DateTime{} = datetime, %DateTime{} = reference) do
    DateTime.diff(datetime, reference, :second) >= -2
  end

  defp datetime_at_or_after?(_datetime, _reference), do: false

  defp latest_datetime(datetimes) do
    Enum.max_by(datetimes, &DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp git_dirty?(workspace) do
    case System.cmd("git", ["status", "--porcelain=v1"], cd: workspace, stderr_to_stdout: true) do
      {status, 0} -> String.trim(status) != ""
      {_output, _exit_code} -> false
    end
  rescue
    _error -> false
  end

  defp git_ahead_of_upstream?(workspace) do
    with {upstream, 0} <-
           System.cmd("git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
             cd: workspace,
             stderr_to_stdout: true
           ),
         upstream <- String.trim(upstream),
         true <- upstream != "",
         {count, 0} <- System.cmd("git", ["rev-list", "--count", "#{upstream}..HEAD"], cd: workspace, stderr_to_stdout: true) do
      case Integer.parse(String.trim(count)) do
        {value, _rest} -> value > 0
        :error -> false
      end
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp runtime_progress_correction?(corrections) do
    Enum.any?(corrections, fn correction ->
      source = correction["source"] || ""
      summary = correction["summary"] || ""
      findings = Enum.join(correction["findings"] || [], " ")

      String.contains?(source, "no-durable-progress") or
        String.contains?(source, "missing-first-durable-event") or
        String.contains?(summary, "durable progress") or
        String.contains?(summary, "first durable") or
        String.contains?(findings, "no-durable-progress") or
        String.contains?(findings, "missing_first_durable_event")
    end)
  end

  defp runtime_progress_corrections(corrections) when is_list(corrections) do
    Enum.filter(corrections, &runtime_progress_correction?([&1]))
  end

  defp correction_id_list(corrections) when is_list(corrections) do
    corrections
    |> Enum.map(& &1["correction_id"])
    |> Enum.filter(&is_binary/1)
  end

  defp runtime_dispatch_config_correction?(corrections) when is_list(corrections) do
    Enum.any?(corrections, &runtime_dispatch_config_correction?/1)
  end

  defp runtime_dispatch_config_correction?(%{} = correction) do
    text =
      [
        correction["source"],
        correction["source_status"],
        correction["summary"],
        correction["classification_summary"],
        Enum.join(correction["findings"] || [], " ")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    correction["status"] == "open" and
      String.contains?(text, "symphony.runtime.worker") and
      String.contains?(text, "failed to load configuration") and
      String.contains?(text, "mcp_servers")
  end

  defp runtime_dispatch_config_correction?(_correction), do: false

  defp worker_prompt_defect_correction?(corrections) when is_list(corrections) do
    Enum.any?(corrections, fn correction ->
      worker_prompt_defect_correction?(correction)
    end)
  end

  defp worker_prompt_defect_correction?(%{} = correction) do
    correction["status"] == "open" and correction["classification"] == "worker_prompt_defect"
  end

  defp worker_prompt_defect_correction?(_correction), do: false

  defp current_worker_prompt_defect_correction?(corrections) when is_list(corrections) do
    Enum.any?(corrections, fn correction ->
      worker_prompt_defect_correction?(correction) and
        String.contains?(correction["classification_summary"] || "", @worker_prompt_fix_version)
    end)
  end

  defp stale_worker_prompt_mixed_runtime_progress_corrections?(corrections) when is_list(corrections) do
    Enum.any?(corrections, &(worker_prompt_defect_correction?(&1) or runtime_dispatch_config_correction?(&1))) and
      Enum.all?(corrections, fn correction ->
        worker_prompt_defect_correction?(correction) or runtime_progress_correction?([correction]) or
          runtime_dispatch_config_correction?(correction)
      end)
  end

  defp worker_prompt_runtime_fix_summary do
    "worker_prompt_defect_resolved_by_runtime_fix: #{@worker_prompt_fix_version} records review classification or technical MIU checkpoint before Codex starts, uses an isolated review-rework thread profile with compact base instructions, blocks broad search/refetch/sideways file-read commands including real exec_command function-call events, injects toolchain guidance so missing corepack/PATH is visible, treats successful focused validation function-call outputs as live durable progress, writes recent worker command/outcome evidence into runtime corrections, marks dispatch-preflight state as read-only worker context, blocks review-rework Linear terminal state mutations until a fresh review scan is clean, and forces dirty review handoffs to validate the dirty diff instead of rediscovering paths with git ls-files."
  end

  defp stale_worker_prompt_defect_resolved_comment(issue, corrections) do
    correction_ids = correction_ids(corrections)

    """
    Symphony resolved stale `worker_prompt_defect` corrections after a runtime dispatch preflight fix.

    - Issue: `#{issue.identifier}`
    - Correction: `#{correction_ids}`
    - Runtime dispatch fix: `#{@worker_prompt_fix_version}`
    - Next action: redispatch is allowed; Symphony will record review classification or technical MIU checkpoint before Codex starts.
    """
    |> String.trim()
  end

  defp later_progress_review_rework_comment(issue, corrections, pr_number, pr_url, head_sha) do
    correction_ids = correction_ids(corrections)

    """
    Symphony resolved a stale `worker_prompt_defect` because workspace progress appeared after the correction, then found current PR review feedback.

    - Issue: `#{issue.identifier}`
    - Correction: `#{correction_ids}`
    - PR: ##{pr_number} #{pr_url}
    - Head: `#{short_sha(head_sha)}`
    - Next action: move to Rework and dispatch a bounded review-fix worker on the existing PR branch.
    """
    |> String.trim()
  end

  defp fresh_review_feedback_rework_comment(issue, corrections, pr_number, pr_url, head_sha) do
    correction_ids = correction_ids(corrections)

    """
    Symphony resolved a stale `worker_prompt_defect` because fresh Codex review feedback arrived after the latest review request.

    - Issue: `#{issue.identifier}`
    - Correction: `#{correction_ids}`
    - PR: ##{pr_number} #{pr_url}
    - Head: `#{short_sha(head_sha)}`
    - Runtime dispatch fix: `#{@worker_prompt_fix_version}`
    - Next action: move to Rework and dispatch a bounded review-fix worker for the new current feedback.
    """
    |> String.trim()
  end

  defp later_progress_resolved_comment(issue, corrections) do
    correction_ids = correction_ids(corrections)

    """
    Symphony resolved a stale `worker_prompt_defect` because durable workspace progress appeared after the correction.

    - Issue: `#{issue.identifier}`
    - Correction: `#{correction_ids}`
    - Next action: continue normal dispatch/review monitoring from the latest branch state.
    """
    |> String.trim()
  end

  defp review_rework_comment(issue, corrections, classification, pr_number, pr_url, head_sha) do
    correction_ids =
      corrections
      |> Enum.map(& &1["correction_id"])
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    """
    Symphony rescue classified this parked correction as `#{classification}`.

    - Issue: `#{issue.identifier}`
    - Correction: `#{correction_ids}`
    - PR: ##{pr_number} #{pr_url}
    - Head: `#{short_sha(head_sha)}`
    - Next action: move to Rework and dispatch a bounded review-fix worker on the existing PR branch.
    """
    |> String.trim()
  end

  defp hydrated_retry_comment(issue, corrections, requirements) do
    correction_ids = correction_ids(corrections)
    scope_count = requirements |> Map.get("write_scope", []) |> length()
    miu_count = requirements |> Map.get("mius", []) |> length()

    """
    Symphony rescue classified this parked correction as `retry_with_hydrated_requirements`.

    - Issue: `#{issue.identifier}`
    - Correction: `#{correction_ids}`
    - Branch: `#{requirements["branch"] || issue.branch_name || "unknown"}`
    - Hydrated scope entries: #{scope_count}
    - Hydrated MIUs: #{miu_count}
    - Next action: resolve the stale no-durable-progress block and redispatch a bounded worker with the hydrated issue requirements.
    """
    |> String.trim()
  end

  defp retry_loop_block_comment(issue, corrections, requirements) do
    correction_ids = correction_ids(corrections)

    """
    Symphony rescue classified this parked correction as `worker_prompt_defect`.

    - Issue: `#{issue.identifier}`
    - Correction: `#{correction_ids}`
    - Branch: `#{requirements["branch"] || issue.branch_name || "unknown"}`
    - Prior hydrated retries: #{@hydrated_retry_loop_limit}+
    - Workspace progress: no dirty files, no commits ahead of `origin/main`
    - Runtime dispatch fix: `#{@worker_prompt_fix_version}`
    - Next action: stop redispatching automatically; fix the worker prompt/runtime dispatch path so the next COD-153 turn records real file, commit, test, review, or blocker progress before the first-event budget.
    """
    |> String.trim()
  end

  defp hydrated_preflight_block_comment(issue, corrections, requirements) do
    correction_ids = correction_ids(corrections)

    """
    Symphony rescue classified this parked correction as `worker_prompt_defect`.

    - Issue: `#{issue.identifier}`
    - Correction: `#{correction_ids}`
    - Branch: `#{requirements["branch"] || issue.branch_name || "unknown"}`
    - Dispatch preflight: hydrated `technical-miu-trace` was already recorded before this runtime progress correction
    - Workspace progress: no dirty files, no commits ahead of `origin/main`
    - Runtime dispatch fix: `#{@worker_prompt_fix_version}`
    - Next action: keep the correction blocked; update the issue/worker handoff or make scoped file, test, blocker, or commit progress before redispatching.
    """
    |> String.trim()
  end

  defp review_retry_loop_block_comment(issue, corrections, pr_number, pr_url, head_sha) do
    correction_ids = correction_ids(corrections)

    """
    Symphony rescue classified this parked correction as `worker_prompt_defect`.

    - Issue: `#{issue.identifier}`
    - Correction: `#{correction_ids}`
    - PR: ##{pr_number} #{pr_url}
    - Head: `#{short_sha(head_sha)}`
    - Prior review-rework retries: #{@review_rework_loop_limit}+
    - Workspace progress: no dirty files, no commits ahead of the tracking branch
    - Runtime dispatch fix: `#{@worker_prompt_fix_version}`
    - Next action: stop redispatching automatically; fix the review-fix worker prompt/runtime dispatch path so the next turn records real file, commit, test, review, or blocker progress before the first-event budget.
    """
    |> String.trim()
  end

  defp correction_ids(corrections) do
    corrections
    |> Enum.map(& &1["correction_id"])
    |> Enum.reject(&blank?/1)
    |> Enum.join(", ")
  end

  defp short_sha(value) when is_binary(value), do: String.slice(value, 0, 12)
  defp short_sha(_value), do: "unknown"

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
