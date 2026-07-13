defmodule SymphonyElixir.MergeController do
  @moduledoc """
  Converges an explicitly enabled automatic merge against exact-head evidence.

  GitHub observations are re-read here immediately before the irreversible
  merge call. Dashboard and telemetry state are never accepted as authority.
  """

  alias SymphonyElixir.{ControllerEvidence, HandoffCertificate, Linear.Issue, ReviewMonitor, RuntimeContract, Workspace}

  @events_path ".orocsy/delivery/events/events.jsonl"
  @authority "symphony.runtime.merge-controller"

  @spec converge(Issue.t(), String.t(), map()) ::
          :manual_handoff | {:merged, map()} | {:blocked, term()} | {:error, term()}
  def converge(%Issue{} = issue, workspace, inspection)
      when is_binary(workspace) and is_map(inspection) do
    with {:ok, compiled} <- structured_contract(issue),
         merge when is_map(merge) <- compiled.contract["merge"],
         true <- merge["automatic"] || :manual_handoff,
         {:ok, certificate} <- HandoffCertificate.current(issue, workspace),
         true <-
           not Workspace.blocking_correction_in_workspace?(workspace) ||
             {:blocked, :open_runtime_correction},
         {:ok, repo, pr} <- repo_and_pr(inspection),
         {:ok, live_pr} <- ReviewMonitor.refresh_pull_request(repo, pr),
         live_inspection <- live_inspection(inspection, live_pr),
         :ok <- verify_pull_request_contract(compiled.contract, certificate, live_inspection, live_pr),
         :ok <- verify_live_feedback_empty(repo, live_pr, merge),
         {:ok, true} <- ReviewMonitor.clean_codex_review_after_latest_request?(repo, live_pr),
         {:ok, 0} <- ReviewMonitor.unresolved_review_thread_count(repo, live_pr),
         :ok <- verify_checks(repo, certificate["head_sha"], merge),
         {:ok, merge_result} <- merge_pull_request(repo, live_pr, certificate["head_sha"], merge["method"]),
         {:ok, evidence} <-
           record_merge(workspace, issue, compiled, certificate, live_inspection, merge, merge_result) do
      {:merged, evidence}
    else
      :manual_handoff -> :manual_handoff
      {:stale, reason} -> {:blocked, {:stale_handoff_certificate, reason}}
      {:ok, false} -> {:blocked, :missing_clean_current_head_codex_review}
      {:ok, count} when is_integer(count) and count > 0 -> {:blocked, {:unresolved_review_threads, count}}
      {:blocked, _reason} = blocked -> blocked
      {:error, _reason} = error -> error
      _ -> {:error, :merge_convergence_failed}
    end
  end

  def converge(_issue, _workspace, _inspection), do: {:error, :invalid_merge_request}

  @spec completed_evidence(Issue.t(), String.t()) :: {:ok, map()} | :none
  def completed_evidence(%Issue{} = issue, workspace) when is_binary(workspace) do
    with {:ok, compiled} <- structured_contract(issue),
         %{} = event <- latest_merge_event(workspace),
         true <- event["issue_id"] == issue.id,
         true <- event["issue"] == issue.identifier,
         true <- event["contract_hash"] == compiled.contract_hash do
      {:ok, event}
    else
      _ -> :none
    end
  end

  def completed_evidence(_issue, _workspace), do: :none

  defp verify_pull_request_contract(contract, certificate, inspection, pr) do
    live_head = value(inspection, :head_sha)
    head_ref = value(inspection, :head_ref) || get_in(pr, ["head", "ref"])
    base_ref = get_in(pr, ["base", "ref"])
    mergeable = value(inspection, :mergeable)
    mergeable_state = value(inspection, :mergeable_state) |> to_string() |> String.downcase()
    pull_state = pr["state"] || pr[:state]

    cond do
      pull_state != "open" ->
        {:blocked, {:pull_request_not_open, pull_state}}

      live_head != certificate["head_sha"] ->
        {:blocked, :pull_request_head_mismatch}

      head_ref != contract["integration_branch"] ->
        {:blocked, :pull_request_branch_mismatch}

      base_ref != contract["base_branch"] ->
        {:blocked, :pull_request_base_mismatch}

      mergeable != true ->
        {:blocked, {:pull_request_not_mergeable, mergeable_state}}

      mergeable_state in ["dirty", "conflicting", "blocked", "unknown"] ->
        {:blocked, {:pull_request_not_mergeable, mergeable_state}}

      true ->
        :ok
    end
  end

  defp live_inspection(inspection, live_pr) do
    inspection
    |> Map.put(:pr, live_pr)
    |> Map.put(:head_sha, get_in(live_pr, ["head", "sha"]))
    |> Map.put(:head_ref, get_in(live_pr, ["head", "ref"]))
    |> Map.put(:mergeable, live_pr["mergeable"])
    |> Map.put(:mergeable_state, live_pr["mergeable_state"] || live_pr["mergeStateStatus"])
    |> Map.put(:pr_number, live_pr["number"])
    |> Map.put(:pr_url, live_pr["html_url"])
  end

  defp verify_live_feedback_empty(repo, pr, merge) do
    include_checks? = merge["require_ci_checks"] != false

    case ReviewMonitor.current_feedback(repo, pr, include_checks?: include_checks?) do
      {:ok, feedback} -> verify_feedback_empty(feedback)
      {:error, reason} -> {:blocked, {:review_feedback_unavailable, reason}}
    end
  end

  defp verify_feedback_empty(feedback) do
    case feedback do
      [] -> :ok
      feedback when is_list(feedback) -> {:blocked, {:current_head_feedback, length(feedback)}}
      _ -> {:blocked, :review_feedback_unavailable}
    end
  end

  defp verify_checks(_repo, _head_sha, %{"require_ci_checks" => false}), do: :ok

  defp verify_checks(repo, head_sha, _merge) do
    case ReviewMonitor.check_runs_state(repo, head_sha) do
      {:ok, :passed} -> :ok
      {:ok, state} -> {:blocked, {:ci_checks_not_passed, state}}
      {:error, reason} -> {:blocked, {:ci_checks_unavailable, reason}}
    end
  end

  defp repo_and_pr(inspection) do
    repo = value(inspection, :repo)
    pr = value(inspection, :pr)

    if is_binary(repo) and repo != "" and is_map(pr) do
      {:ok, repo, pr}
    else
      {:error, :missing_pull_request}
    end
  end

  defp merge_pull_request(repo, pr, head_sha, method) do
    case pull_number(pr) do
      nil ->
        {:error, :missing_pull_request_number}

      number ->
        endpoint = "repos/#{repo}/pulls/#{number}/merge"
        fields = %{"sha" => head_sha, "merge_method" => method}

        case github_merge_runner().(endpoint, fields) do
          {:ok, %{"merged" => true} = result} -> {:ok, result}
          {:ok, %{"merged" => false} = result} -> {:blocked, {:github_merge_rejected, result["message"]}}
          {output, 0} when is_binary(output) -> decode_merge_result(output)
          {output, exit_code} -> {:error, {:github_merge_failed, exit_code, summarize(output)}}
          other -> {:error, {:github_merge_unexpected_result, other}}
        end
    end
  rescue
    error -> {:error, {:github_merge_exception, Exception.message(error)}}
  end

  defp decode_merge_result(output) do
    case Jason.decode(output) do
      {:ok, %{"merged" => true} = result} -> {:ok, result}
      {:ok, %{"merged" => false} = result} -> {:blocked, {:github_merge_rejected, result["message"]}}
      {:ok, result} -> {:error, {:unexpected_github_merge_payload, result}}
      {:error, reason} -> {:error, {:invalid_github_merge_payload, reason}}
    end
  end

  defp github_merge_runner do
    case Application.get_env(:symphony_elixir, :github_merge_runner) do
      runner when is_function(runner, 2) ->
        runner

      _ ->
        fn endpoint, fields ->
          args =
            ["api", "--method", "PUT", endpoint]
            |> Kernel.++(Enum.flat_map(fields, fn {key, value} -> ["-f", "#{key}=#{value}"] end))

          System.cmd("gh", args, stderr_to_stdout: true)
        end
    end
  end

  defp record_merge(workspace, issue, compiled, certificate, inspection, merge, result) do
    merge_sha = result["sha"]

    if is_binary(merge_sha) and merge_sha != "" do
      event =
        ControllerEvidence.sign(%{
          "schema_version" => 1,
          "event" => "merge.completed",
          "authority" => @authority,
          "status" => "passed",
          "issue_id" => issue.id,
          "issue" => issue.identifier,
          "contract_hash" => compiled.contract_hash,
          "branch" => certificate["branch"],
          "base_branch" => certificate["base_branch"],
          "reviewed_head_sha" => certificate["head_sha"],
          "merge_sha" => merge_sha,
          "merge_method" => merge["method"],
          "completed_state" => merge["completed_state"],
          "review_authority" => compiled.contract["review"]["authority"],
          "validation_event_ids" => certificate["validation_event_ids"],
          "pr_number" => value(inspection, :pr_number),
          "pr_url" => value(inspection, :pr_url),
          "completed_at" => now()
        })

      append_event(workspace, event)
      {:ok, event}
    else
      {:error, :missing_merge_sha}
    end
  end

  defp latest_merge_event(workspace) do
    path = Path.join(workspace, @events_path)

    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.reverse()
      |> Enum.find_value(fn line ->
        case Jason.decode(String.trim(line)) do
          {:ok, %{"event" => "merge.completed", "authority" => @authority} = event} ->
            if ControllerEvidence.valid?(event), do: event

          _ ->
            nil
        end
      end)
    end
  end

  defp append_event(workspace, event) do
    path = Path.join(workspace, @events_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(event) <> "\n", [:append])
    :ok
  end

  defp structured_contract(%Issue{} = issue) do
    case RuntimeContract.compile(issue.description) do
      {:ok, compiled} -> {:ok, compiled}
      :none -> {:error, :legacy_or_missing_runtime_contract}
      {:error, errors} -> {:error, {:invalid_runtime_contract, errors}}
    end
  end

  defp pull_number(pr) when is_map(pr), do: pr["number"] || pr[:number]
  defp pull_number(_pr), do: nil

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp summarize(output) do
    output
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
