defmodule SymphonyElixir.HandoffController do
  @moduledoc """
  Converts an explicit worker handoff request into a runtime-owned certificate.
  """

  alias SymphonyElixir.{HandoffCertificate, Linear.Issue, RuntimeContract, RuntimeRequest, ValidationController}

  @spec process_requests(Issue.t(), String.t()) ::
          :none | {:ok, map()} | {:error, term()} | {:blocked, term()}
  def process_requests(%Issue{} = issue, workspace) when is_binary(workspace) do
    case HandoffCertificate.current(issue, workspace) do
      {:ok, certificate} ->
        {:ok, certificate}

      _ ->
        case structured_contract(issue) do
          {:ok, compiled} ->
            contract_identity = %{
              "contract_hash" => compiled.contract_hash,
              "issue_revision" => RuntimeContract.issue_revision(issue.description, issue.updated_at)
            }

            process_handoff_request(issue, workspace, contract_identity)

          {:error, reason} = error ->
            process_invalid_contract_request(workspace, reason, error)
        end
    end
  end

  def process_requests(_issue, _workspace), do: :none

  defp process_handoff_request(issue, workspace, contract_identity) do
    case RuntimeRequest.latest_unprocessed(workspace, "handoff.requested", contract_identity) do
      {:ok, request} ->
        result = certify_handoff(issue, workspace)
        :ok = record_request_result(workspace, request, result)
        result

      {:stale, request, reason} ->
        :ok = RuntimeRequest.mark_processed(workspace, request, "stale", %{"reason" => inspect(reason)})
        :none

      :none ->
        :none
    end
  end

  defp process_invalid_contract_request(workspace, reason, result) do
    case RuntimeRequest.latest_unprocessed(workspace, "handoff.requested") do
      {:ok, request} ->
        :ok = RuntimeRequest.mark_processed(workspace, request, "failed", %{"reason" => inspect(reason)})
        result

      {:stale, request, stale_reason} ->
        :ok = RuntimeRequest.mark_processed(workspace, request, "stale", %{"reason" => inspect(stale_reason)})
        :none

      :none ->
        :none
    end
  end

  defp certify_handoff(issue, workspace) do
    with {:ok, compiled} <- structured_contract(issue),
         {:ok, head_sha} <- git(workspace, ["rev-parse", "HEAD"]),
         certificates <- ValidationController.certificates(workspace),
         :ok <- verify_miu_certificates(issue, workspace, compiled, head_sha, certificates),
         :ok <- verify_final_head_certified(compiled, head_sha, certificates),
         {:ok, final_events} <- ValidationController.validate_final(issue, workspace) do
      validation_event_ids =
        (Enum.flat_map(certificates, &Map.get(&1, "validation_event_ids", [])) ++
           Enum.map(final_events, & &1["event_id"]))
        |> Enum.uniq()

      HandoffCertificate.issue(issue, workspace,
        completed_mius: compiled.miu_ids,
        validation_event_ids: validation_event_ids
      )
    else
      {:error, _reason} = error -> error
      {:blocked, _reason} = blocked -> blocked
      _ -> {:error, :handoff_certification_failed}
    end
  end

  defp verify_miu_certificates(issue, workspace, compiled, head_sha, certificates) do
    expected_revision = RuntimeContract.issue_revision(issue.description, issue.updated_at)
    by_id = Map.new(certificates, &{&1["miu_id"], &1})

    compiled.miu_ids
    |> Enum.reduce_while(nil, fn miu_id, previous_head_sha ->
      case by_id[miu_id] do
        %{} = certificate ->
          cond do
            certificate["event"] != "miu.completed" ->
              {:halt, {:error, {:invalid_miu_certificate_event, miu_id}}}

            certificate["authority"] != "symphony.runtime.validation-controller" ->
              {:halt, {:error, {:invalid_miu_certificate_authority, miu_id}}}

            certificate["issue_id"] != issue.id or certificate["issue"] != issue.identifier ->
              {:halt, {:error, {:miu_certificate_issue_mismatch, miu_id}}}

            certificate["branch"] != compiled.contract["integration_branch"] ->
              {:halt, {:error, {:miu_certificate_branch_mismatch, miu_id}}}

            certificate["contract_hash"] != compiled.contract_hash ->
              {:halt, {:error, {:stale_miu_contract, miu_id}}}

            certificate["issue_revision"] != expected_revision ->
              {:halt, {:error, {:stale_miu_issue_revision, miu_id}}}

            not valid_miu_certificate_range?(workspace, certificate) ->
              {:halt, {:error, {:invalid_miu_certificate_range, miu_id}}}

            is_binary(previous_head_sha) and certificate["base_head_sha"] != previous_head_sha ->
              {:halt, {:error, {:noncontiguous_miu_certificate_range, miu_id}}}

            not git_ancestor?(workspace, certificate["head_sha"], head_sha) ->
              {:halt, {:error, {:miu_checkpoint_not_ancestor, miu_id}}}

            true ->
              {:cont, certificate["head_sha"]}
          end

        _ ->
          {:halt, {:error, {:missing_miu_certificate, miu_id}}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      _last_head_sha -> :ok
    end
  end

  defp valid_miu_certificate_range?(workspace, certificate) do
    base_head_sha = certificate["base_head_sha"]
    certificate_head_sha = certificate["head_sha"]
    changed_paths = certificate["changed_paths"]

    is_binary(base_head_sha) and base_head_sha != "" and
      is_binary(certificate_head_sha) and certificate_head_sha != "" and
      base_head_sha != certificate_head_sha and
      is_list(changed_paths) and changed_paths != [] and
      git_ancestor?(workspace, base_head_sha, certificate_head_sha)
  end

  defp verify_final_head_certified(compiled, head_sha, certificates) do
    last_miu_id = List.last(compiled.miu_ids)

    case Enum.find(certificates, &(&1["miu_id"] == last_miu_id)) do
      %{"head_sha" => ^head_sha} -> :ok
      %{"head_sha" => certified_head} -> {:error, {:uncertified_commits_after_last_miu, certified_head, head_sha}}
      _ -> {:error, {:missing_miu_certificate, last_miu_id}}
    end
  end

  defp record_request_result(workspace, request, result) do
    {status, attributes} =
      case result do
        {:ok, certificate} -> {"completed", %{"certificate_head_sha" => certificate["head_sha"]}}
        {:blocked, reason} -> {"blocked", %{"reason" => inspect(reason)}}
        {:error, reason} -> {"failed", %{"reason" => inspect(reason)}}
      end

    RuntimeRequest.mark_processed(workspace, request, status, attributes)
  end

  defp structured_contract(%Issue{} = issue) do
    case RuntimeContract.compile(issue.description) do
      {:ok, compiled} -> {:ok, compiled}
      :none -> {:error, :legacy_or_missing_runtime_contract}
      {:error, errors} -> {:error, {:invalid_runtime_contract, errors}}
    end
  end

  defp git_ancestor?(workspace, ancestor, head) when is_binary(ancestor) and is_binary(head) do
    case System.cmd("git", ["merge-base", "--is-ancestor", ancestor, head],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _error -> false
  end

  defp git_ancestor?(_workspace, _ancestor, _head), do: false

  defp git(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_failed, args, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_exception, Exception.message(error)}}
  end
end
