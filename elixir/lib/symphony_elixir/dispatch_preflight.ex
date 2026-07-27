defmodule SymphonyElixir.DispatchPreflight do
  @moduledoc """
  Writes a small machine-owned dispatch checkpoint before Codex starts.
  """

  alias SymphonyElixir.{
    Config,
    ControllerEvidence,
    HandoffCertificate,
    IssueRequirements,
    KnowledgeLedger,
    PromptBuilder,
    ReviewMonitor,
    RuntimeContract,
    ScopeAccess,
    ValidationController,
    Workspace
  }

  alias SymphonyElixir.Linear.Issue

  @preflight_path ".orocsy/delivery/state/dispatch-preflight.json"
  @event_path ".orocsy/delivery/events/events.jsonl"
  @feedback_body_max_bytes 1_200

  @spec prepare(String.t(), Issue.t() | map()) :: {:ok, map()} | {:error, term()}
  def prepare(workspace, issue) when is_binary(workspace) do
    with :ok <- ensure_dirs(workspace),
         :ok <- consume_turn_policy_patches(workspace),
         {:ok, requirements} <- requirements_for(workspace, issue),
         {:ok, inspection} <- inspect_review(workspace, issue, requirements) do
      prepare_with_inspection(workspace, issue, requirements, inspection, false)
    end
  end

  def prepare(_workspace, _issue), do: {:error, :invalid_workspace}

  @spec prepare_review_delta_recovery(String.t(), Issue.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def prepare_review_delta_recovery(workspace, %Issue{} = issue, inspection)
      when is_binary(workspace) and is_map(inspection) do
    with :ok <- ensure_dirs(workspace),
         :ok <- consume_turn_policy_patches(workspace),
         {:ok, requirements} <- requirements_for(workspace, issue),
         true <- review_delta_recovery?(workspace, issue, requirements, inspection) do
      prepare_with_inspection(workspace, issue, requirements, inspection, true)
    else
      false -> {:error, :review_delta_recovery_not_authorized}
      {:error, _reason} = error -> error
      _ -> {:error, :review_delta_recovery_failed}
    end
  end

  def prepare_review_delta_recovery(_workspace, _issue, _inspection),
    do: {:error, :invalid_review_delta_recovery}

  defp prepare_with_inspection(workspace, issue, requirements, inspection, review_delta_recovery?) do
    with mode <-
           if(review_delta_recovery?,
             do: "review_rework",
             else: preflight_mode(workspace, issue, requirements, inspection)
           ),
         :ok <-
           maybe_switch_to_review_head(
             workspace,
             inspection,
             mode,
             requirements,
             review_delta_recovery?
           ),
         :ok <- verify_review_delta_head(workspace, inspection, review_delta_recovery?),
         {:ok, certification_base_sha} <-
           certification_base_sha(workspace, issue, requirements, inspection, mode) do
      preflight =
        case mode do
          "handoff_recovery" -> handoff_recovery_preflight(workspace, issue, requirements, inspection)
          "review_rework" -> review_rework_preflight(workspace, issue, requirements, inspection)
          "integration_check" -> integration_check_preflight(workspace, issue, requirements, inspection)
          _ -> fresh_implementation_preflight(workspace, issue, requirements, inspection)
        end
        |> Map.put("certification_base_sha", certification_base_sha)
        |> maybe_bind_review_delta_base(workspace, issue, requirements, inspection, mode)
        |> merge_policy_patches(workspace)
        |> merge_knowledge_ledger(workspace)
        |> bind_controller_identity(issue, requirements)
        |> ControllerEvidence.sign()

      :ok = write_preflight(workspace, preflight)
      :ok = append_preflight_event(workspace, preflight)
      :ok = merge_current_state(workspace, preflight)

      {:ok, preflight}
    end
  end

  @spec read(String.t() | nil) :: {:ok, map()} | :none | {:error, term()}
  def read(workspace) when is_binary(workspace) do
    with {:ok, preflight} <- read_raw(workspace) do
      {:ok,
       preflight
       |> drop_inactive_turn_policy_patch_entries(workspace)
       |> merge_policy_patches(workspace)
       |> merge_knowledge_ledger(workspace)}
    end
  rescue
    error -> {:error, {:preflight_read_failed, Exception.message(error)}}
  end

  def read(_workspace), do: :none

  @spec read_authoritative(String.t() | nil) :: {:ok, map()} | :none | {:error, term()}
  def read_authoritative(workspace) when is_binary(workspace) do
    case read_raw(workspace) do
      {:ok, preflight} when is_map(preflight) ->
        case Map.fetch(preflight, "controller_signature") do
          {:ok, _signature} ->
            if ControllerEvidence.valid?(preflight),
              do: {:ok, preflight},
              else: {:error, :invalid_controller_signature}

          :error ->
            {:error, :missing_controller_signature}
        end

      other ->
        other
    end
  rescue
    error -> {:error, {:authoritative_preflight_read_failed, Exception.message(error)}}
  end

  def read_authoritative(_workspace), do: :none

  @spec read_authoritative(String.t() | nil, String.t() | nil) ::
          {:ok, map()} | :none | {:error, term()}
  def read_authoritative(workspace, nil), do: read_authoritative(workspace)

  def read_authoritative(workspace, worker_host)
      when is_binary(workspace) and is_binary(worker_host) do
    case Workspace.read_file_in_workspace(workspace, @preflight_path, worker_host) do
      {:ok, body} ->
        with {:ok, %{} = preflight} <- Jason.decode(body),
             true <- ControllerEvidence.valid?(preflight) do
          {:ok, preflight}
        else
          false -> {:error, :invalid_controller_signature}
          _ -> {:error, :invalid_dispatch_preflight}
        end

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, {:authoritative_preflight_read_failed, Exception.message(error)}}
  end

  def read_authoritative(_workspace, _worker_host), do: :none

  defp read_raw(workspace) do
    path = Path.join(workspace, @preflight_path)

    cond do
      not File.regular?(path) ->
        :none

      true ->
        case File.read(path) do
          {:ok, body} -> Jason.decode(body)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec consume_turn_policy_patches(String.t() | nil) :: :ok
  def consume_turn_policy_patches(workspace) when is_binary(workspace) do
    workspace
    |> policy_patches()
    |> Enum.each(&consume_turn_policy_patch(workspace, &1))

    prune_persisted_turn_policy_patch_entries(workspace)
    :ok
  end

  def consume_turn_policy_patches(_workspace), do: :ok

  @spec prompt_context(String.t() | nil) :: String.t()
  def prompt_context(workspace) do
    case read_for_prompt(workspace) do
      {:ok, %{"mode" => "review_rework"} = preflight} ->
        review_prompt_context(preflight)

      {:ok, %{"mode" => "fresh_implementation"} = preflight} ->
        fresh_prompt_context(preflight)

      {:ok, %{"mode" => "handoff_recovery"} = preflight} ->
        handoff_recovery_prompt_context(preflight)

      {:ok, %{"mode" => "integration_check"} = preflight} ->
        integration_prompt_context(preflight)

      _ ->
        ""
    end
  end

  @spec read_for_prompt(String.t() | nil) :: {:ok, map()} | {:error, term()} | :none
  def read_for_prompt(workspace) do
    case read(workspace) do
      {:ok, preflight} -> {:ok, with_live_corrections(preflight, workspace)}
      other -> other
    end
  end

  defp with_live_corrections(preflight, workspace) do
    live_corrections = all_open_correction_summaries(workspace)
    visible_corrections = Enum.take(live_corrections, 5)

    preflight
    |> Map.put("open_corrections", visible_corrections)
    |> Map.put("validation_command_guidance", validation_guidance(preflight["toolchain"], visible_corrections))
    |> refresh_correction_derived_fields(live_corrections)
  end

  defp refresh_correction_derived_fields(%{"mode" => "review_rework"} = preflight, corrections) do
    requirements = preflight["requirements"] || %{}
    visible_corrections = Enum.take(corrections, 5)

    preflight
    |> Map.put("checkpoint_event", if(corrections == [], do: "review-feedback-classified", else: "correction-scoped-fix"))
    |> Map.put("open_corrections", visible_corrections)
    |> Map.put("first_task", review_rework_first_task(corrections, requirements))
  end

  defp refresh_correction_derived_fields(%{"mode" => "handoff_recovery"} = preflight, corrections) do
    requirements = preflight["requirements"] || %{}
    visible_corrections = handoff_recovery_correction_summaries(corrections)
    structured? = requirements["runtime_contract_status"] == "structured"
    controller_owned? = corrections |> List.first() |> retryable_controller_validation_correction?()

    checkpoint_event =
      cond do
        structured? and controller_owned? -> "runtime-contract-gate"
        visible_corrections != [] -> "correction-scoped-fix"
        structured? -> "runtime-contract-gate"
        true -> "gate.post-miu"
      end

    preflight
    |> Map.put("open_corrections", visible_corrections)
    |> Map.put("checkpoint_event", checkpoint_event)
    |> Map.put("first_task", handoff_recovery_first_task(corrections, requirements))
  end

  defp refresh_correction_derived_fields(preflight, _corrections), do: preflight

  defp ensure_dirs(workspace) do
    File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/state"))
    File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/events"))
    :ok
  end

  defp requirements_for(workspace, issue) do
    case IssueRequirements.write_workspace_files(workspace, issue) do
      {:ok, requirements} ->
        {:ok, requirements}

      {:error, :no_issue_requirements} ->
        {:ok, fallback_requirements(workspace, issue)}

      {:error, {:missing_issue_requirements, _missing}} ->
        {:ok, fallback_requirements(workspace, issue)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inspect_review(workspace, issue, requirements) do
    issue =
      issue
      |> struct_issue()
      |> maybe_append_issue_brief_description(workspace, requirements)
      |> maybe_bind_authoritative_review_branch(requirements)

    monitor = Config.settings!().review_monitor

    cond do
      not monitor.enabled ->
        {:ok, %{pr: nil, pr_number: nil, pr_url: nil, head_sha: nil, feedback: [], feedback_source: :disabled}}

      true ->
        case ReviewMonitor.inspect_issue(issue, monitor) do
          {:ok, inspection} -> {:ok, inspection}
          {:error, reason} -> {:ok, review_inspection_failed(reason)}
        end
    end
  end

  defp maybe_bind_authoritative_review_branch(%Issue{} = issue, requirements) do
    case authoritative_contract_branch(requirements) do
      branch when is_binary(branch) and branch != "" ->
        %{issue | branch_name: branch, description: ""}

      _ ->
        issue
    end
  end

  defp maybe_append_issue_brief_description(%Issue{} = issue, workspace, requirements) do
    case issue_brief_body(workspace, requirements) do
      "" ->
        issue

      brief ->
        description =
          [issue.description || "", "## Focused Issue Brief\n\n#{brief}"]
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n\n")

        %{issue | description: description}
    end
  end

  defp issue_brief_body(workspace, requirements) when is_binary(workspace) do
    workspace
    |> issue_brief_candidate_paths(requirements)
    |> Enum.find_value("", fn path ->
      if File.regular?(path) do
        path
        |> File.read!()
        |> truncate(20_000)
      end
    end)
  rescue
    _error -> ""
  end

  defp issue_brief_body(_workspace, _requirements), do: ""

  defp issue_brief_candidate_paths(workspace, requirements) when is_map(requirements) do
    requirement_path =
      case requirements do
        %{"issue_brief" => %{"path" => path}} when is_binary(path) -> [Path.join(workspace, path)]
        _ -> []
      end

    identifier = safe_issue_identifier(requirements["identifier"] || "")

    requirement_path ++
      [
        Path.join(workspace, ".orocsy/delivery/issue-brief.md"),
        Path.join(workspace, ".codex/agentic/issue-briefs/#{identifier}.md")
      ]
  end

  defp issue_brief_candidate_paths(_workspace, _requirements), do: []

  defp maybe_switch_to_review_head(_workspace, _inspection, _mode, _requirements, true), do: :ok

  defp maybe_switch_to_review_head(workspace, inspection, mode, requirements, false)
       when is_binary(workspace) and mode in ["review_rework", "integration_check", "handoff_recovery"] do
    branch = authoritative_contract_branch(requirements) || Map.get(inspection, :head_ref)

    if clean_worktree?(workspace) and safe_branch_name?(branch) do
      _ = git_command(workspace, ["fetch", "origin", "+refs/heads/#{branch}:refs/remotes/origin/#{branch}"])

      if local_branch_exists?(workspace, branch) do
        _ = git_command(workspace, ["switch", branch])
        _ = git_command(workspace, ["merge", "--ff-only", "origin/#{branch}"])
      else
        _ = git_command(workspace, ["switch", "--track", "-c", branch, "origin/#{branch}"])
      end
    end

    :ok
  end

  defp maybe_switch_to_review_head(_workspace, _inspection, _mode, _requirements, _review_delta_recovery?),
    do: :ok

  defp verify_review_delta_head(workspace, %{head_sha: review_head}, true)
       when is_binary(workspace) and is_binary(review_head) and review_head != "" do
    case git_command(workspace, ["rev-parse", "HEAD"]) do
      {local_head, 0} when is_binary(local_head) ->
        if String.trim(local_head) == review_head,
          do: :ok,
          else: {:error, :review_delta_head_changed}

      _ ->
        {:error, :review_delta_head_unavailable}
    end
  end

  defp verify_review_delta_head(_workspace, _inspection, true),
    do: {:error, :review_delta_head_missing}

  defp verify_review_delta_head(_workspace, _inspection, false), do: :ok

  defp clean_worktree?(workspace) do
    case git_command(workspace, ["status", "--porcelain", "--untracked-files=all"]) do
      {status, 0} ->
        substantive_status_lines(status) == []

      _ ->
        false
    end
  end

  defp local_branch_exists?(workspace, branch) do
    case git_command(workspace, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"]) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp safe_branch_name?(branch) when is_binary(branch) do
    branch != "" and
      not String.contains?(branch, ["\n", "\r", <<0>>]) and
      not String.starts_with?(branch, "-")
  end

  defp safe_branch_name?(_branch), do: false

  defp git_command(workspace, args) when is_binary(workspace) and is_list(args) do
    System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
  rescue
    error -> {Exception.message(error), 1}
  end

  defp current_branch(workspace) when is_binary(workspace) do
    case git_command(workspace, ["branch", "--show-current"]) do
      {branch, 0} ->
        branch = String.trim(branch)
        if branch == "", do: nil, else: branch

      _ ->
        nil
    end
  end

  defp current_branch(_workspace), do: nil

  defp review_inspection_failed(reason) do
    %{
      pr: nil,
      pr_number: nil,
      pr_url: nil,
      head_sha: nil,
      feedback: [],
      feedback_source: :inspection_failed,
      inspection_error: inspect(reason)
    }
  end

  defp review_feedback?(%{feedback: feedback}) when is_list(feedback), do: feedback != []
  defp review_feedback?(_inspection), do: false

  defp scoped_review_feedback?(inspection, requirements) do
    review_feedback?(inspection) and review_feedback_for_requirements(inspection, requirements) != []
  end

  defp preflight_mode(workspace, issue, requirements, inspection) do
    cond do
      integration_check_mergeability?(requirements, inspection) ->
        "integration_check"

      retryable_miu_validation_correction?(workspace) ->
        "handoff_recovery"

      handoff_recovery_checkpoint?(workspace) and dirty_handoff?(workspace) ->
        "handoff_recovery"

      scoped_review_feedback?(inspection, requirements) ->
        "review_rework"

      retryable_review_rework_validation_correction?(workspace) ->
        "review_rework"

      structured_contract_has_pending_miu?(workspace, issue, requirements) and
          clean_worktree?(workspace) ->
        "fresh_implementation"

      in_progress_implementation_continuation?(workspace, requirements) ->
        "fresh_implementation"

      handoff_recovery_checkpoint?(workspace) and handoff_recovery_must_precede_review?(workspace, inspection) ->
        "handoff_recovery"

      handoff_recovery_checkpoint?(workspace) ->
        "handoff_recovery"

      integration_check_review?(requirements, inspection) ->
        "integration_check"

      explicit_integration_check_requirements?(requirements) ->
        "integration_check"

      true ->
        "fresh_implementation"
    end
  end

  defp review_delta_recovery?(
         workspace,
         issue,
         %{
           "runtime_contract_status" => "structured",
           "integration_branch" => integration_branch
         },
         %{head_sha: review_head, head_ref: review_branch} = inspection
       )
       when is_binary(workspace) and is_binary(review_head) and review_head != "" and
              is_binary(integration_branch) and integration_branch != "" and
              is_binary(review_branch) and review_branch != "" do
    issue = struct_issue(issue)

    with %Issue{state: state} <- issue,
         true <- normalize_state(state) == configured_rework_state(),
         false <- review_feedback?(%{feedback: Map.get(inspection, :feedback, [])}),
         true <- review_branch == integration_branch,
         {:ok, signed_head} <- HandoffCertificate.latest_signed_head(issue, workspace),
         true <- signed_head != review_head,
         {current_branch, 0} <- git_command(workspace, ["branch", "--show-current"]),
         true <- String.trim(current_branch) == integration_branch,
         {status, 0} <-
           git_command(workspace, ["status", "--short", "--branch", "--untracked-files=all"]),
         true <- clean_pushed_tracking_status?(status),
         {local_head, 0} <- git_command(workspace, ["rev-parse", "HEAD"]),
         true <- String.trim(local_head) == review_head,
         {_output, 0} <- git_command(workspace, ["merge-base", "--is-ancestor", signed_head, review_head]) do
      true
    else
      _ -> false
    end
  end

  defp review_delta_recovery?(_workspace, _issue, _requirements, _inspection), do: false

  defp maybe_bind_review_delta_base(
         preflight,
         workspace,
         issue,
         requirements,
         inspection,
         "review_rework"
       ) do
    current_head = review_or_workspace_head(workspace, inspection)

    case HandoffCertificate.latest_signed_head(struct_issue(issue), workspace) do
      {:ok, signed_head} ->
        if valid_review_delta_base?(workspace, signed_head, current_head) do
          Map.put(preflight, "review_delta_base_head", signed_head)
        else
          maybe_preserve_review_delta_base(preflight, workspace, issue, requirements, current_head)
        end

      _ ->
        maybe_preserve_review_delta_base(preflight, workspace, issue, requirements, current_head)
    end
  end

  defp maybe_bind_review_delta_base(preflight, _workspace, _issue, _requirements, _inspection, _mode),
    do: preflight

  defp maybe_preserve_review_delta_base(preflight, workspace, issue, requirements, current_head) do
    issue_id = issue_value(issue, :id)
    contract_hash = requirements["contract_hash"]
    issue_revision = requirements["issue_revision"]

    case read_authoritative(workspace) do
      {:ok,
       %{
         "mode" => "review_rework",
         "issue_id" => ^issue_id,
         "contract_hash" => ^contract_hash,
         "issue_revision" => ^issue_revision
       } = prior_preflight} ->
        case prior_preflight["review_delta_base_head"] || get_in(prior_preflight, ["review", "head_sha"]) do
          base_head
          when is_binary(base_head) and base_head != "" and is_binary(current_head) and
                 current_head != "" ->
            if valid_review_delta_base?(workspace, base_head, current_head) do
              Map.put(preflight, "review_delta_base_head", base_head)
            else
              preflight
            end

          _ ->
            preflight
        end

      _ ->
        preflight
    end
  end

  defp review_or_workspace_head(workspace, inspection) do
    review_head = Map.get(inspection, :head_sha) || Map.get(inspection, "head_sha")

    if is_binary(review_head) and review_head != "" do
      review_head
    else
      case git_command(workspace, ["rev-parse", "HEAD"]) do
        {head, 0} -> String.trim(head)
        _ -> nil
      end
    end
  end

  defp valid_review_delta_base?(workspace, base_head, current_head) do
    case git_command(workspace, ["merge-base", "--is-ancestor", base_head, current_head]) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp configured_rework_state do
    Config.settings!().review_monitor.rework_state
    |> normalize_state()
  end

  defp clean_pushed_tracking_status?(status) when is_binary(status) do
    lines = String.split(status, "\n", trim: true)
    branch_line = List.first(lines) || ""
    dirty_lines = substantive_status_lines(status)

    dirty_lines == [] and
      String.contains?(branch_line, "...") and
      not String.contains?(branch_line, ["ahead", "behind", "diverged"])
  end

  defp clean_pushed_tracking_status?(_status), do: false

  defp handoff_recovery_checkpoint?(workspace) when is_binary(workspace) do
    checkpoint = PromptBuilder.workspace_recovery_checkpoint(workspace)

    String.starts_with?(checkpoint, "Dirty validated handoff checkpoint:") or
      String.starts_with?(checkpoint, "Pushed validated handoff checkpoint:") or
      String.starts_with?(checkpoint, "Local handoff recovery checkpoint:")
  end

  defp handoff_recovery_checkpoint?(_workspace), do: false

  defp validated_handoff_checkpoint?(workspace) when is_binary(workspace) do
    checkpoint = PromptBuilder.workspace_recovery_checkpoint(workspace)

    String.starts_with?(checkpoint, "Dirty validated handoff checkpoint:") or
      String.starts_with?(checkpoint, "Pushed validated handoff checkpoint:")
  end

  defp validated_handoff_checkpoint?(_workspace), do: false

  defp in_progress_implementation_continuation?(workspace, requirements)
       when is_binary(workspace) and is_map(requirements) do
    implementation_issue?(requirements) and
      requirement_state(requirements) == "in progress" and
      clean_worktree?(workspace) and
      not validated_handoff_checkpoint?(workspace)
  end

  defp in_progress_implementation_continuation?(_workspace, _requirements), do: false

  defp structured_contract_has_pending_miu?(workspace, issue, requirements)
       when is_binary(workspace) and is_map(requirements) do
    requirements["runtime_contract_status"] == "structured" and
      remaining_structured_mius(workspace, issue, requirements) != []
  rescue
    _error -> false
  end

  defp structured_contract_has_pending_miu?(_workspace, _issue, _requirements), do: false

  defp remaining_structured_mius(
         workspace,
         issue,
         %{"runtime_contract_status" => "structured"} = requirements
       ) do
    issue = struct_issue(issue)

    certified_ids =
      issue
      |> ValidationController.certified_miu_ids(workspace)
      |> MapSet.new()

    case RuntimeContract.compile(issue.description) do
      {:ok, compiled} ->
        Enum.reject(compiled.contract["mius"], fn miu ->
          MapSet.member?(certified_ids, miu["id"])
        end)

      _ ->
        requirements
        |> Map.get("mius", [])
        |> Enum.map(&%{"id" => &1})
        |> Enum.reject(fn miu -> MapSet.member?(certified_ids, miu["id"]) end)
    end
  end

  defp remaining_structured_mius(_workspace, _issue, _requirements), do: []

  defp retryable_review_rework_validation_correction?(workspace) when is_binary(workspace) do
    workspace
    |> Workspace.open_blocking_corrections_in_workspace()
    |> Enum.any?(fn correction ->
      retryable_controller_validation_correction?(correction) and
        get_in(correction, ["guard", "miu_id"]) == "__review_rework__"
    end)
  end

  defp retryable_review_rework_validation_correction?(_workspace), do: false

  defp retryable_miu_validation_correction?(workspace) when is_binary(workspace) do
    workspace
    |> Workspace.open_blocking_corrections_in_workspace()
    |> Enum.any?(fn correction ->
      miu_id = get_in(correction, ["guard", "miu_id"])

      retryable_controller_validation_correction?(correction) and
        is_binary(miu_id) and miu_id not in ["", "__review_rework__", "__final__"]
    end)
  end

  defp retryable_miu_validation_correction?(_workspace), do: false

  defp retryable_controller_validation_correction?(correction) when is_map(correction) do
    correction["source"] == "symphony.runtime.validation-controller" and
      correction["next_action"] == "retry"
  end

  defp retryable_controller_validation_correction?(_correction), do: false

  defp implementation_issue?(requirements) when is_map(requirements) do
    requirements
    |> Map.get("ticket_type", "")
    |> to_string()
    |> String.downcase()
    |> Kernel.==("implementation")
  end

  defp implementation_issue?(_requirements), do: false

  defp test_spec_issue?(requirements) when is_map(requirements) do
    ticket_type =
      requirements
      |> Map.get("ticket_type", "")
      |> to_string()
      |> String.trim()
      |> String.downcase()

    title =
      requirements
      |> Map.get("title", "")
      |> to_string()
      |> String.trim()
      |> String.downcase()

    ticket_type in ["test-spec", "test spec", "test"] or
      String.contains?(title, "test-spec") or
      String.contains?(title, "test spec")
  end

  defp test_spec_issue?(_requirements), do: false

  defp review_feedback_for_requirements(inspection, requirements) do
    feedback = Map.get(inspection, :feedback, [])

    cond do
      test_spec_issue?(requirements) ->
        Enum.filter(feedback, &feedback_in_write_scope?(&1, requirements))

      implementation_issue?(requirements) ->
        Enum.filter(feedback, &implementation_review_feedback_in_scope?(&1, requirements))

      true ->
        feedback
    end
  end

  defp feedback_in_write_scope?(feedback, requirements) when is_map(requirements) do
    summary = feedback_summary(feedback)

    cond do
      summary["type"] == "check" ->
        true

      true ->
        target_paths = feedback_target_paths(summary)
        write_scope_paths = feedback_write_scope_paths(summary)

        write_scope_paths != [] and
          Enum.any?(write_scope_paths, fn path -> path_in_write_scope?(path, requirements["write_scope"] || []) end) and
          not Enum.any?(target_paths, fn path -> path_in_scope_list?(path, requirements["out_of_scope"] || []) end)
    end
  end

  defp feedback_in_write_scope?(_feedback, _requirements), do: false

  defp implementation_review_feedback_in_scope?(feedback, requirements) when is_map(requirements) do
    feedback_in_write_scope?(feedback, requirements) or
      current_review_path_supersedes_stale_out_of_scope?(feedback, requirements)
  end

  defp implementation_review_feedback_in_scope?(_feedback, _requirements), do: false

  defp current_review_path_supersedes_stale_out_of_scope?(feedback, requirements) do
    summary = feedback_summary(feedback)

    case summary["path"] do
      path when is_binary(path) and path != "" ->
        path_in_scope_list?(path, requirements["out_of_scope"] || []) and
          not protected_shared_scope_path?(path, requirements)

      _ ->
        false
    end
  end

  defp protected_shared_scope_path?(path, requirements) when is_binary(path) and is_map(requirements) do
    requirements
    |> Map.get("shared_files", [])
    |> Enum.any?(fn shared_file ->
      protected_shared_scope_text?(shared_file) and path_in_scope_list?(path, [shared_file])
    end)
  end

  defp protected_shared_scope_path?(_path, _requirements), do: false

  defp protected_shared_scope_text?(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.contains?(["owned by", "owned-by", "do not edit", "out of scope", "out-of-scope"])
  end

  defp protected_shared_scope_text?(_value), do: false

  defp path_in_write_scope?(path, write_scope) when is_binary(path) and is_list(write_scope) do
    path_in_scope_list?(path, write_scope)
  end

  defp path_in_write_scope?(_path, _write_scope), do: false

  defp path_in_scope_list?(path, scope_items) when is_binary(path) and is_list(scope_items) do
    normalized_path = normalize_scope_path(path)

    Enum.any?(scope_items, fn scope ->
      scope
      |> scope_path_candidates()
      |> Enum.any?(fn normalized_scope ->
        path_matches_scope?(normalized_path, normalized_scope)
      end)
    end)
  end

  defp path_in_scope_list?(_path, _scope_items), do: false

  defp path_matches_scope?(normalized_path, normalized_scope) do
    cond do
      normalized_scope == "" ->
        false

      String.ends_with?(normalized_scope, "/**") ->
        prefix = String.trim_trailing(normalized_scope, "/**")
        normalized_path == prefix or String.starts_with?(normalized_path, prefix <> "/")

      String.ends_with?(normalized_scope, "/*") ->
        prefix = String.trim_trailing(normalized_scope, "/*")
        normalized_path == prefix or String.starts_with?(normalized_path, prefix <> "/")

      String.contains?(normalized_scope, "*") ->
        glob_scope_matches?(normalized_path, normalized_scope)

      true ->
        normalized_path == normalized_scope or String.starts_with?(normalized_path, normalized_scope <> "/")
    end
  end

  defp glob_scope_matches?(normalized_path, normalized_scope) do
    normalized_scope
    |> Regex.escape()
    |> String.replace("\\*", ".*")
    |> then(&Regex.compile!("^#{&1}$"))
    |> Regex.match?(normalized_path)
  rescue
    _error -> false
  end

  defp feedback_target_paths(%{"path" => path} = summary) when is_binary(path) and path != "" do
    ([path] ++ feedback_paths([Map.delete(summary, "path")]))
    |> Enum.uniq()
  end

  defp feedback_target_paths(summary) when is_map(summary), do: feedback_paths([summary])
  defp feedback_target_paths(_summary), do: []

  defp feedback_write_scope_paths(%{"path" => path}) when is_binary(path) and path != "", do: [path]
  defp feedback_write_scope_paths(summary) when is_map(summary), do: feedback_paths([summary])
  defp feedback_write_scope_paths(_summary), do: []

  defp scope_path_candidates(scope) when is_binary(scope) do
    ~r{`([^`]+)`|(?:^|[\s,;:"'(])((?:\./)?[A-Za-z0-9_.@+*\-][A-Za-z0-9_\-./()\[\]@+*]*(?:/\*\*|/\*|\.[A-Za-z0-9]+)(?:[A-Za-z0-9_\-./()\[\]@+*]*)?)}
    |> Regex.scan(scope)
    |> Enum.flat_map(fn captures ->
      captures
      |> tl()
      |> Enum.find(&(&1 != ""))
      |> case do
        value when is_binary(value) -> [normalize_scope_path(value)]
        _ -> []
      end
    end)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ["http://", "https://"])))
    |> case do
      [] -> [normalize_scope_path(scope)]
      candidates -> candidates
    end
  end

  defp scope_path_candidates(_scope), do: []

  defp normalize_scope_path(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim("-")
    |> String.trim()
    |> String.trim("`")
    |> String.trim_leading("./")
    |> String.trim_trailing(".")
    |> String.trim_trailing(",")
    |> String.trim_trailing(";")
    |> trim_unbalanced_trailing_parentheses()
    |> String.trim()
  end

  defp trim_unbalanced_trailing_parentheses(path) when is_binary(path) do
    excess = count_char(path, ")") - count_char(path, "(")
    trim_trailing_parentheses(path, excess)
  end

  defp trim_trailing_parentheses(path, excess) when excess > 0 do
    if String.ends_with?(path, ")") do
      path
      |> binary_part(0, byte_size(path) - 1)
      |> trim_trailing_parentheses(excess - 1)
    else
      path
    end
  end

  defp trim_trailing_parentheses(path, _excess), do: path

  defp count_char(value, char) do
    value
    |> String.graphemes()
    |> Enum.count(&(&1 == char))
  end

  defp requirement_state(requirements) when is_map(requirements) do
    requirements
    |> Map.get("state", "")
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp requirement_state(_requirements), do: ""

  defp handoff_recovery_must_precede_review?(workspace, inspection) do
    dirty_or_ahead_handoff?(workspace) or current_branch_matches_review_head?(workspace, inspection)
  end

  defp dirty_handoff?(workspace) when is_binary(workspace) do
    case git_command(workspace, ["status", "--short", "--branch", "--untracked-files=all"]) do
      {status, 0} -> substantive_status_lines(status) != []
      _ -> false
    end
  end

  defp dirty_handoff?(_workspace), do: false

  defp dirty_or_ahead_handoff?(workspace) when is_binary(workspace) do
    case git_command(workspace, ["status", "--short", "--branch", "--untracked-files=all"]) do
      {status, 0} ->
        lines = String.split(String.trim(status), "\n", trim: true)
        branch_line = List.first(lines) || ""
        dirty_lines = substantive_status_lines(status)

        dirty_lines != [] or String.contains?(branch_line, ["ahead", "diverged"])

      _ ->
        false
    end
  end

  defp dirty_or_ahead_handoff?(_workspace), do: false

  defp substantive_status_lines(status) when is_binary(status) do
    status
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "##"))
    |> Enum.reject(&orchestration_status_line?/1)
  end

  defp substantive_status_lines(_status), do: []

  defp orchestration_status_line?(line) when is_binary(line) do
    line
    |> status_line_paths()
    |> case do
      [] -> false
      paths -> Enum.all?(paths, &orchestration_status_path?/1)
    end
  end

  defp orchestration_status_line?(_line), do: false

  defp status_line_paths(line) when is_binary(line) do
    path_part =
      if String.length(line) > 3 do
        String.slice(line, 3..-1//1)
      else
        line
      end

    path_part
    |> String.split(" -> ")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.trim(&1, ~s(")))
    |> Enum.reject(&(&1 == ""))
  end

  defp orchestration_status_path?(path) when is_binary(path) do
    String.starts_with?(path, [
      ".codex/agentic/issue-briefs/",
      ".orocsy/",
      ".codex/delivery/"
    ])
  end

  defp orchestration_status_path?(_path), do: false

  defp current_branch_matches_review_head?(workspace, inspection) when is_binary(workspace) and is_map(inspection) do
    case Map.get(inspection, :head_ref) do
      branch when is_binary(branch) and branch != "" -> current_branch(workspace) == branch
      _ -> false
    end
  end

  defp current_branch_matches_review_head?(_workspace, _inspection), do: false

  defp integration_check_mergeability?(requirements, inspection) do
    integration_check_requirements?(requirements) and mergeability_conflict?(inspection)
  end

  defp integration_check_review?(requirements, inspection) do
    explicit_integration_check_requirements?(requirements) and review_pr_present?(inspection)
  end

  defp integration_check_requirements?(requirements) when is_map(requirements) do
    explicit_integration_check_requirements?(requirements) or
      incidental_merge_conflict_requirement?(requirements)
  end

  defp integration_check_requirements?(_requirements), do: false

  defp explicit_integration_check_requirements?(requirements) when is_map(requirements) do
    ticket_type = requirements["ticket_type"] |> to_string() |> String.downcase()
    title = requirements["title"] |> to_string() |> String.downcase()

    write_scope =
      requirements
      |> Map.get("write_scope", [])
      |> Enum.map(&to_string/1)
      |> Enum.join("\n")
      |> String.downcase()

    ticket_type == "integration-check" or
      String.contains?(title, "integration check") or
      String.contains?(title, "final pr handoff") or
      String.contains?(write_scope, "final pr handoff")
  end

  defp explicit_integration_check_requirements?(_requirements), do: false

  defp incidental_merge_conflict_requirement?(requirements) when is_map(requirements) do
    requirements
    |> Map.get("write_scope", [])
    |> Enum.map(&to_string/1)
    |> Enum.join("\n")
    |> String.downcase()
    |> String.contains?("merge conflict")
  end

  defp incidental_merge_conflict_requirement?(_requirements), do: false

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

  defp review_pr_present?(inspection) when is_map(inspection) do
    Enum.any?([:pr, :pr_number, :pr_url, :head_ref, :head_sha], fn key ->
      present_review_value?(Map.get(inspection, key))
    end)
  end

  defp review_pr_present?(_inspection), do: false

  defp present_review_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_review_value?(nil), do: false
  defp present_review_value?(value), do: value not in [false, [], %{}]

  defp review_rework_preflight(workspace, issue, requirements, inspection) do
    feedback = review_feedback_for_requirements(inspection, requirements)
    requirements = add_review_scope_bundle_entries(requirements, feedback)
    all_open_corrections = all_open_correction_summaries(workspace)
    open_corrections = Enum.take(all_open_corrections, 5)
    correction_active? = open_corrections != []

    %{
      "schema_version" => 1,
      "mode" => "review_rework",
      "created_at" => now_iso8601(),
      "issue" => issue_value(issue, :identifier),
      "state" => issue_value(issue, :state),
      "branch" => authoritative_contract_branch(requirements) || Map.get(inspection, :head_ref) || requirements["branch"] || issue_value(issue, :branch_name),
      "policy_hash" => policy_hash(requirements),
      "checkpoint_event" => if(correction_active?, do: "correction-scoped-fix", else: "review-feedback-classified"),
      "first_task" => review_rework_first_task(open_corrections, requirements),
      "open_corrections" => open_corrections,
      "requirements" => compact_requirements(requirements),
      "toolchain" => toolchain_snapshot(workspace),
      "review" => %{
        "pr_number" => Map.get(inspection, :pr_number),
        "pr_url" => Map.get(inspection, :pr_url),
        "head_ref" => Map.get(inspection, :head_ref),
        "head_sha" => Map.get(inspection, :head_sha),
        "feedback_source" => Map.get(inspection, :feedback_source) |> to_string(),
        "feedback_count" => length(feedback),
        "feedback" => Enum.map(feedback, &feedback_summary/1)
      }
    }
  end

  defp review_rework_first_task([correction | _], %{"runtime_contract_status" => "structured"}) do
    summary = correction["summary"] || correction["correction_id"] || "open Orocsy correction"

    if retryable_controller_validation_correction?(correction) do
      "Use the controller-owned correction before the review shortcut: #{summary}. Make only the named in-scope fix; do not rerun validation or resolve the correction inside the worker. Commit and push the scoped delta, append handoff.requested, and stop so Symphony's validation controller can validate and reconcile it."
    else
      "Resolve the open Orocsy correction before the review shortcut: #{summary}. Make only the named in-scope fix without worker-side validation, resolve the worker/guidance correction with scoped-fix evidence, commit and push the delta, append handoff.requested, and stop so Symphony's validation controller can validate it. Do not append review-feedback-classified while any correction remains."
    end
  end

  defp review_rework_first_task([correction | _], _requirements) do
    summary = correction["summary"] || correction["correction_id"] || "open Orocsy correction"

    "Resolve the open Orocsy correction before the review shortcut: #{summary}. Edit only the named in-scope files, run focused validation, resolve the correction after evidence is recorded, then continue PR review handoff. Do not append review-feedback-classified while an open correction remains."
  end

  defp review_rework_first_task(_open_corrections, %{"runtime_contract_status" => "structured"}) do
    "Fix only the listed current-head review feedback on the existing PR branch, commit and push the scoped delta without running contract validation inside the Codex worker sandbox, then request runtime handoff certification. Symphony's validation controller validates the review delta and requests the fresh Codex review. Do not move Linear to Done; review/rework transitions belong to Symphony's review monitor."
  end

  defp review_rework_first_task(_open_corrections, _requirements) do
    "Fix only the listed current-head review feedback on the existing PR branch, run focused validation, commit and push, then request a fresh Codex review directly. This legacy issue has no structured Runtime Contract for runtime handoff certification. Do not move Linear to Done; review/rework transitions belong to Symphony's review monitor."
  end

  defp handoff_recovery_preflight(workspace, issue, requirements, inspection) do
    feedback = handoff_recovery_feedback(inspection, requirements)
    requirements = add_review_scope_bundle_entries(requirements, feedback)
    all_open_corrections = all_open_correction_summaries(workspace)
    open_corrections = handoff_recovery_correction_summaries(all_open_corrections)
    correction_active? = open_corrections != []
    structured_contract? = requirements["runtime_contract_status"] == "structured"

    first_correction_controller_owned? =
      all_open_corrections
      |> List.first()
      |> retryable_controller_validation_correction?()

    %{
      "schema_version" => 1,
      "mode" => "handoff_recovery",
      "created_at" => now_iso8601(),
      "issue" => issue_value(issue, :identifier),
      "state" => issue_value(issue, :state),
      "branch" => handoff_recovery_branch(workspace, issue, requirements, inspection),
      "policy_hash" => policy_hash(requirements),
      "checkpoint_event" =>
        cond do
          structured_contract? and first_correction_controller_owned? -> "runtime-contract-gate"
          correction_active? -> "correction-scoped-fix"
          structured_contract? -> "runtime-contract-gate"
          true -> "gate.post-miu"
        end,
      "first_task" => handoff_recovery_first_task(all_open_corrections, requirements),
      "open_corrections" => open_corrections,
      "requirements" => compact_requirements(requirements),
      "toolchain" => toolchain_snapshot(workspace),
      "review" => %{
        "pr_number" => Map.get(inspection, :pr_number),
        "pr_url" => Map.get(inspection, :pr_url),
        "head_ref" => Map.get(inspection, :head_ref),
        "head_sha" => Map.get(inspection, :head_sha),
        "mergeable" => Map.get(inspection, :mergeable),
        "mergeable_state" => Map.get(inspection, :mergeable_state),
        "feedback_source" => Map.get(inspection, :feedback_source) |> to_string(),
        "feedback_count" => length(feedback),
        "feedback" => Enum.map(feedback, &feedback_summary/1)
      }
    }
  end

  defp handoff_recovery_first_task([correction | _], %{"runtime_contract_status" => "structured"}) do
    if retryable_controller_validation_correction?(correction) do
      summary = correction["summary"] || correction["correction_id"] || "open Orocsy correction"

      "Resolve the open Orocsy correction before dirty handoff recovery: #{summary}. Follow the active Runtime Contract gate, edit only files named by a remaining MIU, create the clean local micro commit when that gate requires one, append only the exact runtime event supplied by the gate, and stop. Do not run contract-declared validation inside the Codex worker. After successful certification, Symphony's validation controller resolves matching MIU validation corrections and records authoritative evidence."
    else
      handoff_recovery_correction_task(correction)
    end
  end

  defp handoff_recovery_first_task([correction | _], _requirements) do
    handoff_recovery_correction_task(correction)
  end

  defp handoff_recovery_first_task(_open_corrections, requirements) when is_map(requirements) do
    cond do
      test_spec_issue?(requirements) and requirements["runtime_contract_status"] == "structured" ->
        "Recover the existing dirty test-spec checkpoint: run `git status --short --branch`, then run each focused `git diff --no-ext-diff --no-textconv -- <dirty-file>` read as a separate command; never combine checkpoint reads with `&&`, `||`, `;`, or pipes. Finish the named expected-failure marker, create one clean local micro commit, append the exact miu.completion_requested event from the Runtime Contract execution gate, and stop. Do not run contract-declared validation inside the Codex worker; Symphony's validation controller runs it authoritatively outside the worker sandbox. Do not edit production source or broaden scope."

      test_spec_issue?(requirements) ->
        "Recover the existing dirty test-spec checkpoint: run `git status --short --branch`, then run each focused `git diff --no-ext-diff --no-textconv -- <dirty-file>` read as a separate command; never combine checkpoint reads with `&&`, `||`, `;`, or pipes. Run the declared focused validation. If the new test assertions fail only because the implementation is intentionally not present yet, record that expected test-spec result, commit and push the test-only change on the existing branch, and do not edit production source or broaden scope."

      true ->
        handoff_recovery_first_task([], nil)
    end
  end

  defp handoff_recovery_first_task(_open_corrections, _requirements) do
    "Recover the existing dirty/local handoff checkpoint: run `git status --short --branch`, then run each focused `git diff --no-ext-diff --no-textconv -- <dirty-file>` read as a separate command; never combine checkpoint reads with `&&`, `||`, `;`, or pipes. If the dirty validated checkpoint lists current passed evidence and the diff is unchanged, use that evidence and commit, push, and request/update Codex review. Otherwise run the smallest validation for those files, then either fix exact in-scope validation failures or commit/push after validation passes. Do not restart broad implementation or broaden project discovery."
  end

  defp handoff_recovery_correction_summaries(all_open_corrections) do
    visible = Enum.take(all_open_corrections, 5)

    case Enum.find(all_open_corrections, &retryable_controller_validation_correction?/1) do
      nil -> visible
      controller_correction -> Enum.uniq_by(visible ++ [controller_correction], & &1["correction_id"])
    end
  end

  defp handoff_recovery_correction_task(correction) do
    summary = correction["summary"] || correction["correction_id"] || "open Orocsy correction"

    "Resolve the open Orocsy correction before dirty handoff recovery: #{summary}. Inspect the existing focused dirty delta first. When that delta already addresses the named correction and current passed evidence covers it, resolve the correction from that evidence and continue commit/push/review handoff without manufacturing another edit or rerunning the same validation. Otherwise edit only the named in-scope files, run focused validation, and resolve the correction after evidence is recorded. Do not use unrelated or stale handoff evidence to skip the correction."
  end

  defp handoff_recovery_branch(workspace, issue, requirements, inspection) do
    review_head = Map.get(inspection, :head_ref)

    cond do
      contract_branch = authoritative_contract_branch(requirements) ->
        contract_branch

      clean_worktree?(workspace) and present_review_value?(review_head) ->
        review_head

      true ->
        current_branch(workspace) ||
          review_head ||
          requirements["integration_branch"] ||
          requirements["branch"] ||
          issue_value(issue, :branch_name)
    end
  end

  defp integration_check_preflight(workspace, issue, requirements, inspection) do
    requirements = add_conflict_scope_bundle_entries(requirements, inspection)

    %{
      "schema_version" => 1,
      "mode" => "integration_check",
      "created_at" => now_iso8601(),
      "issue" => issue_value(issue, :identifier),
      "state" => issue_value(issue, :state),
      "branch" => authoritative_contract_branch(requirements) || Map.get(inspection, :head_ref) || requirements["integration_branch"] || requirements["branch"] || issue_value(issue, :branch_name),
      "policy_hash" => policy_hash(requirements),
      "checkpoint_event" => "technical-miu-trace",
      "first_task" => integration_check_first_task(inspection),
      "requirements" => compact_requirements(requirements),
      "toolchain" => toolchain_snapshot(workspace),
      "review" => %{
        "pr_number" => Map.get(inspection, :pr_number),
        "pr_url" => Map.get(inspection, :pr_url),
        "head_ref" => Map.get(inspection, :head_ref),
        "head_sha" => Map.get(inspection, :head_sha),
        "mergeable" => Map.get(inspection, :mergeable),
        "mergeable_state" => Map.get(inspection, :mergeable_state),
        "feedback_source" => Map.get(inspection, :feedback_source) |> to_string(),
        "feedback_count" => 0,
        "feedback" => []
      }
    }
  end

  defp integration_check_first_task(inspection) do
    cond do
      mergeability_conflict?(inspection) ->
        "Resolve only the existing PR mergeability conflict on the integration branch, run the declared validation, push the same PR branch, and request a fresh Codex review. Do not merge the PR automatically."

      review_pr_present?(inspection) ->
        "Validate the current pushed integration handoff, avoid product edits unless validation or current-head review reveals a scoped blocker, request Codex review only after a new fix or validation handoff, and leave clean-review waiting to Symphony's review monitor."

      true ->
        "Inspect only the configured integration branch, record handoff.integration-check-started after branch/status confirmation, inspect bounded PR state, create or update the final integration PR only if no PR exists for that branch, run declared validation, request Codex review only after a new fix or validation handoff, and leave clean-review waiting to Symphony's review monitor."
    end
  end

  defp fresh_implementation_preflight(workspace, issue, requirements, inspection) do
    first_task =
      case remaining_structured_mius(workspace, issue, requirements) do
        [%{"id" => miu_id, "write_scope" => [first_path | _]} | _] ->
          "Continue with the next uncertified MIU `#{miu_id}` at its first declared write-scope path `#{first_path}`; make the scoped code/test change, create one clean micro commit, and request runtime MIU certification. Do not recover or revalidate already certified MIUs."

        [%{"id" => miu_id} | _] ->
          "Continue with the next uncertified MIU `#{miu_id}`; make the scoped code/test change, create one clean micro commit, and request runtime MIU certification. Do not recover or revalidate already certified MIUs."

        _ ->
          "Start with the first MIU and the first declared write-scope path only; make a scoped code/test change and then record technical-miu-trace, or record an explicit blocker before broad project scanning. Trace-only/read-only MIU notes are not durable progress."
      end

    %{
      "schema_version" => 1,
      "mode" => "fresh_implementation",
      "created_at" => now_iso8601(),
      "issue" => issue_value(issue, :identifier),
      "state" => issue_value(issue, :state),
      "branch" => fresh_implementation_branch(workspace, issue, requirements),
      "policy_hash" => policy_hash(requirements),
      "checkpoint_event" => "technical-miu-trace",
      "first_task" => first_task,
      "requirements" => compact_requirements(requirements),
      "toolchain" => toolchain_snapshot(workspace),
      "review" => %{
        "pr_number" => Map.get(inspection, :pr_number),
        "pr_url" => Map.get(inspection, :pr_url),
        "head_sha" => Map.get(inspection, :head_sha),
        "mergeable" => Map.get(inspection, :mergeable),
        "mergeable_state" => Map.get(inspection, :mergeable_state),
        "feedback_source" => Map.get(inspection, :feedback_source) |> to_string(),
        "feedback_count" => 0,
        "feedback" => []
      }
    }
  end

  defp fresh_implementation_branch(workspace, issue, requirements) do
    authoritative_contract_branch(requirements) ||
      current_branch(workspace) ||
      shared_existing_branch_from_requirements(requirements) ||
      requirements["branch"] ||
      issue_value(issue, :branch_name)
  end

  defp certification_base_sha(workspace, issue, requirements, inspection, mode) do
    issue_identifier = issue_value(issue, :identifier)
    branch = authoritative_contract_branch(requirements) || Map.get(inspection, :head_ref) || requirements["integration_branch"] || requirements["branch"] || issue_value(issue, :branch_name)
    explicit_base_sha = get_in(requirements, ["runtime_contract", "certification_base_sha"])

    case preserved_certification_base_sha(workspace, issue_identifier, branch) do
      {:ok, base_sha} ->
        {:ok, base_sha}

      :none ->
        {:ok, explicit_base_sha || review_rework_head_sha(inspection, mode)}

      {:error, :missing_controller_signature} when is_binary(explicit_base_sha) ->
        {:ok, explicit_base_sha}

      {:error, reason} ->
        {:error, {:invalid_certification_preflight, reason}}
    end
  end

  defp review_rework_head_sha(inspection, "review_rework"), do: Map.get(inspection, :head_sha)
  defp review_rework_head_sha(_inspection, _mode), do: nil

  defp preserved_certification_base_sha(workspace, issue_identifier, branch) do
    with {:ok, previous} <- read_authoritative(workspace),
         true <- previous["issue"] == issue_identifier,
         true <- previous["branch"] == branch do
      case previous["certification_base_sha"] do
        nil -> {:ok, nil}
        candidate when is_binary(candidate) and candidate != "" -> {:ok, candidate}
        _ -> {:error, :invalid_certification_base}
      end
    else
      :none -> :none
      {:error, reason} -> {:error, reason}
      _ -> :none
    end
  end

  defp bind_controller_identity(preflight, issue, requirements) do
    preflight
    |> Map.put("issue_id", issue_value(issue, :id))
    |> Map.put("contract_hash", requirements["contract_hash"])
    |> Map.put("issue_revision", requirements["issue_revision"])
  end

  defp authoritative_contract_branch(%{"runtime_contract_status" => "structured"} = requirements) do
    case requirements["integration_branch"] do
      branch when is_binary(branch) and branch != "" -> branch
      _ -> nil
    end
  end

  defp authoritative_contract_branch(_requirements), do: nil

  defp shared_existing_branch_from_requirements(requirements) when is_map(requirements) do
    integration_branch = requirements["integration_branch"] |> to_string()

    if integration_branch |> String.downcase() |> String.contains?("same shared branch") do
      clean_branch_token(integration_branch)
    end
  end

  defp shared_existing_branch_from_requirements(_requirements), do: nil

  defp clean_branch_token(value) do
    value = to_string(value)

    value =
      case Regex.run(~r/`([^`]+)`/, value, capture: :all_but_first) do
        [code] -> code
        _ -> value
      end

    value
    |> String.replace(~r/^same shared branch:\s*/i, "")
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim("`")
    |> String.trim_trailing(".")
    |> String.trim_trailing(",")
    |> String.trim_trailing(";")
    |> String.trim()
    |> case do
      "" -> nil
      branch -> branch
    end
  end

  defp write_preflight(workspace, preflight) do
    path = Path.join(workspace, @preflight_path)
    File.write!(path, Jason.encode!(preflight, pretty: true) <> "\n")
    :ok
  end

  defp append_preflight_event(workspace, preflight) do
    event = %{
      "event" => "dispatch.preflight",
      "status" => "passed",
      "tool" => "dispatch-preflight",
      "ts" => now_iso8601(),
      "issue" => preflight["issue"],
      "branch" => preflight["branch"],
      "mode" => preflight["mode"],
      "required_worker_event" => preflight["checkpoint_event"],
      "step" => preflight["first_task"],
      "source" => "symphony.runtime.dispatch-preflight"
    }

    path = Path.join(workspace, @event_path)
    File.write!(path, Jason.encode!(event) <> "\n", [:append])
    :ok
  end

  defp merge_current_state(workspace, preflight) do
    path = Path.join(workspace, ".orocsy/delivery/state/current.json")

    state =
      case File.read(path) do
        {:ok, body} -> Jason.decode!(body)
        {:error, _reason} -> %{"schema_version" => 1}
      end

    state =
      state
      |> Map.put("dispatch_preflight", preflight)
      |> Map.put("updated_at", now_iso8601())

    File.write!(path, Jason.encode!(state, pretty: true) <> "\n")
    :ok
  end

  defp review_prompt_context(preflight) do
    review = preflight["review"] || %{}
    feedback = review["feedback"] || []
    open_corrections = preflight["open_corrections"] || []
    correction_active? = open_corrections != []

    """
    Runtime dispatch preflight:

    - Mode: review rework
    - Preflight file: `#{@preflight_path}`
    - Branch: `#{preflight["branch"] || "unknown"}`
    - PR: #{review["pr_url"] || review["pr_number"] || "unknown"}
    - Reviewed head: `#{short_sha(review["head_sha"])}`
    - Worker-required checkpoint: #{review_rework_checkpoint_guidance(preflight["checkpoint_event"], correction_active?)}
    - Runtime preflight is not worker progress and is not proof that review classification, validation, push, or handoff is complete.
    - Preflight file is read-only runtime context; do not edit it.
    - First task: #{preflight["first_task"]}
    - Open Orocsy corrections: #{format_corrections(open_corrections)}
    - Target feedback file(s): #{format_inline_items(feedback_paths(feedback))}
    - Toolchain preflight: #{format_toolchain(preflight["toolchain"])}
    - Validation command guidance: #{preflight["validation_command_guidance"] || validation_guidance(preflight["toolchain"], open_corrections)}

    Current-head review feedback:
    #{format_items(feedback)}

    Review rework limits:
    - If an open Orocsy correction is listed above, it overrides the review-feedback shortcut. Start from the exact file path named in the correction, not the review feedback path.
    - Use the target feedback file as the first read/edit path only when no open Orocsy correction is listed above.
    - Read only directly related tests, imported local types, or the nearest caller before the first edit.
    - Do not read workflow docs, issue briefs, previous Codex session JSONL, broad CSS, or unrelated components before the first edit unless listed above.
    - Produce a scoped edit plus focused validation, or record an explicit blocker/correction. Do not stop after analysis.
    - Do not create/update a PR, request review, or update Linear handoff until this turn has produced real scoped code/test progress or a valid blocker.
    """
    |> String.trim()
  end

  defp review_rework_checkpoint_guidance(checkpoint_event, true) do
    "`#{checkpoint_event}` after making or explicitly blocking the scoped correction fix. Do not append `review-feedback-classified` while any open correction remains."
  end

  defp review_rework_checkpoint_guidance(checkpoint_event, _correction_active?) do
    "`#{checkpoint_event}` after making the scoped review fix or recording an explicit blocker; classification alone is lifecycle context."
  end

  defp fresh_prompt_context(preflight) do
    requirements = preflight["requirements"] || %{}
    base_branch = requirements["base_branch"] || requirements["integration_branch"] || "unknown"

    """
    Runtime dispatch preflight:

    - Mode: fresh implementation
    - Preflight file: `#{@preflight_path}`
    - Branch: `#{preflight["branch"] || "unknown"}`
    - Base/PR target branch: `#{base_branch}`
    - Worker-required checkpoint: `#{preflight["checkpoint_event"]}` after a scoped code/test change, or a scoped blocker if the edit target is missing.
    - Runtime preflight is not worker progress and is not proof that implementation, validation, push, or handoff is complete.
    - First task: #{preflight["first_task"]}
    - First MIU: #{first_item(requirements["mius"])}
    - First write-scope path: #{first_item(requirements["write_scope"])}
    - First validation command: #{first_item(get_in(requirements, ["validation", "commands"]))}
    - Issue brief: #{format_issue_brief(requirements["issue_brief"])}
    - Dependencies: #{format_inline_items(requirements["dependencies"] || [])}
    - Test activation: #{requirements["test_activation"] || "unknown"}
    - Toolchain preflight: #{format_toolchain(preflight["toolchain"])}
    - Validation command guidance: #{toolchain_guidance(preflight["toolchain"])}

    Do not inspect broad project history before producing scoped file/test progress or an explicit blocker. In a fresh implementation first turn, stop after the scoped code/test checkpoint and `technical-miu-trace`, or after recording a blocker; `technical-miu-trace` alone is not durable progress. The next handoff-recovery turn handles focused validation, commit, push, PR review request, and Linear handoff. Do not create/update a PR, request review, or update Linear handoff from the first implementation turn.
    """
    |> String.trim()
  end

  defp handoff_recovery_prompt_context(preflight) do
    requirements = preflight["requirements"] || %{}
    review = preflight["review"] || %{}
    feedback = review["feedback"] || []
    open_corrections = preflight["open_corrections"] || []
    correction_active? = open_corrections != []

    if requirements["runtime_contract_status"] == "structured" and
         preflight["checkpoint_event"] == "runtime-contract-gate" do
      """
      Runtime dispatch preflight:

      - Mode: structured handoff recovery
      - Preflight file: `#{@preflight_path}`
      - Branch: `#{preflight["branch"] || "unknown"}`
      - PR: #{review["pr_url"] || review["pr_number"] || "unknown"}
      - Worker-required checkpoint: follow the active Runtime Contract gate and append only its exact event (`miu.completion_requested` for a remaining MIU or `handoff.requested` after all MIUs are certified).
      - Runtime preflight is not worker progress and is not proof that certification, push, or review handoff is complete.
      - First task: #{preflight["first_task"]}
      - Open Orocsy corrections: #{format_corrections(open_corrections)}
      - Target current-head feedback file(s): #{format_inline_items(feedback_paths(feedback))}
      - Toolchain preflight: #{format_toolchain(preflight["toolchain"])}

      Current-head review feedback:
      #{format_items(feedback)}

      Structured recovery limits:
      - The Runtime Contract execution/final handoff gate prepended above is authoritative. Do not substitute `gate.post-miu`, `technical-miu-trace`, or a worker-created validation event.
      - For an execution gate, run `git status --short --branch` and each `git diff --no-ext-diff --no-textconv -- <dirty-file>` read as separate commands; never combine checkpoint reads with `&&`, `||`, `;`, or pipes. Inspect only that focused dirty diff and files named by the remaining MIU, complete that MIU, create its micro commit, append `miu.completion_requested`, and stop without pushing.
      - For a final handoff gate, do not create another MIU commit. Push the canonical branch, verify upstream equality, ensure the PR exists, append `handoff.requested`, and stop.
      - Do not run contract-declared validation inside the Codex worker. The validation controller runs it after the runtime request and writes exact failure evidence into an Orocsy correction when a fix is needed.
      - When a matching MIU validation correction is open, use its supplied command output to make the smallest in-scope fix. Do not manually resolve it; successful controller certification resolves it.
      - When current-head review feedback is listed, the recovered delta must address that feedback before final handoff certification.
      - Do not broaden into unrelated routes, docs, historical sessions, Linear discovery, or PR polling.
      """
      |> String.trim()
    else
      """
      Runtime dispatch preflight:

      - Mode: handoff recovery
      - Preflight file: `#{@preflight_path}`
      - Branch: `#{preflight["branch"] || "unknown"}`
      - PR: #{review["pr_url"] || review["pr_number"] || "unknown"}
      - Reviewed head: `#{short_sha(review["head_sha"])}`
      - Worker-required checkpoint: #{handoff_recovery_checkpoint_guidance(preflight["checkpoint_event"], correction_active?)}
      - Runtime preflight is not worker progress and is not proof that validation, commit, push, or review request is complete.
      - First task: #{preflight["first_task"]}
      - Open Orocsy corrections: #{format_corrections(open_corrections)}
      - Target current-head feedback file(s): #{format_inline_items(feedback_paths(feedback))}
      - Dirty workspace recovery is the only task. Run `git status --short --branch` and each focused `git diff --no-ext-diff --no-textconv -- <dirty-file>` read as separate single-purpose commands before any edit; never join them with `&&`, `||`, `;`, or pipes. Do not run `git log` or `git diff --stat` — the runtime denies them and provides commit/diffstat context in the checkpoint above.
      - First validation command: #{first_item(get_in(requirements, ["validation", "commands"]))}
      - Toolchain preflight: #{format_toolchain(preflight["toolchain"])}
      - Validation command guidance: #{preflight["validation_command_guidance"] || validation_guidance(preflight["toolchain"], open_corrections)}

      Current-head review feedback:
      #{format_items(feedback)}

      Handoff recovery limits:
      - If an open Orocsy correction is listed above, inspect the focused dirty delta against its named paths first. When the existing delta addresses the correction and the checkpoint lists current passed evidence for that unchanged delta, resolve the correction and continue handoff without another edit or duplicate validation. Otherwise start from the exact correction path and do not commit, push, or request review until the correction is fixed or explicitly blocked.
      - Do not restart the MIU from the issue brief or switch to the issue seed branch while local dirty work exists.
      - Do not broaden into unrelated routes, docs, historical sessions, Linear discovery, or PR polling.
      - If the focused diff is complete and the dirty handoff checkpoint already lists current passed validation/gate evidence for those dirty files, do not rerun the same validation command; use the recorded evidence, then commit, push the current branch, and request/update Codex review.
      - If validation evidence is missing, stale, or the focused diff changed after evidence was recorded, run the smallest validation for the dirty files before committing.
      - If focused validation fails and names exact in-scope files, assertions, missing columns, missing exports, or required contract symbols, make that smallest in-scope fix first, rerun the same focused validation, then continue handoff.
      - When current-head review feedback is listed, do not commit or request review until the focused dirty delta addresses every listed in-scope finding.
      - Record an Orocsy correction and stop only when validation lacks an actionable in-scope target, a required dependency/credential is missing, permissions block the command, or the needed edit is outside the issue write scope.
      """
      |> String.trim()
    end
  end

  defp handoff_recovery_checkpoint_guidance(checkpoint_event, true) do
    "`#{checkpoint_event}` after making or explicitly blocking the scoped correction fix. Do not use older handoff evidence while any open correction remains."
  end

  defp handoff_recovery_checkpoint_guidance(checkpoint_event, _correction_active?) do
    "focused validation such as `#{checkpoint_event}`, or a scoped blocker only if validation cannot name an in-scope fix target."
  end

  defp integration_prompt_context(preflight) do
    requirements = preflight["requirements"] || %{}
    review = preflight["review"] || %{}
    base_branch = requirements["base_branch"] || "main"

    """
    Runtime dispatch preflight:

    - Mode: integration check
    - Preflight file: `#{@preflight_path}`
    - Branch: `#{preflight["branch"] || "unknown"}`
    - Base/PR target branch: `#{base_branch}`
    - PR: #{review["pr_url"] || review["pr_number"] || "unknown"}
    - PR mergeability: `#{review["mergeable_state"] || review["mergeable"] || "unknown"}`
    - Reviewed head: `#{short_sha(review["head_sha"])}`
    - Worker-required checkpoint: `#{preflight["checkpoint_event"]}` after listing the exact merge-conflict/code paths being changed, or the validation-only handoff checkpoint if the PR is already clean.
    - Runtime preflight is not worker progress and is not proof that mergeability, validation, push, or handoff is complete.
    - First task: #{preflight["first_task"]}
    - Write-scope/conflict paths: #{format_inline_items(requirements["write_scope"] || [])}
    - First validation command: #{first_item(get_in(requirements, ["validation", "commands"]))}
    - Issue brief: #{format_issue_brief(requirements["issue_brief"])}
    - Toolchain preflight: #{format_toolchain(preflight["toolchain"])}
    - Validation command guidance: #{toolchain_guidance(preflight["toolchain"])}

    Integration check limits:
    - Stay on the configured integration branch or discovered PR head branch and push back to that same branch.
    - If PR is unknown, use bounded read-only GitHub PR lookup for the configured branch before deciding whether a same-branch PR handoff is missing; prefer `gh pr list`/`gh pr view`, or use `gh api --method GET` for REST lookup.
    - Use `git fetch origin #{base_branch}` and a bounded merge/rebase conflict check only to expose current merge conflicts.
    - Resolve only the listed conflict/write-scope paths and directly required helper/test paths.
    - If the PR is already mergeable/clean and no current-head review feedback is listed, validate and request/confirm review without product edits; only change code after a concrete validation or review blocker.
    - If a declared validation command fails and names an exact failing test, route, helper, or assertion on the integration branch, treat it as integration validation rework for this handoff branch. Make the smallest same-branch fix, or create an Orocsy inbox correction with the exact command, failing test/assertion, and next action.
    - Do not create a new branch or duplicate PR, do not broaden into unrelated feature work, and never merge the PR automatically.
    - After the conflict fix, run focused validation, then commit, push, and request a fresh Codex review.
    """
    |> String.trim()
  end

  defp toolchain_snapshot(workspace) when is_binary(workspace) do
    executables =
      ["node", "npm", "pnpm", "corepack", "git", "gh"]
      |> Map.new(fn name ->
        {name,
         %{
           "available" => not is_nil(System.find_executable(name))
         }}
      end)

    %{
      "executables" => executables,
      "package_manager" => package_manager_for_workspace(workspace),
      "package_scripts" => package_scripts(workspace)
    }
  end

  defp toolchain_snapshot(_workspace), do: %{"executables" => %{}, "package_manager" => "unknown", "package_scripts" => []}

  defp package_manager_for_workspace(workspace) do
    cond do
      File.regular?(Path.join(workspace, "pnpm-lock.yaml")) -> "pnpm"
      File.regular?(Path.join(workspace, "package-lock.json")) -> "npm"
      File.regular?(Path.join(workspace, "yarn.lock")) -> "yarn"
      File.regular?(Path.join(workspace, "bun.lockb")) -> "bun"
      File.regular?(Path.join(workspace, "package.json")) -> "node"
      true -> "unknown"
    end
  end

  defp package_scripts(workspace) do
    path = Path.join(workspace, "package.json")

    with true <- File.regular?(path),
         {:ok, body} <- File.read(path),
         {:ok, %{"scripts" => scripts}} when is_map(scripts) <- Jason.decode(body) do
      scripts
      |> Map.keys()
      |> Enum.sort()
      |> Enum.take(16)
    else
      _ -> []
    end
  rescue
    _error -> []
  end

  defp format_toolchain(%{"executables" => executables} = toolchain) when is_map(executables) do
    availability =
      ["node", "npm", "pnpm", "corepack", "git", "gh"]
      |> Enum.map_join(" ", fn name ->
        status =
          case get_in(executables, [name, "available"]) do
            true -> "yes"
            false -> "no"
            _ -> "unknown"
          end

        "#{name}=#{status}"
      end)

    "package_manager=#{toolchain["package_manager"] || "unknown"} #{availability}"
  end

  defp format_toolchain(_toolchain), do: "unknown"

  defp toolchain_guidance(%{"executables" => executables, "package_scripts" => scripts}) when is_map(executables) do
    npm? = executable_available?(executables, "npm")
    pnpm? = executable_available?(executables, "pnpm")
    corepack? = executable_available?(executables, "corepack")
    script_hint = validation_script_hint(scripts)

    cond do
      not corepack? and pnpm? ->
        "Do not use `corepack`; use direct `pnpm ...` commands#{script_hint}. If a command is missing, record the exact blocker and stop."

      not corepack? and npm? ->
        "Do not use `corepack`; use `npm run <script>` commands#{script_hint}. If a command is missing, record the exact blocker and stop."

      corepack? ->
        "Corepack is available, but prefer the shortest existing package-manager command#{script_hint}. If a command fails from environment/PATH, record the exact blocker and stop."

      true ->
        "No Node package manager was detected on the runtime PATH. Record an environment blocker before attempting broad rediscovery."
    end
  end

  defp toolchain_guidance(_toolchain), do: "Toolchain availability is unknown; record exact command failures as blockers."

  defp validation_guidance(toolchain, open_corrections) do
    [toolchain_guidance(toolchain), playwright_correction_guidance(open_corrections)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp playwright_correction_guidance(open_corrections) when is_list(open_corrections) do
    if Enum.any?(open_corrections, &playwright_browser_correction?/1) do
      "For Playwright browser validation blocked by the Codex worker sandbox, do not rerun Playwright or seek browser escalation inside the worker. When the prompt includes a `Runtime Contract final handoff gate`, commit and push the scoped fix, append `handoff.requested`, and let Symphony's validation controller run Playwright outside the worker sandbox. For a legacy ticket without that gate, record one concrete environment blocker and stop."
    else
      ""
    end
  end

  defp playwright_correction_guidance(_open_corrections), do: ""

  @spec playwright_browser_correction?(map()) :: boolean()
  def playwright_browser_correction?(%{} = correction) do
    text =
      [
        correction["summary"],
        correction["findings"],
        correction["required_corrections"]
      ]
      |> correction_string_values()
      |> Enum.join("\n")
      |> String.downcase()

    browser_command? = String.contains?(text, ["playwright", "chrome", "chromium"])

    launch_context? =
      String.contains?(text, [
        "before test",
        "before the test",
        "did not execute",
        "launch",
        "startup",
        "starting"
      ])

    sigabrt_launch_failure? = String.contains?(text, "sigabrt") and launch_context?

    launch_failure? =
      String.contains?(text, [
        "could not launch",
        "cannot launch",
        "failed to launch",
        "launch failed",
        "did not execute because",
        "executable missing",
        "local-browsers"
      ]) or sigabrt_launch_failure?

    environment_failure? =
      String.contains?(text, ["sandbox", "sigabrt", "executable missing", "local-browsers"])

    browser_command? and launch_failure? and environment_failure?
  end

  def playwright_browser_correction?(_correction), do: false

  defp executable_available?(executables, name) do
    get_in(executables, [name, "available"]) == true
  end

  defp validation_script_hint(scripts) when is_list(scripts) do
    scripts
    |> Enum.filter(&(&1 in ["typecheck", "type-check", "test", "lint", "build"]))
    |> case do
      [] -> ""
      matched -> " using existing scripts: #{Enum.map_join(matched, ", ", &"`#{&1}`")}"
    end
  end

  defp validation_script_hint(_scripts), do: ""

  defp add_review_scope_bundle_entries(requirements, feedback) when is_map(requirements) and is_list(feedback) do
    entries =
      feedback
      |> Enum.flat_map(&review_scope_bundle_entries/1)

    put_scope_bundle_entries(requirements, "write_scope", entries)
  end

  defp add_review_scope_bundle_entries(requirements, _feedback), do: requirements

  defp review_scope_bundle_entries(feedback) when is_map(feedback) do
    summary = feedback_summary(feedback)
    reason = summary["body"] || "Current-head review feedback"
    review_url = summary["url"]

    [summary]
    |> feedback_paths()
    |> Enum.map(fn path ->
      %{
        "path" => path,
        "source" => "github.current_head_review",
        "operation" => "write",
        "expires" => "review_thread_resolved_or_outdated",
        "reason" => reason
      }
      |> maybe_put("review_url", review_url)
    end)
  end

  defp review_scope_bundle_entries(_feedback), do: []

  defp add_conflict_scope_bundle_entries(requirements, inspection) when is_map(requirements) and is_map(inspection) do
    entries =
      inspection
      |> conflict_paths()
      |> Enum.map(fn path ->
        %{
          "path" => path,
          "source" => "github.mergeability",
          "operation" => "write-if-conflicted",
          "expires" => "mergeable",
          "reason" => "Current PR mergeability names this conflict path"
        }
      end)

    put_scope_bundle_entries(requirements, "conflict_scope", entries)
  end

  defp add_conflict_scope_bundle_entries(requirements, _inspection), do: requirements

  defp put_scope_bundle_entries(requirements, _key, []), do: ensure_scope_bundle(requirements)

  defp put_scope_bundle_entries(requirements, key, entries) when is_map(requirements) do
    bundle =
      requirements
      |> scope_bundle()
      |> Map.update(key, entries, &(&1 ++ entries))
      |> IssueRequirements.refresh_scope_bundle_hash()

    Map.put(requirements, "scope_bundle", bundle)
  end

  defp ensure_scope_bundle(requirements) when is_map(requirements) do
    Map.put(requirements, "scope_bundle", scope_bundle(requirements))
  end

  defp scope_bundle(%{"scope_bundle" => bundle}) when is_map(bundle) do
    IssueRequirements.refresh_scope_bundle_hash(bundle)
  end

  defp scope_bundle(requirements) when is_map(requirements) do
    %{
      "schema_version" => 2,
      "issue" => requirements["identifier"] || "",
      "write_scope" => [],
      "read_context" => [],
      "conflict_scope" => [],
      "denied_scope" => []
    }
    |> IssueRequirements.refresh_scope_bundle_hash()
  end

  defp policy_hash(requirements) when is_map(requirements) do
    requirements
    |> scope_bundle()
    |> Map.get("policy_hash")
  end

  defp policy_hash(_requirements), do: nil

  defp conflict_paths(inspection) when is_map(inspection) do
    inspection
    |> map_value([:conflict_paths, "conflict_paths", :merge_conflict_paths, "merge_conflict_paths"])
    |> case do
      paths when is_list(paths) -> paths
      path when is_binary(path) -> [path]
      _ -> []
    end
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp merge_policy_patches(preflight, workspace) when is_map(preflight) and is_binary(workspace) do
    patches = policy_patches(workspace)

    case patches do
      [] ->
        preflight

      patches ->
        {requirements, applied_patches} =
          preflight
          |> Map.get("requirements", %{})
          |> apply_policy_patches_to_requirements(patches)

        if applied_patches == [] do
          preflight
        else
          preflight
          |> Map.put("requirements", requirements)
          |> Map.put("policy_hash", policy_hash(requirements))
          |> Map.put("policy_patches", Enum.map(applied_patches, &policy_patch_summary/1))
        end
    end
  end

  defp merge_policy_patches(preflight, _workspace), do: preflight

  defp merge_knowledge_ledger(preflight, workspace) when is_map(preflight) and is_binary(workspace) do
    knowledge = KnowledgeLedger.load(workspace, preflight)

    if empty_knowledge_ledger?(knowledge) do
      preflight
    else
      read_context = Map.get(knowledge, "read_context", [])

      preflight =
        case read_context do
          [] ->
            preflight

          entries ->
            requirements =
              preflight
              |> requirements_map()
              |> put_scope_bundle_entries("read_context", entries)

            preflight
            |> Map.put("requirements", requirements)
            |> Map.put("policy_hash", policy_hash(requirements))
        end

      Map.put(preflight, "knowledge_ledger", Map.delete(knowledge, "read_context"))
    end
  end

  defp merge_knowledge_ledger(preflight, _workspace), do: preflight

  defp empty_knowledge_ledger?(%{} = knowledge) do
    Enum.all?(["fresh", "stale", "read_context"], fn key ->
      case Map.get(knowledge, key) do
        values when is_list(values) -> values == []
        _ -> true
      end
    end)
  end

  defp empty_knowledge_ledger?(_knowledge), do: true

  defp requirements_map(%{"requirements" => requirements}) when is_map(requirements), do: requirements
  defp requirements_map(_preflight), do: %{}

  defp policy_patches(workspace) when is_binary(workspace) do
    workspace
    |> active_policy_patch_files()
    |> Enum.filter(&authenticated_scope_access_patch?/1)
    |> Enum.sort_by(&{&1["created_at"] || "", &1["patch_id"] || ""})
  end

  defp active_policy_patch_files(workspace) when is_binary(workspace) do
    workspace
    |> Path.join(Path.join(ScopeAccess.Controller.policy_patch_dir(), "*.json"))
    |> Path.wildcard()
    |> Enum.flat_map(&read_policy_patch/1)
    |> Enum.filter(&active_policy_patch?/1)
  end

  defp read_policy_patch(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{} = patch} ->
            workspace = path |> Path.dirname() |> Path.dirname() |> Path.dirname() |> Path.dirname()
            [Map.put(patch, "path", Path.relative_to(path, workspace))]

          _ ->
            []
        end

      _ ->
        []
    end
  rescue
    _error -> []
  end

  defp active_policy_patch?(%{"status" => status}) when status in ["active", "applied"], do: true
  defp active_policy_patch?(%{"status" => status}) when is_binary(status), do: false
  defp active_policy_patch?(_patch), do: true

  defp authenticated_scope_access_patch?(patch) when is_map(patch) do
    patch["source"] == "symphony.runtime.scope-access-controller" and
      patch["decision"] == "allow_once" and
      policy_patch_target(patch) == "read_context" and
      is_binary(patch["patch_id"]) and patch["patch_id"] != "" and
      is_binary(patch["policy_hash_before"]) and patch["policy_hash_before"] != "" and
      same_patch_request_policy?(patch) and
      valid_scope_access_patch_entries?(patch) and
      ControllerEvidence.valid?(patch)
  end

  defp authenticated_scope_access_patch?(_patch), do: false

  defp same_patch_request_policy?(%{
         "policy_hash_before" => policy_hash,
         "request" => %{"policy_hash" => policy_hash}
       }),
       do: true

  defp same_patch_request_policy?(_patch), do: false

  defp valid_scope_access_patch_entries?(%{
         "entries" => entries,
         "request" => %{"paths" => requested_paths}
       })
       when is_list(entries) and entries != [] and is_list(requested_paths) do
    entry_paths =
      entries
      |> Enum.flat_map(fn
        %{"path" => path, "operation" => operation}
        when is_binary(path) and path != "" and operation in ["read", "search"] ->
          [normalize_policy_patch_path(path)]

        _ ->
          []
      end)
      |> Enum.sort()

    request_paths =
      requested_paths
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.map(&normalize_policy_patch_path/1)
      |> Enum.sort()

    length(entry_paths) == length(entries) and entry_paths == request_paths
  end

  defp valid_scope_access_patch_entries?(_patch), do: false

  defp normalize_policy_patch_path(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim_leading("./")
  end

  defp drop_inactive_turn_policy_patch_entries(preflight, workspace) when is_map(preflight) and is_binary(workspace) do
    active_patch_ids = active_policy_patch_ids(workspace)

    pruned =
      preflight
      |> prune_preflight_scope_bundle(active_patch_ids)
      |> prune_policy_patch_summaries(active_patch_ids)

    if pruned == preflight do
      preflight
    else
      refresh_preflight_policy_hash(pruned)
    end
  end

  defp drop_inactive_turn_policy_patch_entries(preflight, _workspace), do: preflight

  defp active_policy_patch_ids(workspace) when is_binary(workspace) do
    workspace
    |> policy_patches()
    |> Enum.map(& &1["patch_id"])
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp prune_preflight_scope_bundle(preflight, active_patch_ids) when is_map(preflight) do
    preflight
    |> prune_requirements_scope_bundle(active_patch_ids)
    |> prune_top_level_scope_bundle(active_patch_ids)
  end

  defp prune_requirements_scope_bundle(%{"requirements" => requirements} = preflight, active_patch_ids)
       when is_map(requirements) do
    Map.put(preflight, "requirements", prune_scope_bundle_in_requirements(requirements, active_patch_ids))
  end

  defp prune_requirements_scope_bundle(preflight, _active_patch_ids), do: preflight

  defp prune_scope_bundle_in_requirements(%{"scope_bundle" => bundle} = requirements, active_patch_ids)
       when is_map(bundle) do
    Map.put(requirements, "scope_bundle", prune_scope_bundle_turn_entries(bundle, active_patch_ids))
  end

  defp prune_scope_bundle_in_requirements(requirements, _active_patch_ids), do: requirements

  defp prune_top_level_scope_bundle(%{"scope_bundle" => bundle} = preflight, active_patch_ids) when is_map(bundle) do
    Map.put(preflight, "scope_bundle", prune_scope_bundle_turn_entries(bundle, active_patch_ids))
  end

  defp prune_top_level_scope_bundle(preflight, _active_patch_ids), do: preflight

  defp prune_scope_bundle_turn_entries(bundle, active_patch_ids) when is_map(bundle) do
    {pruned, changed?} =
      Enum.reduce(["read_context", "write_scope", "conflict_scope", "denied_scope"], {bundle, false}, fn key, {acc, changed?} ->
        case Map.get(acc, key) do
          entries when is_list(entries) ->
            kept = Enum.reject(entries, &inactive_turn_policy_patch_entry?(&1, active_patch_ids))
            {Map.put(acc, key, kept), changed? or kept != entries}

          _ ->
            {acc, changed?}
        end
      end)

    if changed? do
      IssueRequirements.refresh_scope_bundle_hash(pruned)
    else
      bundle
    end
  end

  defp inactive_turn_policy_patch_entry?(%{"policy_patch_id" => patch_id, "expires" => "turn"}, active_patch_ids)
       when is_binary(patch_id) do
    not MapSet.member?(active_patch_ids, patch_id)
  end

  defp inactive_turn_policy_patch_entry?(_entry, _active_patch_ids), do: false

  defp prune_policy_patch_summaries(preflight, active_patch_ids) when is_map(preflight) do
    case Map.get(preflight, "policy_patches", :missing) do
      :missing ->
        preflight

      summaries when is_list(summaries) ->
        Map.put(preflight, "policy_patches", Enum.reject(summaries, &inactive_policy_patch_summary?(&1, active_patch_ids)))

      _other ->
        preflight
    end
  end

  defp inactive_policy_patch_summary?(%{"patch_id" => patch_id}, active_patch_ids) when is_binary(patch_id) do
    not MapSet.member?(active_patch_ids, patch_id)
  end

  defp inactive_policy_patch_summary?(_summary, _active_patch_ids), do: false

  defp refresh_preflight_policy_hash(%{"requirements" => requirements} = preflight) when is_map(requirements) do
    Map.put(preflight, "policy_hash", policy_hash(requirements))
  end

  defp refresh_preflight_policy_hash(%{"scope_bundle" => %{"policy_hash" => policy_hash}} = preflight) when is_binary(policy_hash) do
    Map.put(preflight, "policy_hash", policy_hash)
  end

  defp refresh_preflight_policy_hash(preflight), do: preflight

  defp prune_persisted_turn_policy_patch_entries(workspace) when is_binary(workspace) do
    path = Path.join(workspace, @preflight_path)

    with true <- File.regular?(path),
         {:ok, body} <- File.read(path),
         {:ok, %{} = preflight} <- Jason.decode(body) do
      pruned = drop_inactive_turn_policy_patch_entries(preflight, workspace)

      if pruned != preflight do
        File.write!(path, Jason.encode!(pruned, pretty: true) <> "\n")
      end
    end

    :ok
  rescue
    _error -> :ok
  end

  defp consume_turn_policy_patch(workspace, %{"path" => relative_path} = patch) when is_binary(relative_path) do
    if turn_policy_patch?(patch) do
      path = Path.join(workspace, relative_path)

      patch
      |> Map.put("status", "consumed")
      |> Map.put_new("consumed_at", DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())
      |> ControllerEvidence.sign()
      |> then(&File.write!(path, Jason.encode!(&1, pretty: true) <> "\n"))
    end
  rescue
    _error -> :ok
  end

  defp consume_turn_policy_patch(_workspace, _patch), do: :ok

  defp handoff_recovery_feedback(inspection, requirements) do
    if test_spec_issue?(requirements),
      do: [],
      else: review_feedback_for_requirements(inspection, requirements)
  end

  if Code.ensure_loaded?(Mix) and Mix.env() == :test do
    def handoff_recovery_feedback_for_test(inspection, requirements),
      do: handoff_recovery_feedback(inspection, requirements)
  end

  defp turn_policy_patch?(%{"decision" => "allow_once"}), do: true

  defp turn_policy_patch?(%{"entries" => entries}) when is_list(entries) do
    Enum.any?(entries, &(&1["expires"] == "turn"))
  end

  defp turn_policy_patch?(_patch), do: false

  defp apply_policy_patches_to_requirements(requirements, patches) when is_map(requirements) do
    Enum.reduce(patches, {ensure_scope_bundle(requirements), []}, fn patch, {acc, applied} ->
      if applicable_policy_patch?(patch, acc) do
        updated =
          patch
          |> policy_patch_entries()
          |> Enum.reduce(acc, fn {target, entries}, requirements ->
            put_scope_bundle_entries(requirements, target, entries)
          end)

        {updated, applied ++ [patch]}
      else
        {acc, applied}
      end
    end)
  end

  defp applicable_policy_patch?(patch, requirements) do
    patch["policy_hash_before"] == policy_hash(requirements) or
      policy_patch_already_applied?(patch, requirements)
  end

  defp policy_patch_already_applied?(%{"patch_id" => patch_id, "entries" => entries}, requirements)
       when is_binary(patch_id) and is_list(entries) do
    current_entries =
      requirements
      |> scope_bundle()
      |> Map.get("read_context", [])

    Enum.all?(entries, fn %{"path" => path} ->
      normalized = normalize_policy_patch_path(path)

      Enum.any?(current_entries, fn
        %{"path" => current_path, "policy_patch_id" => ^patch_id} ->
          normalize_policy_patch_path(current_path) == normalized

        _ ->
          false
      end)
    end)
  end

  defp policy_patch_already_applied?(_patch, _requirements), do: false

  defp policy_patch_entries(%{"entries" => entries} = patch) when is_list(entries) do
    target = policy_patch_target(patch)

    entries =
      entries
      |> Enum.filter(&is_map/1)
      |> Enum.map(&normalize_policy_patch_entry(&1, patch))

    [{target, entries}]
  end

  defp policy_patch_entries(_patch), do: []

  defp normalize_policy_patch_entry(entry, patch) do
    entry
    |> Map.put_new("source", patch["source"] || "symphony.runtime.scope-access-controller")
    |> Map.put_new("operation", policy_patch_entry_operation(patch))
    |> Map.put_new("expires", "turn")
    |> maybe_put("policy_patch_id", patch["patch_id"])
  end

  defp policy_patch_target(%{"target" => target}) when target in ["write_scope", "read_context", "conflict_scope", "denied_scope"], do: target
  defp policy_patch_target(_patch), do: "read_context"

  defp policy_patch_entry_operation(%{"target" => "write_scope"}), do: "write"
  defp policy_patch_entry_operation(%{"target" => "conflict_scope"}), do: "write-if-conflicted"
  defp policy_patch_entry_operation(%{"target" => "denied_scope"}), do: "deny"
  defp policy_patch_entry_operation(_patch), do: "read"

  defp policy_patch_summary(patch) do
    %{
      "patch_id" => patch["patch_id"],
      "source" => patch["source"],
      "target" => policy_patch_target(patch),
      "decision" => patch["decision"],
      "reason_class" => patch["reason_class"],
      "path" => patch["path"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp compact_requirements(requirements) when is_map(requirements) do
    Map.take(requirements, [
      "identifier",
      "title",
      "state",
      "branch",
      "base_branch",
      "integration_branch",
      "feature_group",
      "ticket_type",
      "runtime_contract_status",
      "contract_hash",
      "expected_test_state",
      "test_activation",
      "write_scope",
      "read_context",
      "shared_files",
      "dependencies",
      "mius",
      "validation",
      "out_of_scope",
      "issue_brief",
      "scope_bundle"
    ])
  end

  defp compact_requirements(_requirements), do: %{}

  defp fallback_requirements(workspace, issue) do
    %{
      "identifier" => issue_value(issue, :identifier),
      "title" => issue_value(issue, :title),
      "state" => issue_value(issue, :state),
      "branch" => issue_value(issue, :branch_name),
      "write_scope" => [],
      "dependencies" => [],
      "mius" => [],
      "validation" => %{"commands" => [], "files" => [], "events" => [], "scenarios" => []},
      "out_of_scope" => [],
      "issue_brief" => fallback_issue_brief_reference(workspace, issue_value(issue, :identifier))
    }
  end

  defp fallback_issue_brief_reference(workspace, identifier) when is_binary(workspace) and is_binary(identifier) do
    relative_paths = [
      ".orocsy/delivery/issue-brief.md",
      Path.join([".codex/agentic/issue-briefs", "#{safe_issue_identifier(identifier)}.md"])
    ]

    relative_paths
    |> Enum.find_value(fn relative_path ->
      path = Path.join(workspace, relative_path)

      if File.regular?(path) do
        body = File.read!(path)

        if String.trim(body) != "" do
          %{"path" => relative_path, "bytes" => File.stat!(path).size}
        end
      end
    end)
  rescue
    _error -> nil
  end

  defp fallback_issue_brief_reference(_workspace, _identifier), do: nil

  defp safe_issue_identifier(identifier) when is_binary(identifier) do
    identifier
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
  end

  defp safe_issue_identifier(_identifier), do: ""

  defp feedback_summary(%{type: type, payload: payload}) when is_map(payload) do
    comment = latest_comment(payload)

    %{
      "type" => to_string(type),
      "path" => comment["path"] || payload["path"],
      "line" => comment["line"] || comment["originalLine"] || comment["original_line"] || payload["line"],
      "body" => compact_feedback_body(comment["body"] || payload["body"]),
      "url" => comment["url"] || comment["html_url"] || payload["url"] || payload["html_url"]
    }
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp feedback_summary(_feedback), do: %{"type" => "unknown", "body" => "Review feedback"}

  defp latest_comment(%{"comments" => %{"nodes" => comments}}) when is_list(comments), do: List.last(comments) || %{}
  defp latest_comment(payload) when is_map(payload), do: payload
  defp latest_comment(_payload), do: %{}

  defp compact_feedback_body(body) when is_binary(body) do
    body
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/!\[[^\]]*\]\([^)]+\)/, "")
    |> String.replace("\r\n", "\n")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> truncate(@feedback_body_max_bytes)
  end

  defp compact_feedback_body(_body), do: nil

  defp all_open_correction_summaries(workspace) when is_binary(workspace) do
    workspace
    |> Workspace.open_blocking_corrections_in_workspace()
    |> Enum.map(&open_correction_summary/1)
  rescue
    _error -> []
  end

  defp all_open_correction_summaries(_workspace), do: []

  defp open_correction_summary(%{} = correction) do
    %{
      "correction_id" => correction["correction_id"],
      "summary" => compact_feedback_body(correction["summary"]),
      "findings" => compact_correction_list(correction["findings"]),
      "required_corrections" => compact_correction_list(correction["required_corrections"]),
      "artifacts" => correction["artifacts"],
      "source" => correction["source"],
      "next_action" => correction["next_action"],
      "guard" => correction["guard"]
    }
    |> Enum.reject(fn {_key, value} -> blank?(value) or value == [] or value == %{} end)
    |> Map.new()
  end

  defp compact_correction_list(values) when is_list(values) do
    values
    |> Enum.flat_map(&correction_string_values/1)
    |> Enum.take(4)
    |> Enum.map(&compact_feedback_body/1)
    |> Enum.reject(&blank?/1)
  end

  defp compact_correction_list(value) when is_binary(value), do: [compact_feedback_body(value)]
  defp compact_correction_list(_value), do: []

  defp correction_string_values(values) when is_list(values), do: Enum.flat_map(values, &correction_string_values/1)
  defp correction_string_values(value) when is_binary(value), do: [value]
  defp correction_string_values(_value), do: []

  defp format_corrections(corrections) when is_list(corrections) and corrections != [] do
    corrections
    |> Enum.map_join("\n", fn correction ->
      id = correction["correction_id"] || "unknown-correction"
      summary = correction["summary"] || "Open correction"
      findings = format_correction_lines("Finding", correction["findings"])
      required = format_correction_lines("Required", correction["required_corrections"])

      "- #{id}: #{summary}#{findings}#{required}"
    end)
  end

  defp format_corrections(_corrections), do: "none"

  defp format_correction_lines(label, values) when is_list(values) and values != [] do
    values
    |> Enum.map_join("", fn value -> "\n  #{label}: #{indent_multiline(value, "  ")}" end)
  end

  defp format_correction_lines(_label, _values), do: ""

  defp format_items(items) when is_list(items) and items != [] do
    items
    |> Enum.take(8)
    |> Enum.map_join("\n", fn item ->
      location =
        [item["path"], item["line"]]
        |> Enum.reject(&blank?/1)
        |> Enum.join(":")

      body =
        case item["body"] do
          body when is_binary(body) and body != "" -> "\n  Body: " <> indent_multiline(body, "  ")
          _ -> ""
        end

      url =
        case item["url"] do
          url when is_binary(url) and url != "" -> "\n  URL: #{url}"
          _ -> ""
        end

      "- #{location}#{body}#{url}"
    end)
  end

  defp format_items(_items), do: "- none"

  defp feedback_paths(items) when is_list(items) do
    items
    |> Enum.flat_map(&feedback_item_paths/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp feedback_paths(_items), do: []

  defp feedback_item_paths(%{"path" => path}) when is_binary(path) and path != "" do
    [path]
  end

  defp feedback_item_paths(%{"body" => body}) do
    feedback_body_paths(body)
  end

  defp feedback_item_paths(_item), do: []

  defp feedback_body_paths(body) when is_binary(body) do
    ~r{`([^`]+)`|(?:^|[\s,;:"'(])((?:\./)?[A-Za-z0-9_.@+\-][A-Za-z0-9_\-./()\[\]@+]*\.(?:ts|tsx|js|jsx|mjs|cjs|md|json|yml|yaml|css|scss))}
    |> Regex.scan(body)
    |> Enum.flat_map(fn captures ->
      captures
      |> tl()
      |> Enum.find(&(&1 != ""))
      |> case do
        path when is_binary(path) -> [normalize_feedback_body_path(path)]
        _ -> []
      end
    end)
    |> Enum.filter(&feedback_body_path_like?/1)
  end

  defp feedback_body_paths(_body), do: []

  defp normalize_feedback_body_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.trim_leading("./")
  end

  defp feedback_body_path_like?(path) when is_binary(path) do
    path != "" and
      String.contains?(path, "/") and
      not String.contains?(path, [" ", "\t", "\n", "\r"]) and
      not String.starts_with?(path, ["http://", "https://", "origin/"])
  end

  defp feedback_body_path_like?(_path), do: false

  defp format_inline_items([]), do: "unknown"
  defp format_inline_items(items), do: Enum.map_join(items, ", ", &"`#{&1}`")

  defp format_issue_brief(%{"path" => path, "bytes" => bytes}) when is_binary(path) do
    "`#{path}` (#{bytes} bytes)"
  end

  defp format_issue_brief(_issue_brief), do: "none"

  defp indent_multiline(text, prefix) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> prefix <> String.trim_trailing(line) end)
    |> String.trim_leading()
  end

  defp first_item([item | _]) when is_binary(item) and item != "", do: item
  defp first_item(_items), do: "unknown"

  defp struct_issue(%Issue{} = issue), do: issue

  defp struct_issue(%{} = issue) do
    %Issue{
      id: Map.get(issue, :id) || Map.get(issue, "id"),
      identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      title: Map.get(issue, :title) || Map.get(issue, "title"),
      description: Map.get(issue, :description) || Map.get(issue, "description"),
      state: Map.get(issue, :state) || Map.get(issue, "state"),
      branch_name: Map.get(issue, :branch_name) || Map.get(issue, "branch_name") || Map.get(issue, "branch")
    }
  end

  defp issue_value(%_{} = issue, key), do: issue |> Map.from_struct() |> issue_value(key)

  defp issue_value(issue, key) when is_map(issue) do
    case Map.get(issue, key) || Map.get(issue, to_string(key)) do
      value when is_binary(value) -> String.trim(value)
      nil -> ""
      value -> to_string(value)
    end
  end

  defp issue_value(_issue, _key), do: ""

  defp map_value(%{} = map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key)
    end)
  end

  defp map_value(_map, _keys), do: nil

  defp short_sha(sha) when is_binary(sha) and byte_size(sha) >= 10, do: binary_part(sha, 0, 10)
  defp short_sha(sha) when is_binary(sha) and sha != "", do: sha
  defp short_sha(_sha), do: "unknown"

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp truncate(value, max_bytes) when is_binary(value) and byte_size(value) > max_bytes do
    utf8_prefix(value, max_bytes) <> "..."
  end

  defp truncate(value, _max_bytes), do: value

  defp utf8_prefix(_value, max_bytes) when max_bytes <= 0, do: ""

  defp utf8_prefix(value, max_bytes) do
    candidate = binary_part(value, 0, max_bytes)

    if String.valid?(candidate) do
      candidate
    else
      utf8_prefix(value, max_bytes - 1)
    end
  end

  defp blank?(value), do: value in [nil, ""]
end
