defmodule SymphonyElixir.HandoffCertificate do
  @moduledoc """
  Issues and verifies runtime-owned final handoff certificates.

  Generic validation events are deliberately ignored. A certificate is valid
  only for one structured issue contract, issue revision, branch, and pushed
  head.
  """

  alias SymphonyElixir.{ControllerEvidence, Linear.Issue, RuntimeContract}

  @certificate_path ".orocsy/delivery/state/handoff-ready.json"
  @authority "symphony.runtime.handoff-controller"

  @spec issue(Issue.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue(%Issue{} = issue, workspace, opts) when is_binary(workspace) and is_list(opts) do
    with {:ok, compiled} <- structured_contract(issue),
         {:ok, branch} <- git(workspace, ["branch", "--show-current"]),
         true <- branch == compiled.contract["integration_branch"] || {:error, :canonical_branch_mismatch},
         {:ok, head_sha} <- git(workspace, ["rev-parse", "HEAD"]),
         {:ok, upstream_sha} <- git(workspace, ["rev-parse", "@{upstream}"]),
         true <- head_sha == upstream_sha || {:error, :unpushed_head},
         true <- clean_worktree?(workspace) || {:error, :dirty_worktree},
         completed_mius when is_list(completed_mius) <- Keyword.get(opts, :completed_mius),
         true <- same_values?(completed_mius, compiled.miu_ids) || {:error, :incomplete_mius},
         validation_event_ids when is_list(validation_event_ids) and validation_event_ids != [] <-
           Keyword.get(opts, :validation_event_ids) do
      certificate =
        ControllerEvidence.sign(%{
          "schema_version" => 1,
          "event" => "handoff.ready",
          "authority" => @authority,
          "issue_id" => issue.id,
          "issue" => issue.identifier,
          "contract_hash" => compiled.contract_hash,
          "issue_revision" => RuntimeContract.issue_revision(issue.description, issue.updated_at),
          "base_branch" => compiled.contract["base_branch"],
          "branch" => branch,
          "head_sha" => head_sha,
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
           {:ok, upstream_sha} <- git(workspace, ["rev-parse", "@{upstream}"]),
           :ok <- equal_or_stale(head_sha, upstream_sha, :unpushed_head) do
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
      certificate["schema_version"] != 1 -> {:stale, :schema_version_mismatch}
      not ControllerEvidence.valid?(certificate) -> {:stale, :invalid_controller_signature}
      certificate["event"] != "handoff.ready" -> {:stale, :event_mismatch}
      certificate["authority"] != @authority -> {:stale, :authority_mismatch}
      certificate["issue_id"] != issue.id -> {:stale, :issue_id_mismatch}
      certificate["issue"] != issue.identifier -> {:stale, :issue_identifier_mismatch}
      certificate["contract_hash"] != compiled.contract_hash -> {:stale, :contract_hash_mismatch}
      certificate["issue_revision"] != expected_revision -> {:stale, :issue_revision_mismatch}
      certificate["branch"] != compiled.contract["integration_branch"] -> {:stale, :canonical_branch_mismatch}
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

  defp git(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_failed, args, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_exception, Exception.message(error)}}
  end
end
