defmodule SymphonyElixir.DispatchPreflight do
  @moduledoc """
  Writes a small machine-owned dispatch checkpoint before Codex starts.
  """

  alias SymphonyElixir.{Config, IssueRequirements, PromptBuilder, ReviewMonitor, Workspace}
  alias SymphonyElixir.Linear.Issue

  @preflight_path ".orocsy/delivery/state/dispatch-preflight.json"
  @event_path ".orocsy/delivery/events/events.jsonl"
  @feedback_body_max_bytes 1_200

  @spec prepare(String.t(), Issue.t() | map()) :: {:ok, map()} | {:error, term()}
  def prepare(workspace, issue) when is_binary(workspace) do
    with :ok <- ensure_dirs(workspace),
         {:ok, requirements} <- requirements_for(workspace, issue),
         {:ok, inspection} <- inspect_review(workspace, issue, requirements),
         mode <- preflight_mode(workspace, requirements, inspection),
         :ok <- maybe_switch_to_review_head(workspace, inspection, mode) do
      preflight =
        case mode do
          "handoff_recovery" -> handoff_recovery_preflight(workspace, issue, requirements, inspection)
          "review_rework" -> review_rework_preflight(workspace, issue, requirements, inspection)
          "integration_check" -> integration_check_preflight(workspace, issue, requirements, inspection)
          _ -> fresh_implementation_preflight(workspace, issue, requirements, inspection)
        end

      :ok = write_preflight(workspace, preflight)
      :ok = append_preflight_event(workspace, preflight)
      :ok = merge_current_state(workspace, preflight)

      {:ok, preflight}
    end
  end

  def prepare(_workspace, _issue), do: {:error, :invalid_workspace}

  @spec read(String.t() | nil) :: {:ok, map()} | :none | {:error, term()}
  def read(workspace) when is_binary(workspace) do
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
  rescue
    error -> {:error, {:preflight_read_failed, Exception.message(error)}}
  end

  def read(_workspace), do: :none

  @spec prompt_context(String.t() | nil) :: String.t()
  def prompt_context(workspace) do
    case read(workspace) do
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

  defp maybe_switch_to_review_head(workspace, %{head_ref: branch}, mode)
       when is_binary(workspace) and mode in ["review_rework", "integration_check", "handoff_recovery"] and is_binary(branch) and branch != "" do
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

  defp maybe_switch_to_review_head(_workspace, _inspection, _mode), do: :ok

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

  defp preflight_mode(workspace, requirements, inspection) do
    cond do
      integration_check_mergeability?(requirements, inspection) ->
        "integration_check"

      scoped_review_feedback?(inspection, requirements) ->
        "review_rework"

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
        Enum.filter(feedback, &feedback_in_write_scope?(&1, requirements))

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
    ~r{`([^`]+)`|((?:\./)?[A-Za-z0-9_\-./\[\]*]+(?:/\*\*|/\*|\.[A-Za-z0-9]+)(?:[A-Za-z0-9_\-./\[\]*]*)?)}
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
    |> String.trim()
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
    open_corrections = open_correction_summaries(workspace)
    correction_active? = open_corrections != []

    %{
      "schema_version" => 1,
      "mode" => "review_rework",
      "created_at" => now_iso8601(),
      "issue" => issue_value(issue, :identifier),
      "state" => issue_value(issue, :state),
      "branch" => Map.get(inspection, :head_ref) || requirements["branch"] || issue_value(issue, :branch_name),
      "checkpoint_event" => if(correction_active?, do: "correction-scoped-fix", else: "review-feedback-classified"),
      "first_task" => review_rework_first_task(open_corrections),
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

  defp review_rework_first_task([correction | _]) do
    summary = correction["summary"] || correction["correction_id"] || "open Orocsy correction"

    "Resolve the open Orocsy correction before the review shortcut: #{summary}. Edit only the named in-scope files, run focused validation, resolve the correction after evidence is recorded, then continue PR review handoff. Do not append review-feedback-classified while an open correction remains."
  end

  defp review_rework_first_task(_open_corrections) do
    "Fix only the listed current-head review feedback on the existing PR branch, then run focused validation, push, and request a fresh Codex review. Do not move Linear to Done; review/rework transitions belong to Symphony's review monitor."
  end

  defp handoff_recovery_preflight(workspace, issue, requirements, inspection) do
    open_corrections = open_correction_summaries(workspace)
    correction_active? = open_corrections != []
    feedback = if test_spec_issue?(requirements), do: [], else: Map.get(inspection, :feedback, [])

    %{
      "schema_version" => 1,
      "mode" => "handoff_recovery",
      "created_at" => now_iso8601(),
      "issue" => issue_value(issue, :identifier),
      "state" => issue_value(issue, :state),
      "branch" => handoff_recovery_branch(workspace, issue, requirements, inspection),
      "checkpoint_event" => if(correction_active?, do: "correction-scoped-fix", else: "gate.post-miu"),
      "first_task" => handoff_recovery_first_task(open_corrections, requirements),
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

  defp handoff_recovery_first_task([correction | _], _requirements) do
    summary = correction["summary"] || correction["correction_id"] || "open Orocsy correction"

    "Resolve the open Orocsy correction before dirty handoff recovery: #{summary}. Edit only the named in-scope files, run focused validation, resolve the correction after evidence is recorded, then continue commit/push/review handoff. Do not use older handoff evidence to skip the correction."
  end

  defp handoff_recovery_first_task(_open_corrections, requirements) when is_map(requirements) do
    if test_spec_issue?(requirements) do
      "Recover the existing dirty test-spec checkpoint: inspect git status and focused dirty diffs only. Run the declared focused validation. If the new test assertions fail only because the implementation is intentionally not present yet, record that expected test-spec result, commit and push the test-only change on the existing branch, and do not edit production source or broaden scope."
    else
      handoff_recovery_first_task([], nil)
    end
  end

  defp handoff_recovery_first_task(_open_corrections, _requirements) do
    "Recover the existing dirty/local handoff checkpoint: inspect git status and focused dirty diffs. If the dirty validated checkpoint lists current passed evidence and the diff is unchanged, use that evidence and commit, push, and request/update Codex review. Otherwise run the smallest validation for those files, then either fix exact in-scope validation failures or commit/push after validation passes. Do not restart broad implementation or broaden project discovery."
  end

  defp handoff_recovery_branch(workspace, issue, requirements, inspection) do
    review_head = Map.get(inspection, :head_ref)

    cond do
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
    %{
      "schema_version" => 1,
      "mode" => "integration_check",
      "created_at" => now_iso8601(),
      "issue" => issue_value(issue, :identifier),
      "state" => issue_value(issue, :state),
      "branch" => Map.get(inspection, :head_ref) || requirements["integration_branch"] || requirements["branch"] || issue_value(issue, :branch_name),
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
    %{
      "schema_version" => 1,
      "mode" => "fresh_implementation",
      "created_at" => now_iso8601(),
      "issue" => issue_value(issue, :identifier),
      "state" => issue_value(issue, :state),
      "branch" => fresh_implementation_branch(workspace, issue, requirements),
      "checkpoint_event" => "technical-miu-trace",
      "first_task" =>
        "Start with the first MIU and the first declared write-scope path only; make a scoped code/test change and then record technical-miu-trace, or record an explicit blocker before broad project scanning. Trace-only/read-only MIU notes are not durable progress.",
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
    current_branch(workspace) ||
      shared_existing_branch_from_requirements(requirements) ||
      requirements["branch"] ||
      issue_value(issue, :branch_name)
  end

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
    - Validation command guidance: #{validation_guidance(preflight["toolchain"], open_corrections)}

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
    open_corrections = preflight["open_corrections"] || []
    correction_active? = open_corrections != []

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
    - Dirty workspace recovery is the only task. Use `git status --short --branch` and focused `git diff -- <dirty-file>` reads before any edit; do not run `git log` or `git diff --stat` — the runtime denies them and provides commit/diffstat context in the checkpoint above.
    - First validation command: #{first_item(get_in(requirements, ["validation", "commands"]))}
    - Toolchain preflight: #{format_toolchain(preflight["toolchain"])}
    - Validation command guidance: #{validation_guidance(preflight["toolchain"], open_corrections)}

    Handoff recovery limits:
    - If an open Orocsy correction is listed above, it overrides any dirty validated checkpoint. Start from the exact file path named in the correction, and do not commit, push, request review, or use older validation evidence until the correction is fixed or explicitly blocked.
    - Do not restart the MIU from the issue brief or switch to the issue seed branch while local dirty work exists.
    - Do not broaden into unrelated routes, docs, historical sessions, Linear discovery, or PR polling.
    - If the focused diff is complete and the dirty handoff checkpoint already lists current passed validation/gate evidence for those dirty files, do not rerun the same validation command; use the recorded evidence, then commit, push the current branch, and request/update Codex review.
    - If validation evidence is missing, stale, or the focused diff changed after evidence was recorded, run the smallest validation for the dirty files before committing.
    - If focused validation fails and names exact in-scope files, assertions, missing columns, missing exports, or required contract symbols, make that smallest in-scope fix first, rerun the same focused validation, then continue handoff.
    - Record an Orocsy correction and stop only when validation lacks an actionable in-scope target, a required dependency/credential is missing, permissions block the command, or the needed edit is outside the issue write scope.
    """
    |> String.trim()
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
    text =
      open_corrections
      |> Enum.flat_map(fn correction ->
        [
          correction["summary"],
          correction["findings"],
          correction["required_corrections"]
        ]
        |> List.flatten()
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n")
      |> String.downcase()

    if String.contains?(text, ["playwright", "chrome", "chromium"]) and
         String.contains?(text, ["sandbox", "sigabrt", "executable missing", "local-browsers"]) do
      "For Playwright browser validation blocked by local Chrome/sandbox or missing Chromium, do not rerun the Chrome-default command. Prefix the focused command with `PLAYWRIGHT_CHANNEL=chromium PLAYWRIGHT_BROWSERS_PATH=0` and keep `--workers=1`; if the local browser is still missing, record that blocker instead of opening repeated Chrome sessions."
    else
      ""
    end
  end

  defp playwright_correction_guidance(_open_corrections), do: ""

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
      "expected_test_state",
      "test_activation",
      "write_scope",
      "shared_files",
      "dependencies",
      "mius",
      "validation",
      "out_of_scope",
      "issue_brief"
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

  defp open_correction_summaries(workspace) when is_binary(workspace) do
    workspace
    |> Workspace.open_blocking_corrections_in_workspace()
    |> Enum.take(5)
    |> Enum.map(&open_correction_summary/1)
  rescue
    _error -> []
  end

  defp open_correction_summaries(_workspace), do: []

  defp open_correction_summary(%{} = correction) do
    %{
      "correction_id" => correction["correction_id"],
      "summary" => compact_feedback_body(correction["summary"]),
      "findings" => compact_correction_list(correction["findings"]),
      "required_corrections" => compact_correction_list(correction["required_corrections"]),
      "artifacts" => correction["artifacts"]
    }
    |> Enum.reject(fn {_key, value} -> blank?(value) or value == [] or value == %{} end)
    |> Map.new()
  end

  defp compact_correction_list(values) when is_list(values) do
    values
    |> Enum.flat_map(&correction_string_values/1)
    |> Enum.take(3)
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
    ~r{`([^`]+)`|((?:\./)?[A-Za-z0-9_\-./\[\]]+\.(?:ts|tsx|js|jsx|mjs|cjs|md|json|yml|yaml|css|scss))}
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
