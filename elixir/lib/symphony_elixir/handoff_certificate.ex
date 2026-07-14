defmodule SymphonyElixir.HandoffCertificate do
  @moduledoc """
  Issues and verifies runtime-owned final handoff certificates.

  Generic validation events are deliberately ignored. A certificate is valid
  only for one structured issue contract, issue revision, branch, and pushed
  head.
  """

  alias SymphonyElixir.{Config, ControllerEvidence, Linear.Issue, ReviewMonitor, RuntimeContract}

  @certificate_path ".orocsy/delivery/state/handoff-ready.json"
  @authority "symphony.runtime.handoff-controller"
  @schema_version 3
  @remote_lookup_timeout_ms 30_000

  @spec issue(Issue.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue(%Issue{} = issue, workspace, opts) when is_binary(workspace) and is_list(opts) do
    with {:ok, compiled} <- structured_contract(issue),
         {:ok, branch} <- git(workspace, ["branch", "--show-current"]),
         true <- branch == compiled.contract["integration_branch"] || {:error, :canonical_branch_mismatch},
         {:ok, head_sha} <- git(workspace, ["rev-parse", "HEAD"]),
         {:ok, remote_head} <- remote_branch_head(branch),
         true <- head_sha == remote_head["head_sha"] || {:error, :unpushed_head},
         {:ok, pr} <- open_pull_request(remote_head["repo"], branch),
         :ok <- verify_pull_request(pr, compiled.contract, head_sha),
         true <- clean_worktree?(workspace) || {:error, :dirty_worktree},
         completed_mius when is_list(completed_mius) <- Keyword.get(opts, :completed_mius),
         true <- same_values?(completed_mius, compiled.miu_ids) || {:error, :incomplete_mius},
         validation_event_ids when is_list(validation_event_ids) and validation_event_ids != [] <-
           Keyword.get(opts, :validation_event_ids) do
      certificate =
        ControllerEvidence.sign(%{
          "schema_version" => @schema_version,
          "event" => "handoff.ready",
          "authority" => @authority,
          "issue_id" => issue.id,
          "issue" => issue.identifier,
          "contract_hash" => compiled.contract_hash,
          "issue_revision" => RuntimeContract.issue_revision(issue.description, issue.updated_at),
          "base_branch" => compiled.contract["base_branch"],
          "branch" => branch,
          "head_sha" => head_sha,
          "remote_repo" => remote_head["repo"],
          "remote_branch" => remote_head["branch"],
          "remote_head_sha" => remote_head["head_sha"],
          "pr_number" => pr["number"],
          "pr_url" => pr["html_url"],
          "completed_mius" => completed_mius,
          "validation_event_ids" => validation_event_ids,
          "issued_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        })

      :ok = write(workspace, certificate)
      :ok = append_event(workspace, certificate)
      {:ok, certificate}
    else
      false -> {:error, :certificate_precondition_failed}
      nil -> {:error, :missing_certificate_evidence}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_certificate_evidence}
    end
  end

  def issue(_issue, _workspace, _opts), do: {:error, :invalid_certificate_request}

  @spec current(Issue.t(), String.t()) :: {:ok, map()} | {:stale, atom()} | :not_ready
  def current(%Issue{} = issue, workspace) when is_binary(workspace) do
    path = Path.join(workspace, @certificate_path)

    if File.regular?(path) do
      with {:ok, certificate} <- read(path),
           {:ok, compiled} <- structured_contract(issue),
           :ok <- verify_static_fields(certificate, issue, compiled),
           {:ok, branch} <- git(workspace, ["branch", "--show-current"]),
           :ok <- equal_or_stale(branch, certificate["branch"], :branch_mismatch),
           {:ok, head_sha} <- git(workspace, ["rev-parse", "HEAD"]),
           :ok <- equal_or_stale(head_sha, certificate["head_sha"], :head_mismatch),
           true <- clean_worktree?(workspace) || {:stale, :dirty_worktree},
           {:ok, remote_head} <- remote_branch_head(branch),
           :ok <- equal_or_stale(head_sha, remote_head["head_sha"], :unpushed_head),
           :ok <- equal_or_stale(certificate["remote_repo"], remote_head["repo"], :remote_repo_mismatch),
           {:ok, pr} <- open_pull_request(remote_head["repo"], branch),
           :ok <- verify_pull_request(pr, compiled.contract, head_sha),
           :ok <- equal_or_stale(certificate["pr_number"], pr["number"], :pull_request_mismatch),
           :ok <- equal_or_stale(certificate["pr_url"], pr["html_url"], :pull_request_mismatch) do
        {:ok, certificate}
      else
        :none -> {:stale, :legacy_or_missing_runtime_contract}
        {:error, _reason} -> {:stale, :certificate_unverifiable}
        {:stale, reason} -> {:stale, reason}
        false -> {:stale, :certificate_unverifiable}
        _ -> {:stale, :certificate_unverifiable}
      end
    else
      :not_ready
    end
  end

  def current(_issue, _workspace), do: :not_ready

  @spec path() :: String.t()
  def path, do: @certificate_path

  defp structured_contract(%Issue{} = issue) do
    case RuntimeContract.compile(issue.description) do
      {:ok, compiled} -> {:ok, compiled}
      :none -> {:error, :legacy_or_missing_runtime_contract}
      {:error, errors} -> {:error, {:invalid_runtime_contract, errors}}
    end
  end

  defp verify_static_fields(certificate, issue, compiled) do
    expected_revision = RuntimeContract.issue_revision(issue.description, issue.updated_at)

    cond do
      certificate["schema_version"] != @schema_version -> {:stale, :schema_version_mismatch}
      not ControllerEvidence.valid?(certificate) -> {:stale, :invalid_controller_signature}
      certificate["event"] != "handoff.ready" -> {:stale, :event_mismatch}
      certificate["authority"] != @authority -> {:stale, :authority_mismatch}
      certificate["issue_id"] != issue.id -> {:stale, :issue_id_mismatch}
      certificate["issue"] != issue.identifier -> {:stale, :issue_identifier_mismatch}
      certificate["contract_hash"] != compiled.contract_hash -> {:stale, :contract_hash_mismatch}
      certificate["issue_revision"] != expected_revision -> {:stale, :issue_revision_mismatch}
      certificate["base_branch"] != compiled.contract["base_branch"] -> {:stale, :base_branch_mismatch}
      certificate["branch"] != compiled.contract["integration_branch"] -> {:stale, :canonical_branch_mismatch}
      certificate["remote_branch"] != certificate["branch"] -> {:stale, :remote_branch_mismatch}
      certificate["remote_head_sha"] != certificate["head_sha"] -> {:stale, :remote_head_mismatch}
      not is_binary(certificate["remote_repo"]) or certificate["remote_repo"] == "" -> {:stale, :remote_repo_missing}
      not is_integer(certificate["pr_number"]) or certificate["pr_number"] <= 0 -> {:stale, :pull_request_missing}
      not is_binary(certificate["pr_url"]) or certificate["pr_url"] == "" -> {:stale, :pull_request_missing}
      not same_values?(certificate["completed_mius"], compiled.miu_ids) -> {:stale, :incomplete_mius}
      not valid_validation_evidence?(certificate["validation_event_ids"]) -> {:stale, :missing_validation_evidence}
      true -> :ok
    end
  end

  defp equal_or_stale(left, right, _reason) when left == right, do: :ok
  defp equal_or_stale(_left, _right, reason), do: {:stale, reason}

  defp valid_validation_evidence?(values) when is_list(values) and values != [],
    do: Enum.all?(values, &(is_binary(&1) and &1 != ""))

  defp valid_validation_evidence?(_values), do: false

  defp same_values?(left, right) when is_list(left) and is_list(right) do
    MapSet.new(left) == MapSet.new(right) and length(left) == length(right)
  end

  defp same_values?(_left, _right), do: false

  defp write(workspace, certificate) do
    path = Path.join(workspace, @certificate_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(certificate, pretty: true) <> "\n")
    :ok
  end

  defp append_event(workspace, certificate) do
    path = Path.join(workspace, ".orocsy/delivery/events/events.jsonl")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(certificate) <> "\n", [:append])
    :ok
  end

  defp read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_certificate}
    end
  end

  defp clean_worktree?(workspace) do
    case git(workspace, ["status", "--porcelain=v1", "--untracked-files=all", "--", ".", ":(exclude).orocsy/"]) do
      {:ok, status} -> String.trim(status) == ""
      _ -> false
    end
  end

  defp remote_branch_head(branch) do
    task =
      Task.async(fn ->
        try do
          do_remote_branch_head(branch)
        rescue
          error -> {:error, {:remote_head_exception, Exception.message(error)}}
        catch
          kind, reason -> {:error, {:remote_head_exception, kind, inspect(reason)}}
        end
      end)

    case Task.yield(task, @remote_lookup_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:remote_head_exception, inspect(reason)}}
      nil -> {:error, {:remote_head_lookup_timed_out, @remote_lookup_timeout_ms}}
    end
  rescue
    error -> {:error, {:remote_head_exception, Exception.message(error)}}
  end

  defp do_remote_branch_head(branch) do
    case Application.get_env(:symphony_elixir, :handoff_remote_head_runner) do
      runner when is_function(runner, 1) ->
        normalize_remote_head_result(runner.(branch), branch)

      _ ->
        with {:ok, settings} <- Config.settings(),
             repo when is_binary(repo) and repo != "" <- settings.review_monitor.repo,
             {:ok, head_sha} <- ReviewMonitor.remote_branch_head(repo, branch) do
          {:ok, %{"repo" => repo, "branch" => branch, "head_sha" => head_sha}}
        else
          nil -> {:error, :missing_trusted_github_repo}
          {:error, _reason} = error -> error
          _ -> {:error, :remote_branch_head_unavailable}
        end
    end
  end

  defp normalize_remote_head_result({:ok, %{"repo" => repo, "head_sha" => head_sha}}, branch)
       when is_binary(repo) and repo != "" and is_binary(head_sha) and head_sha != "" do
    {:ok, %{"repo" => repo, "branch" => branch, "head_sha" => head_sha}}
  end

  defp normalize_remote_head_result({:error, _reason} = error, _branch), do: error
  defp normalize_remote_head_result(_result, _branch), do: {:error, :invalid_remote_head_result}

  defp open_pull_request(repo, branch) do
    result =
      case Application.get_env(:symphony_elixir, :handoff_pull_request_runner) do
        runner when is_function(runner, 2) -> runner.(repo, branch)
        _ -> ReviewMonitor.open_pull_request(repo, branch)
      end

    case result do
      {:ok, %{} = pr} -> {:ok, pr}
      {:ok, nil} -> {:error, :missing_open_pull_request}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_pull_request_result}
    end
  end

  defp verify_pull_request(pr, contract, head_sha) do
    cond do
      pr["state"] != "open" -> {:error, :pull_request_not_open}
      get_in(pr, ["head", "ref"]) != contract["integration_branch"] -> {:error, :pull_request_branch_mismatch}
      get_in(pr, ["head", "sha"]) != head_sha -> {:error, :pull_request_head_mismatch}
      get_in(pr, ["base", "ref"]) != contract["base_branch"] -> {:error, :pull_request_base_mismatch}
      not is_integer(pr["number"]) or pr["number"] <= 0 -> {:error, :missing_pull_request_number}
      not is_binary(pr["html_url"]) or pr["html_url"] == "" -> {:error, :missing_pull_request_url}
      true -> :ok
    end
  end

  defp git(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_failed, args, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_exception, Exception.message(error)}}
  end
end
