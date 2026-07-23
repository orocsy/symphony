defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{
    Config,
    DispatchPreflight,
    HandoffCertificate,
    RuntimeContract,
    ValidationController,
    Workflow,
    Workspace
  }

  alias SymphonyElixir.Codex.AppServer

  @render_opts [strict_variables: true, strict_filters: true]
  @recent_event_limit 80
  @checkpoint_only_tool_labels [
    "technical-miu-trace",
    "review-feedback-classified",
    "integration-conflict-slice",
    "integration-handoff-preflight"
  ]
  @issue_brief_max_bytes 20_000
  @issue_brief_heading_max_bytes 4_000
  @issue_description_max_bytes 8_000
  @workflow_prompt_inline_max_bytes 18_500
  @compact_issue_description_max_bytes 4_000

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    attempt = Keyword.get(opts, :attempt)
    workspace = Keyword.get(opts, :workspace)

    checkpoint =
      workspace
      |> workspace_recovery_checkpoint()
      |> maybe_clear_in_progress_checkpoint(issue, workspace)
      |> maybe_clear_clean_rework_checkpoint(issue, workspace)
      |> maybe_clear_uncertified_pushed_checkpoint(issue, workspace)

    workflow = Workflow.current()

    prompt =
      workflow
      |> prompt_template!()
      |> render_prompt_template(issue, opts)
      |> maybe_prepend_issue_brief_reference(issue, workspace)
      |> maybe_prepend_retry_prelude(attempt)

    prompt =
      cond do
        dirty_validated_handoff_checkpoint?(checkpoint) ->
          dirty_validated_handoff_prompt(issue, checkpoint, attempt)

        pushed_validated_handoff_checkpoint?(checkpoint) ->
          pushed_validated_handoff_prompt(issue, checkpoint, attempt)

        checkpoint != "" ->
          checkpoint <> "\n\n" <> prompt

        true ->
          prompt
      end

    prompt
    |> maybe_prepend_dispatch_preflight(workspace)
    |> maybe_prepend_policy_violation(opts)
    |> maybe_prepend_runtime_contract_guidance(issue, workspace)
  end

  @spec workspace_recovery_checkpoint(String.t() | nil) :: String.t()
  def workspace_recovery_checkpoint(workspace) when is_binary(workspace) do
    with true <- File.dir?(workspace),
         {:ok, status} <- git_status(workspace) do
      event_summary = recent_passed_event_summary(workspace)
      git_context = runtime_git_context(workspace)
      pushed_handoff? = pushed_handoff_risk?(status)

      local_handoff? =
        local_handoff_risk?(status) or
          (not pushed_handoff? and local_commit_handoff_risk?(workspace))

      cond do
        local_handoff? and event_summary != "" ->
          dirty_validated_handoff_checkpoint(status, event_summary, git_context)

        local_handoff? ->
          unvalidated_local_handoff_checkpoint(status, git_context)

        pushed_handoff? and event_summary != "" ->
          pushed_validated_handoff_checkpoint(status, event_summary, git_context)

        true ->
          ""
      end
    else
      _ -> ""
    end
  end

  def workspace_recovery_checkpoint(_workspace), do: ""

  defp maybe_prepend_runtime_contract_guidance(prompt, issue, workspace)
       when is_binary(prompt) and is_binary(workspace) do
    case RuntimeContract.compile(Map.get(issue, :description)) do
      {:ok, compiled} ->
        certified_ids =
          issue
          |> ValidationController.certified_miu_ids(workspace)
          |> MapSet.new()

        guidance = runtime_contract_guidance(compiled, certified_ids)
        guidance <> "\n\n" <> prompt

      _ ->
        prompt
    end
  rescue
    _error -> prompt
  end

  defp maybe_prepend_runtime_contract_guidance(prompt, _issue, _workspace), do: prompt

  defp runtime_contract_guidance(compiled, certified_ids) do
    remaining = Enum.reject(compiled.contract["mius"], &MapSet.member?(certified_ids, &1["id"]))

    case remaining do
      [miu | _] ->
        """
        Runtime Contract execution gate:

        - Current contract: `#{compiled.contract_hash}`.
        - Implement only MIU `#{miu["id"]}` in this turn.
        - Write scope: #{Enum.map_join(miu["write_scope"], ", ", &"`#{&1}`")}.
        - Required runtime validation: #{Enum.map_join(miu["validations"], "; ", &"`#{&1}`")}.
        - Do not run contract-declared validation inside the Codex worker sandbox. Symphony's validation controller runs it authoritatively after the request.
        - After your focused implementation, create one clean local micro commit. Do not push yet.
        - Then request runtime certification exactly once:
          `python3 .codex/delivery/bin/orocsy.py --repo . event append --type miu.completion_requested --status requested --step #{miu["id"]}`
        - End the turn after the request. Symphony, not the worker, runs authoritative validation and issues `miu.completed`.
        - Do not append `gate.post-miu` as a substitute for MIU completion and do not request GitHub review yourself.
        """
        |> String.trim()

      [] ->
        """
        Runtime Contract final handoff gate:

        - All required MIUs are runtime-certified for contract `#{compiled.contract_hash}`.
        - Keep the worktree clean, push the canonical integration branch, and verify local `HEAD` matches its upstream.
        - Ensure an open pull request exists from the canonical integration branch into `#{compiled.contract["base_branch"]}`. Create it with `gh pr create` if absent; do not substitute a PR for another branch or base.
        - Request final runtime certification exactly once:
          `python3 .codex/delivery/bin/orocsy.py --repo . event append --type handoff.requested --status requested --step final`
        - End the turn after the request. Symphony runs final validations, issues `handoff.ready`, and requests GitHub Codex review.
        - Do not request GitHub review or move Linear to a terminal state yourself.
        """
        |> String.trim()
    end
  end

  defp maybe_clear_in_progress_checkpoint(checkpoint, issue, workspace)
       when is_binary(checkpoint) and checkpoint != "" and is_binary(workspace) do
    if issue_in_progress?(issue) and issue_implementation?(issue) and clean_worktree?(workspace) do
      ""
    else
      checkpoint
    end
  end

  defp maybe_clear_in_progress_checkpoint(checkpoint, _issue, _workspace), do: checkpoint

  defp maybe_clear_clean_rework_checkpoint(checkpoint, issue, workspace)
       when is_binary(checkpoint) and checkpoint != "" and is_binary(workspace) do
    if issue_rework?(issue) and clean_worktree?(workspace) and
         not local_commit_handoff_risk?(workspace) and
         local_handoff_checkpoint?(checkpoint) do
      ""
    else
      checkpoint
    end
  end

  defp maybe_clear_clean_rework_checkpoint(checkpoint, _issue, _workspace), do: checkpoint

  defp maybe_clear_uncertified_pushed_checkpoint(checkpoint, issue, workspace)
       when is_binary(checkpoint) and is_binary(workspace) do
    if pushed_validated_handoff_checkpoint?(checkpoint) and
         not match?({:ok, _certificate}, HandoffCertificate.current(issue, workspace)) do
      ""
    else
      checkpoint
    end
  end

  defp maybe_clear_uncertified_pushed_checkpoint(checkpoint, _issue, _workspace), do: checkpoint

  defp issue_in_progress?(%{state: state}) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> Kernel.==("in progress")
  end

  defp issue_in_progress?(_issue), do: false

  defp issue_implementation?(%{description: description}) when is_binary(description) do
    text = String.downcase(description)

    Regex.match?(~r/ticket\s+type\s*\n+\s*implementation/, text) or
      (String.contains?(text, "ticket_type") and String.contains?(text, "implementation"))
  end

  defp issue_implementation?(_issue), do: false

  defp issue_rework?(%{state: state}) when is_binary(state) do
    state
    |> String.downcase()
    |> String.contains?("rework")
  end

  defp issue_rework?(_issue), do: false

  defp local_handoff_checkpoint?(checkpoint) when is_binary(checkpoint) do
    String.starts_with?(checkpoint, "Dirty validated handoff checkpoint:") or
      String.starts_with?(checkpoint, "Local handoff recovery checkpoint:")
  end

  defp local_handoff_checkpoint?(_checkpoint), do: false

  defp clean_worktree?(workspace) when is_binary(workspace) do
    with {:ok, status} <- git_status(workspace) do
      substantive_status_lines(status) == []
    else
      _ -> false
    end
  end

  defp clean_worktree?(_workspace), do: false

  @spec render_issue_template(
          String.t(),
          SymphonyElixir.Linear.Issue.t() | map() | String.t() | nil,
          keyword()
        ) ::
          String.t()
  def render_issue_template(template, issue_or_identifier, opts \\ []) when is_binary(template) do
    template = parse_template!(template)

    do_render_issue_template(template, issue_or_identifier, opts)
  end

  defp do_render_issue_template(template, issue_or_identifier, opts) do
    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue_or_identifier |> issue_template_context() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp issue_template_context(%_{} = issue) do
    issue
    |> Map.from_struct()
    |> truncate_prompt_description()
  end

  defp issue_template_context(%{issue_identifier: identifier} = issue_context) do
    %{
      id: Map.get(issue_context, :issue_id),
      identifier: identifier,
      description: issue_context |> Map.get(:description) |> truncate_issue_description_for_prompt()
    }
  end

  defp issue_template_context(%{"issue_identifier" => identifier} = issue_context) do
    %{
      id: Map.get(issue_context, "issue_id"),
      identifier: identifier,
      description: issue_context |> Map.get("description") |> truncate_issue_description_for_prompt()
    }
  end

  defp issue_template_context(identifier) when is_binary(identifier),
    do: %{id: nil, identifier: identifier}

  defp issue_template_context(_), do: %{id: nil, identifier: "issue"}

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp render_prompt_template(prompt, issue, opts)
       when byte_size(prompt) > @workflow_prompt_inline_max_bytes do
    compact_workflow_prompt(issue, prompt, opts)
  end

  defp render_prompt_template(prompt, issue, opts) do
    render_issue_template(prompt, issue, opts)
  end

  defp compact_workflow_prompt(issue, workflow_prompt, opts) do
    """
    You are working on Linear issue `#{issue_value(issue, :identifier)}`.

    Symphony compacted the workflow instructions for the first turn because the workflow body is #{byte_size(workflow_prompt)} bytes. Do not inline or summarize the full workflow before doing product work.

    Workflow reference:
    - Path: `#{Path.expand(Workflow.workflow_file_path())}`
    - Read only the specific section needed when a concrete rule is missing.

    Issue snapshot:
    - ID: `#{issue_value(issue, :id)}`
    - Title: #{issue_value(issue, :title)}
    - State: #{issue_value(issue, :state)}
    - Branch: #{issue_value(issue, :branch_name)}
    - URL: #{issue_value(issue, :url)}
    - Labels: #{issue_value(issue, :labels)}
    - Attempt: #{attempt_label(Keyword.get(opts, :attempt))}

    Description:
    #{indent(compact_issue_description(issue_value(issue, :description)))}

    Core workflow policy:
    - Work only the current issue and its declared write scope. Use the Linear issue, focused issue brief, current code, and current PR review as source of truth.
    - Start from `git status --short --branch`, the issue branch, the runtime dispatch preflight Base/PR target branch when listed (otherwise latest `origin/main`), and the focused files named by the issue/brief. Avoid broad logs, historical tickets, unrelated docs, and unrelated GitHub/Linear data.
    - If `.codex/agentic/issue-briefs/#{safe_issue_identifier(issue_value(issue, :identifier))}.md` exists, read that focused brief before broad rediscovery.
    - First substantive progress guard: before optional skills, broad docs, recursive listings, or scanning more than eight implementation files, produce one real checkpoint:
      - Rework/existing PR: use the current-head feedback supplied by the runtime, inspect only the referenced in-scope file ranges, then make the scoped edit or record an explicit blocker. Append `review-feedback-classified` only after a scoped edit/blocker decision exists; classification alone is lifecycle context, not durable product progress.
      - Fresh implementation: first run `git status --short --branch`, switch/create the exact Linear branch from the runtime dispatch preflight Base/PR target branch when listed (otherwise `origin/main`), read the issue brief plus only the first target file/test, then make a scoped code/test edit or record an explicit blocker. Append `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . event append --type tool.finished --status passed --tool "technical-miu-trace"` only after that scoped edit; trace-only/read-only MIU notes are not durable progress.
      - Blocked issue: create an Orocsy inbox correction with the exact blocker and stop.
      - `first-turn-miu-handoff` alone only proves the worker is alive; it is not substantive progress.
    - If the issue shape is missing code-level scope, dependencies are unfinished, approvals/auth/network block required work, or review feedback is outside scope, record a blocker/correction and stop instead of exploring broadly.
    - If any required command fails because a binary is missing, PATH differs, credentials are absent, network/provider access fails, or approval/input is required, record the exact command, stderr/output, failure kind, and next action in an Orocsy blocker/correction before stopping.
    - Implement one MIU at a time. In a fresh implementation first turn, stop after one scoped code/test/doc edit plus `technical-miu-trace`, or after recording a blocker; a later dirty handoff-recovery turn handles focused validation, evidence, commit, push, PR review request, and Linear handoff.
    - For Rework or an existing PR, fetch only current PR review threads/comments for this branch, classify findings, fix accepted in-scope current-code findings, validate, push, request review again, and never move Linear to a terminal state until a fresh review scan is clean.
    - Never merge automatically from inside the worker.
    """
    |> String.trim()
  end

  defp compact_issue_description(description) when is_binary(description) do
    description
    |> String.trim()
    |> case do
      "" ->
        "unknown"

      text ->
        trim_text(
          text,
          @compact_issue_description_max_bytes,
          "[Linear issue description compacted by Symphony prompt builder. Use the issue brief or Linear only if required fields are missing.]"
        )
    end
  end

  defp compact_issue_description(_description), do: "unknown"

  defp maybe_prepend_dispatch_preflight(prompt, workspace) do
    case DispatchPreflight.read_for_prompt(workspace) do
      {:ok, %{"mode" => "review_rework"} = preflight} ->
        if open_blocking_corrections(workspace) == [] do
          checkpoint = review_rework_handoff_checkpoint(workspace)
          preflight_context = DispatchPreflight.prompt_context(workspace)

          [
            checkpoint,
            preflight_context,
            runtime_command_policy_section(workspace),
            review_rework_micro_prompt(checkpoint)
          ]
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n\n")
        else
          [
            open_correction_mode_contract(workspace, preflight),
            open_correction_dispatch_context(workspace, preflight),
            open_correction_micro_prompt(preflight)
          ]
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n\n")
        end

      {:ok, %{"mode" => "integration_check"}} ->
        checkpoint = workspace_recovery_checkpoint(workspace)

        [
          checkpoint,
          DispatchPreflight.prompt_context(workspace),
          integration_check_micro_prompt(),
          strip_leading_checkpoint(prompt, checkpoint)
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      _ ->
        case DispatchPreflight.prompt_context(workspace) do
          "" -> prompt
          context -> context <> "\n\n" <> prompt
        end
    end
  end

  defp review_rework_micro_prompt(checkpoint) do
    if dirty_validated_handoff_checkpoint?(checkpoint) do
      dirty_validated_review_rework_micro_prompt()
    else
      standard_review_rework_micro_prompt()
    end
  end

  defp standard_review_rework_micro_prompt do
    """
    Review rework execution contract:

    - Treat this as a bounded PR review fix, not a fresh implementation turn.
    - If this prompt includes a `Runtime Contract final handoff gate`, that gate is authoritative and replaces every worker-side validation instruction below. Make the scoped review fix, commit and push it, append `handoff.requested`, and stop. Do not run Playwright or other contract-declared validation inside the Codex worker sandbox; Symphony's validation controller validates the review delta outside that sandbox.
    - Before using a dirty/local handoff checkpoint, run `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py symphony guidance --workspace . --json`.
      If guidance or dispatch preflight reports any open Orocsy correction, that
      correction defines the scoped fix. For a structured Runtime Contract final
      handoff, make that fix and explicitly resolve a worker/guidance correction
      before committing and pushing without worker-side validation; only a
      controller-owned review validation correction stays open for controller
      reconciliation. For a legacy ticket, run focused validation and resolve the
      correction only after evidence is recorded. Do not append
      `review-feedback-classified` or retry browser validation-only.
    - If a dirty/local handoff checkpoint appears above, follow that checkpoint first: inspect only the focused local diff and run the smallest contract-declared validation needed for that diff. If validation names exact in-scope files/assertions, make that smallest repair before committing; otherwise commit and push, then follow the structured-versus-legacy handoff rule below.
    - If no open correction and no dirty/local handoff checkpoint appears above, do not append `review-feedback-classified` as a first action. The current-head review feedback is already in this prompt; start from the listed review feedback path, read one short `sed -n` range around that path only, then make the smallest in-scope edit or record a scoped blocker.
    - Do not read workflow docs, issue briefs, previous Codex session JSONL, broad CSS, or unrelated components before the first code/test edit unless the listed feedback path is one of those files.
    - Do not run `rg`, `grep`, `find`, `ls`, `git ls-files`, `gh api`, shell pipelines, or chained shell commands in review-rework mode; the current-head feedback body and target file path are already in this prompt.
    - Do not run `sed`, `cat`, `head`, `tail`, or `nl` on files outside the listed feedback path before the first code/test edit.
    - In this turn, either make the scoped edit and focused test update, or write an explicit Orocsy blocker/correction. Do not stop after analysis.
    - If validation, git push, GitHub, Linear, PATH, auth, or approval fails, record the exact command/failure and next action in an Orocsy blocker/correction before stopping.
    - After a code/test edit on a structured issue with a `Runtime Contract final handoff gate`, commit and push without worker-side validation, request final runtime certification with `python3 .codex/delivery/bin/orocsy.py --repo . event append --type handoff.requested --status requested --step final`, and end the turn. Symphony validates the review delta and requests fresh Codex review. For a legacy issue with no Runtime Contract gate, run only its declared focused validation, then preserve the direct fallback: request review with `gh pr comment <pr-number> --body '@codex review'` after the focused validation and push.
    - Never move a review-rework issue to `Done`, `Closed`, or another terminal Linear state. A fresh review request is not proof of a clean review; Symphony's review monitor owns review/rework transitions after the new review result exists.
    - If the listed feedback is already resolved or outdated at the current head, record that classification, update the handoff state, and stop without editing.
    """
    |> String.trim()
  end

  defp dirty_validated_review_rework_micro_prompt do
    """
    Dirty validated review-rework handoff contract:

    - Treat this as a handoff-finalization turn for an already-edited, already-validated local diff. Do not redo implementation, source reads, broad review scans, issue-brief reads, or broad validation before the handoff.
    - First action: run `git status --short --branch` only to confirm the dirty files still match the runtime-provided checkpoint above.
    - If the dirty file list still matches and the checkpoint lists current passed validation/gate evidence, do not rerun the same validation command and do not read `sed`, `cat`, `nl`, or full file contents again. Use the recorded evidence.
    - Stage only the intended dirty product/test files, commit with a concise issue-prefixed message, and push the existing branch to its configured upstream. If this prompt includes a `Runtime Contract final handoff gate`, request final runtime certification with `python3 .codex/delivery/bin/orocsy.py --repo . event append --type handoff.requested --status requested --step final` and end the turn. For a legacy issue with no Runtime Contract gate, request review with `gh pr comment <pr-number> --body '@codex review'` after the push.
    - For structured contracts, Symphony independently checks the review delta against MIU write scopes, runs the affected MIU and final validations, issues `handoff.ready`, and requests fresh Codex review. Leave the issue non-terminal; a fresh review request is not proof of clean review.
    - Only fall back to a focused `git diff -- <dirty-file>` read or focused validation when `git status` shows different dirty files, staged/unmerged conflict markers, missing validation evidence, or a failed git/push/review command requires a precise blocker.
    - If git push, GitHub, Linear, network/provider access, or approval blocks the handoff, record the exact command/failure and next action in an Orocsy blocker/correction and stop. Do not start another implementation pass.
    """
    |> String.trim()
  end

  defp open_blocking_corrections(workspace) when is_binary(workspace) do
    Workspace.open_blocking_corrections_in_workspace(workspace)
  rescue
    _error -> []
  end

  defp open_blocking_corrections(_workspace), do: []

  defp open_correction_mode_contract(workspace, preflight) do
    checkpoint_event = correction_checkpoint_event(preflight)

    sections =
      [
        """
        Open correction mode (runtime enforced):

        - This workspace has open Orocsy corrections. Resolving the newest applicable correction is the only first task. Review shortcuts are suspended until the correction is resolved.
        - A dirty validated handoff checkpoint remains authoritative evidence. If its focused delta already addresses the correction and its passed evidence is current for that unchanged delta, resolve the correction and continue handoff without making another edit or rerunning the same validation.
        - Do not inspect commit history, diffs versus the base branch, PR/GitHub/Linear state, or handoff status first. The runtime-provided status below is enough to confirm the workspace state.
        - Required worker checkpoint: after the first scoped code/test edit, append `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . event append --type tool.finished --status passed --tool "#{checkpoint_event}"`. Do not append a duplicate checkpoint when current passed evidence already records the correction delta.
        """
        |> String.trim(),
        runtime_workspace_status_context(workspace),
        runtime_command_policy_section(workspace),
        inline_issue_brief(workspace, preflight)
      ]
      |> Enum.reject(&(&1 == ""))

    Enum.join(sections, "\n\n")
  end

  defp correction_checkpoint_event(%{"checkpoint_event" => event})
       when is_binary(event) and event != "", do: event

  defp correction_checkpoint_event(_preflight), do: "correction-scoped-fix"

  defp runtime_workspace_status_context(workspace) do
    case git_status(workspace) do
      {:ok, status} when status != "" ->
        """
        Runtime-provided workspace context (do not re-derive it with git commands):

        - `git status --short --branch` (runtime-provided):
        #{indent(status)}
        """
        |> String.trim()

      _ ->
        ""
    end
  end

  defp open_correction_dispatch_context(workspace, preflight) when is_map(preflight) do
    review = preflight["review"] || %{}

    open_corrections =
      case preflight["open_corrections"] do
        corrections when is_list(corrections) and corrections != [] ->
          corrections

        _ ->
          open_blocking_corrections(workspace)
      end

    """
    Runtime correction dispatch preflight:

    - Mode: review rework with open correction
    - Preflight file: `.orocsy/delivery/state/dispatch-preflight.json`
    - Branch: `#{preflight["branch"] || "unknown"}`
    - PR: #{review["pr_url"] || review["pr_number"] || "unknown"}
    - Reviewed head: `#{short_sha(review["head_sha"])}`
    - Worker-required checkpoint: `#{correction_checkpoint_event(preflight)}` after the first scoped code/test edit or a scoped blocker.
    - First task: #{preflight["first_task"] || "Resolve the open Orocsy correction."}
    - Open Orocsy corrections: #{format_prompt_corrections(open_corrections)}
    - Validation command guidance: #{preflight["validation_command_guidance"] || "Record one concrete blocker and stop if validation cannot run."}
    - Runtime preflight is not worker progress and is not proof that review classification, validation, push, or handoff is complete.

    Current-head review feedback is intentionally omitted in open-correction mode. The correction and inlined issue brief are the only first-turn scope.
    """
    |> String.trim()
  end

  defp open_correction_dispatch_context(_workspace, _preflight), do: ""

  defp format_prompt_corrections([]), do: "none"

  defp format_prompt_corrections(corrections) when is_list(corrections) do
    corrections
    |> newest_corrections_first()
    |> Enum.take(3)
    |> Enum.map_join("\n", &format_prompt_correction/1)
  end

  defp format_prompt_corrections(_corrections), do: "unknown"

  defp format_prompt_correction(correction) when is_map(correction) do
    id = correction["correction_id"] || "open-correction"
    summary = correction["summary"] || "Open correction"
    findings = correction["findings"] || []
    required = correction["required_corrections"] || []

    finding_lines =
      findings
      |> Enum.take(4)
      |> Enum.map_join(
        "\n",
        &"  Finding: #{trim_text(to_string(&1), 800, "[finding truncated]")}"
      )

    required_lines =
      required
      |> Enum.take(4)
      |> Enum.map_join(
        "\n",
        &"  Required: #{trim_text(to_string(&1), 800, "[required correction truncated]")}"
      )

    ["- #{id}: #{summary}", finding_lines, required_lines]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_prompt_correction(correction), do: "- #{inspect(correction)}"

  defp newest_corrections_first(corrections) do
    Enum.sort_by(corrections, &correction_sort_key/1, :desc)
  end

  defp correction_sort_key(%{} = correction) do
    cond do
      is_binary(correction["created_at"]) and correction["created_at"] != "" ->
        correction["created_at"]

      is_binary(correction["correction_id"]) and correction["correction_id"] != "" ->
        correction["correction_id"]

      is_binary(correction["path"]) ->
        Path.basename(correction["path"])

      true ->
        ""
    end
  end

  defp correction_sort_key(_correction), do: ""

  defp short_sha(sha) when is_binary(sha) and byte_size(sha) >= 10, do: binary_part(sha, 0, 10)
  defp short_sha(sha) when is_binary(sha) and sha != "", do: sha
  defp short_sha(_sha), do: "unknown"

  @command_policy_pattern_max_bytes 200

  defp runtime_command_policy_section(workspace) do
    patterns = effective_command_policy_patterns(workspace)

    if patterns == [] do
      ""
    else
      {readable, generated} =
        Enum.split_with(patterns, &(byte_size(&1) <= @command_policy_pattern_max_bytes))

      rendered = Enum.map_join(readable, "\n", &"  #{&1}")

      generated_note =
        if generated == [] do
          ""
        else
          "\n- Plus #{length(generated)} generated workspace path guard(s) that restrict `sed`/read commands to the exact files named by the correction, brief, and review feedback. Read only those named files."
        end

      bounded_log_note =
        if AppServer.bounded_git_log_exception_available?(workspace) do
          "\n- Narrow exception: local checkpoint metadata may use only `git log -N --oneline [--decorate|--no-decorate]` with `N` from 1 through 20. Revision selectors, pathspecs, patch/stat/name output, other flags, and unbounded history remain denied."
        else
          ""
        end

      """
      Runtime command policy (enforced by the Symphony command guard):

      - Commands matching any regex below are denied in this mode except for an explicitly documented narrow exception. Running any other match interrupts the worker turn and, after repeated violations, parks the issue for human review.
      #{rendered}#{generated_note}
      #{bounded_log_note}
      - The runtime-provided context above replaces the output of all other denied git history/diff commands. Do not attempt equivalents or workarounds; make the scoped correction fix instead.
      """
      |> String.trim()
    end
  end

  defp effective_command_policy_patterns(workspace) do
    AppServer.effective_forbidden_command_patterns_for(workspace)
  rescue
    _error -> []
  end

  defp inline_issue_brief(workspace, preflight) do
    with path when is_binary(path) and path != "" <-
           issue_brief_path_for_preflight(workspace, preflight),
         full_path = Path.join(workspace, path),
         true <- File.regular?(full_path),
         {:ok, content} <- File.read(full_path) do
      content = content |> String.trim() |> trim_issue_brief()

      """
      Issue brief (`#{path}`), inlined by the runtime — do not re-read it from disk:

      #{content}
      """
      |> String.trim()
    else
      _ -> ""
    end
  rescue
    _error -> ""
  end

  defp issue_brief_path_for_preflight(workspace, preflight) do
    preflight_brief_path =
      preflight
      |> Map.get("requirements", %{})
      |> case do
        %{"issue_brief" => %{"path" => path}} when is_binary(path) -> path
        _ -> nil
      end

    identifier =
      case Map.get(preflight, "issue") do
        identifier when is_binary(identifier) and identifier != "" -> identifier
        _ -> nil
      end

    candidates =
      [
        preflight_brief_path,
        identifier &&
          Path.join(".codex/agentic/issue-briefs", "#{safe_issue_identifier(identifier)}.md"),
        ".orocsy/delivery/issue-brief.md"
      ]
      |> Enum.reject(&is_nil/1)

    Enum.find(candidates, fn candidate -> File.regular?(Path.join(workspace, candidate)) end)
  end

  defp open_correction_micro_prompt(preflight) do
    if controller_review_validation_correction?(preflight) do
      controller_review_validation_correction_micro_prompt()
    else
      standard_open_correction_micro_prompt(preflight)
    end
  end

  defp controller_review_validation_correction_micro_prompt do
    """
    Controller-owned review validation correction contract:

    - Use the supplied controller command output and declared write-scope paths to make the smallest review fix.
    - Do not rerun controller-owned validation inside the Codex worker and do not resolve the correction manually.
    - Create and push one scoped review-rework commit, append the exact `handoff.requested` event from the Runtime Contract final gate, and stop.
    - Symphony's validation controller reruns authoritative validation and resolves the matching correction only after certification passes.
    - If no code/test change can address the supplied output, record one precise blocker and stop without retrying validation.
    """
    |> String.trim()
  end

  defp standard_open_correction_micro_prompt(preflight) do
    checkpoint_event = correction_checkpoint_event(preflight)
    correction_handoff = standard_correction_handoff_guidance(preflight)

    """
    Open correction execution contract:

    - The open Orocsy correction overrides review-rework shortcuts, but not a current dirty validated checkpoint that already proves the named correction delta. Do not append `review-feedback-classified`, retry browser validation-only runs, or commit/push/request review before correction evidence exists.
    - If the runtime context contains a dirty validated checkpoint, inspect only its focused delta first. When the delta already addresses the correction and the listed passed evidence is current for the unchanged delta, resolve the correction from that evidence and continue handoff without another edit or duplicate validation.
    - Before the first edit, read only the exact source files named by the correction and the inlined issue brief. Do not read test files first unless a source file is missing a required local type or helper.
    - Make the smallest in-scope source edit or record a scoped blocker. Do not stop after analysis and do not spend the first turn reading every allowed file.
    - Immediately after the first scoped code/test edit, append the `#{checkpoint_event}` durable event exactly as specified above.
    - After the checkpoint: #{correction_handoff}
    - Do not run `git log`, base-branch `git diff`, `git diff --stat`, `rg`, `grep`, `find`, `ls`, `gh api`, shell pipelines, or chained shell commands; the runtime denies them in this mode and the needed context is already inlined above.
    - If validation, git push, GitHub, Linear, PATH, auth, or approval fails, record the exact command/failure and next action in an Orocsy blocker/correction before stopping.
    - Never move the issue to a terminal Linear state from this mode; a fresh review request is not proof of a clean review.
    """
    |> String.trim()
  end

  defp standard_correction_handoff_guidance(%{"requirements" => %{"runtime_contract_status" => "structured"}}) do
    "resolve this non-controller correction with the scoped-fix evidence, commit and push without worker-side validation, append the Runtime Contract `handoff.requested` event, and stop so Symphony's validation controller validates the review delta"
  end

  defp standard_correction_handoff_guidance(_preflight) do
    "update the exact test files named by the correction/brief, run only the focused validation, record the evidence, resolve the correction, and continue the legacy PR review handoff"
  end

  defp controller_review_validation_correction?(%{"open_corrections" => corrections})
       when is_list(corrections) do
    Enum.any?(corrections, fn correction ->
      correction["source"] == "symphony.runtime.validation-controller" and
        correction["next_action"] == "retry" and
        get_in(correction, ["guard", "miu_id"]) == "__review_rework__"
    end)
  end

  defp controller_review_validation_correction?(_preflight), do: false

  defp maybe_prepend_policy_violation(prompt, opts) when is_binary(prompt) do
    case Keyword.get(opts, :policy_violation) do
      %{command: command, pattern: pattern, attempt: attempt, max_attempts: max_attempts} = policy_violation ->
        scope_access = Map.get(policy_violation, :scope_access) || Map.get(policy_violation, "scope_access")
        scope_access_lines = policy_violation_scope_access_lines(scope_access)

        final_warning =
          if attempt >= max_attempts do
            "- This is the final in-run recovery attempt. Another denied command parks the issue for human review."
          else
            "- Running another denied command interrupts the turn again and, after #{max_attempts} violations, parks the issue for human review."
          end

        """
        Runtime command policy interrupt (recovery attempt #{attempt} of #{max_attempts}):

        - The previous worker turn was interrupted because it ran a command denied by the runtime command guard.
        - Denied command: `#{command}`
        - Matched policy: `#{pattern}`
        #{scope_access_lines}
        #{policy_violation_command_guidance(scope_access)}
        - Continue directly with the smallest in-scope fix for the open correction or current task, then its focused validation.
        #{final_warning}
        """
        |> String.trim()
        |> Kernel.<>("\n\n" <> prompt)

      _ ->
        prompt
    end
  end

  defp maybe_prepend_policy_violation(prompt, _opts), do: prompt

  defp policy_violation_scope_access_lines(%{} = scope_access) do
    operation = Map.get(scope_access, "operation") || Map.get(scope_access, :operation)

    if is_binary(operation) do
      "- Requested scope access: #{operation}#{scope_access_paths(scope_access)}; decision #{scope_access_decision(scope_access)}#{scope_access_reason(scope_access)}"
    else
      ""
    end
  end

  defp policy_violation_scope_access_lines(_scope_access), do: ""

  defp policy_violation_command_guidance(%{} = scope_access) do
    if scope_access_decision(scope_access) == "allow_once" do
      "- The runtime added this as read-only context for this retry. You may rerun that exact bounded read/search once if still needed; do not broaden it or edit that path."
    else
      default_policy_violation_command_guidance()
    end
  end

  defp policy_violation_command_guidance(_scope_access), do: default_policy_violation_command_guidance()

  defp default_policy_violation_command_guidance do
    "- Do not run that command again, and do not run other git history/diff/discovery commands. The runtime-provided context in this prompt already contains the repository state."
  end

  defp scope_access_paths(scope_access) do
    case Map.get(scope_access, "paths") || Map.get(scope_access, :paths) do
      paths when is_list(paths) and paths != [] -> " #{Enum.join(paths, ", ")}"
      _ -> ""
    end
  end

  defp scope_access_decision(scope_access) do
    Map.get(scope_access, "decision") || Map.get(scope_access, :decision) || "block"
  end

  defp scope_access_reason(scope_access) do
    scope_access
    |> scope_access_reason_class()
    |> reason_suffix()
  end

  defp scope_access_reason_class(scope_access) do
    Map.get(scope_access, "reason_class") || Map.get(scope_access, :reason_class)
  end

  defp reason_suffix(reason_class) when is_binary(reason_class) and reason_class != "",
    do: " (#{reason_class})"

  defp reason_suffix(_reason_class), do: ""

  @git_context_commit_limit 10
  @git_context_diffstat_limit 20

  defp runtime_git_context(workspace) when is_binary(workspace) do
    case git_context_base(workspace) do
      nil ->
        ""

      base ->
        [
          git_context_section(
            "Local commits ahead of `#{base}` (runtime-provided; do not run `git log`)",
            git_lines(
              workspace,
              ["log", "--oneline", "--no-decorate", "#{base}..HEAD"],
              @git_context_commit_limit
            )
          ),
          git_context_section(
            "Diffstat versus `#{base}` (runtime-provided; do not run `git diff`)",
            git_lines(
              workspace,
              ["diff", "--stat", "#{base}...HEAD"],
              @git_context_diffstat_limit
            )
          ),
          git_context_section(
            "Uncommitted diffstat versus `HEAD` (runtime-provided)",
            git_lines(workspace, ["diff", "--stat", "HEAD"], @git_context_diffstat_limit)
          )
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
    end
  end

  defp runtime_git_context(_workspace), do: ""

  defp git_context_base(workspace) do
    workspace
    |> git_context_base_candidates()
    |> Enum.find(&git_ref_exists?(workspace, &1))
  end

  defp git_context_base_candidates(workspace) when is_binary(workspace) do
    preflight_base_candidates(workspace) ++ ["origin/main", "main"]
  end

  defp git_context_base_candidates(_workspace), do: ["origin/main", "main"]

  defp preflight_base_candidates(workspace) do
    with {:ok, %{} = preflight} <- DispatchPreflight.read(workspace),
         base when is_binary(base) and base != "" <- preflight_base_branch(preflight) do
      base
      |> String.trim()
      |> base_branch_ref_candidates()
    else
      _ -> []
    end
  rescue
    _error -> []
  end

  defp preflight_base_branch(%{} = preflight) do
    requirements = Map.get(preflight, "requirements", %{})

    [
      Map.get(requirements, "base_branch"),
      Map.get(requirements, "integration_branch"),
      Map.get(preflight, "base_branch"),
      Map.get(preflight, "target_branch")
    ]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
  end

  defp base_branch_ref_candidates("origin/" <> _ = base), do: [base, String.replace_prefix(base, "origin/", "")]
  defp base_branch_ref_candidates(base), do: ["origin/#{base}", base]

  defp git_context_section(_title, ""), do: ""

  defp git_context_section(title, content) do
    "- #{title}:\n#{indent(content)}"
  end

  defp git_lines(workspace, args, limit) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        lines =
          output
          |> String.trim()
          |> String.split("\n", trim: true)

        shown = Enum.take(lines, limit)
        hidden = length(lines) - length(shown)

        suffix =
          if hidden > 0 do
            "\n[... #{hidden} more lines truncated by the runtime]"
          else
            ""
          end

        Enum.join(shown, "\n") <> suffix

      {_error, _exit_code} ->
        ""
    end
  rescue
    _error -> ""
  end

  defp strip_leading_checkpoint(prompt, "") when is_binary(prompt), do: prompt

  defp strip_leading_checkpoint(prompt, checkpoint)
       when is_binary(prompt) and is_binary(checkpoint) do
    if String.starts_with?(prompt, checkpoint) do
      prompt
      |> String.replace_prefix(checkpoint, "")
      |> String.trim_leading()
    else
      prompt
    end
  end

  defp strip_leading_checkpoint(prompt, _checkpoint), do: prompt

  defp review_rework_handoff_checkpoint(workspace) do
    workspace
    |> workspace_recovery_checkpoint()
    |> case do
      checkpoint when is_binary(checkpoint) ->
        cond do
          clean_worktree?(workspace) and dirty_or_local_handoff_checkpoint?(checkpoint) -> ""
          dirty_or_local_handoff_checkpoint?(checkpoint) -> checkpoint
          true -> ""
        end

      _checkpoint ->
        ""
    end
  end

  defp dirty_or_local_handoff_checkpoint?(checkpoint) when is_binary(checkpoint) do
    String.starts_with?(checkpoint, "Dirty validated handoff checkpoint:") or
      String.starts_with?(checkpoint, "Local handoff recovery checkpoint:")
  end

  defp dirty_or_local_handoff_checkpoint?(_checkpoint), do: false

  defp integration_check_micro_prompt do
    """
    Integration check execution contract:

    - Treat PR mergeability conflict resolution as the first task; it supersedes pushed-handoff waiting.
    - If a dirty/local handoff checkpoint appears above, follow that checkpoint first: inspect only the focused local diff and run the smallest validation needed for that diff. If validation names exact in-scope files/assertions, make that smallest repair before committing; otherwise commit, push, and request fresh review after validation passes.
    - Start from `git status --short --branch`, then fetch the PR target branch and expose conflicts with a bounded merge/rebase check.
    - Immediately after confirming the current branch/status, and before any GitHub PR lookup, conflict scan, diff, or file read, append `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . event append --type handoff.integration-check-started --status passed --phase handoff --step "integration branch/status confirmed" --tool "integration-handoff-preflight"`.
    - Before broad reads, append a `technical-miu-trace` event naming only the conflicted/write-scope paths, validation commands, PR number or missing-PR finding, and same-branch push target.
    - Resolve only the in-scope conflict files and directly required helper/test files from the issue brief.
    - For full-suite Vitest validation, if the preflight/brief declares `pnpm test` and `package.json` has `"test": "vitest run"`, run `pnpm test -- --configLoader runner` instead and record it as satisfying the declared `pnpm test`.
    - Run the focused validation named by the preflight/brief, then commit, push to the existing PR branch, and request `@codex review`.
    - Do not create a new branch, open a duplicate PR, update unrelated product code, move Linear to a terminal state, or merge the PR automatically.
    - If GitHub/Linear/network/validation blocks completion, record an Orocsy blocker with the exact command and next action.
    """
    |> String.trim()
  end

  defp maybe_prepend_retry_prelude(prompt, attempt)
       when is_binary(prompt) and is_integer(attempt) and attempt > 0 do
    if retry_prelude_present?(prompt, attempt) do
      prompt
    else
      retry_prelude(attempt) <> "\n\n" <> prompt
    end
  end

  defp maybe_prepend_retry_prelude(prompt, _attempt), do: prompt

  defp maybe_prepend_issue_brief_reference(prompt, issue, workspace) do
    case issue_brief_reference(issue, workspace) do
      "" -> prompt
      reference -> maybe_prepend_issue_brief_reference_content(prompt, reference)
    end
  end

  defp maybe_prepend_issue_brief_reference_content(prompt, reference) do
    if prompt_already_contains_issue_brief_reference?(prompt, reference) do
      prompt
    else
      issue_brief_reference_prompt(reference) <> "\n\n" <> prompt
    end
  end

  defp issue_brief_reference(%{identifier: identifier}, workspace)
       when is_binary(identifier) and is_binary(workspace) do
    relative_paths = [
      Path.join([".codex/agentic/issue-briefs", "#{safe_issue_identifier(identifier)}.md"]),
      ".orocsy/delivery/issue-brief.md"
    ]

    with relative_path when is_binary(relative_path) <-
           Enum.find(relative_paths, &File.regular?(Path.join(workspace, &1))),
         path = Path.join(workspace, relative_path),
         {:ok, stat} <- File.stat(path) do
      %{
        bytes: stat.size,
        heading: issue_brief_heading(path),
        path: relative_path
      }
    else
      _ -> ""
    end
  rescue
    _error -> ""
  end

  defp issue_brief_reference(_issue, _workspace), do: ""

  defp safe_issue_identifier(identifier) do
    identifier
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
  end

  defp trim_issue_brief(content) when byte_size(content) > @issue_brief_max_bytes do
    trim_text(
      content,
      @issue_brief_max_bytes,
      "[Issue brief truncated by Symphony prompt builder.]"
    )
  end

  defp trim_issue_brief(content), do: content

  defp trim_text(content, max_bytes, notice)
       when is_binary(content) and is_integer(max_bytes) and max_bytes > 0 and
              byte_size(content) > max_bytes do
    binary_part(content, 0, max_bytes) <> "\n\n#{notice}"
  end

  defp trim_text(content, _max_bytes, _notice), do: content

  defp issue_brief_heading(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(file, @issue_brief_heading_max_bytes) do
          content when is_binary(content) -> markdown_heading(content)
          _ -> nil
        end
      after
        File.close(file)
      end
    else
      _ -> nil
    end
  end

  defp issue_brief_reference_prompt(%{bytes: bytes, heading: heading, path: path}) do
    heading_line =
      case heading do
        nil -> ""
        "" -> ""
        heading -> "\n- Heading: #{heading}"
      end

    """
    Issue technical brief is available on disk. Do not inline or rediscover broad context before using it.

    - Path: `#{path}`
    - Size: #{bytes} bytes#{heading_line}
    """
    |> String.trim()
  end

  defp prompt_already_contains_issue_brief_reference?(prompt, %{heading: heading, path: path}) do
    String.contains?(prompt, path) or
      (is_binary(heading) and heading != "" and String.contains?(prompt, heading))
  end

  defp markdown_heading(markdown) when is_binary(markdown) do
    markdown
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      line = String.trim(line)

      if String.starts_with?(line, "#") do
        line
        |> String.trim_leading("#")
        |> String.trim()
        |> case do
          "" -> nil
          heading -> heading
        end
      end
    end)
  end

  defp markdown_heading(_markdown), do: nil

  defp truncate_prompt_description(%{description: description} = issue_context) do
    Map.put(issue_context, :description, truncate_issue_description_for_prompt(description))
  end

  defp truncate_prompt_description(%{"description" => description} = issue_context) do
    Map.put(issue_context, "description", truncate_issue_description_for_prompt(description))
  end

  defp truncate_prompt_description(issue_context), do: issue_context

  defp truncate_issue_description_for_prompt(description) when is_binary(description) do
    if byte_size(description) > @issue_description_max_bytes do
      binary_part(description, 0, @issue_description_max_bytes) <>
        "\n\n[Linear issue description truncated by Symphony prompt builder. Read the focused issue brief or query Linear only if a required field is missing.]"
    else
      description
    end
  end

  defp truncate_issue_description_for_prompt(description), do: description

  defp retry_prelude_present?(prompt, attempt) do
    normalized = String.downcase(prompt)

    String.contains?(normalized, "continuation context") or
      String.contains?(normalized, "retry continuation") or
      String.contains?(normalized, "retry attempt ##{attempt}") or
      String.contains?(normalized, "handoff-recovery") or
      String.contains?(normalized, "handoff recovery")
  end

  defp retry_prelude(attempt) do
    """
    Continuation context:

    - This is retry attempt ##{attempt} because the issue is still active after an interrupted or failed agent turn.
    - Resume from the current workspace state; inspect `git status --short --branch` and `.orocsy/delivery/events/events.jsonl` before editing. Use the runtime-provided checkpoint context in this prompt for commit/diff state. Run bounded `git log` only when the runtime command policy explicitly advertises it; `git diff --stat` and all other denied history commands remain unavailable.
    - If the workspace is dirty or ahead and recent `tool.finished`, `gate.post-miu`, `gate.required-evidence`, or `gate.declared-scope` events passed, treat that as a dirty handoff checkpoint.
    - At a dirty handoff checkpoint, do not redo implementation, broad PR/Linear review scans, or broad validations first. Run only `git status --short --branch` and a focused `git diff -- <dirty-file>` read; commit and diffstat context is already provided by the runtime checkpoint. If the checkpoint already lists passed validation/gate evidence for the dirty files and the diff has not changed since that evidence, do not rerun the same validation command; use the recorded evidence and proceed to commit, push, and review request. Rerun focused validation only when evidence is missing, stale, or the focused diff is incomplete/invalid.
    - If no unmerged files remain and a dirty diff already exists, validation comes before more code changes. Only edit again when that focused validation fails and names the exact broken path or assertion.
    - After focused validation passes, immediately `git add -A`, commit, push the existing branch to its configured PR head, and request/update PR review.
    - For review-rework handoffs, never set Linear to a terminal state; a fresh review request is not proof that the new review is clean.
    - If product changes, validation, or gates already exist, enter handoff-recovery mode and only complete the pending commit, push, PR review request, or Linear update.
    - Before broad rediscovery, record real progress: a current PR review classification, scoped file/test change, validation/gate result after a change, handoff event, or explicit blocker correction. Do not rely on `first-turn-miu-handoff`; it only proves the worker is alive.
    - If a provider, network, or permission failure still blocks handoff, record an Orocsy inbox item or workpad blocker with next action `retry` and stop.
    """
    |> String.trim()
  end

  defp pushed_validated_handoff_checkpoint?(checkpoint) when is_binary(checkpoint) do
    String.starts_with?(checkpoint, "Pushed validated handoff checkpoint:")
  end

  defp pushed_validated_handoff_checkpoint?(_checkpoint), do: false

  defp dirty_validated_handoff_checkpoint?(checkpoint) when is_binary(checkpoint) do
    String.starts_with?(checkpoint, "Dirty validated handoff checkpoint:")
  end

  defp dirty_validated_handoff_checkpoint?(_checkpoint), do: false

  defp dirty_validated_handoff_prompt(issue, checkpoint, attempt) do
    """
    #{checkpoint}

    Minimal dirty handoff-finalization mode:

    - This is #{attempt_label(attempt)} for an already-edited local diff with recent passed validation/gate evidence. Keep scope to the current ticket, current workspace branch, existing dirty files, and existing PR handoff only.
    - Active issue: `#{issue_value(issue, :identifier)}` — #{issue_value(issue, :title)}
    - Issue URL: #{issue_value(issue, :url)}
    - Current state: #{issue_value(issue, :state)}

    Required sequence:

    - Run `git status --short --branch`.
    - If the dirty file list still matches the checkpoint and validation evidence is present, do not read source/test files and do not rerun the same validation. Stage the intended dirty files, commit, push the current upstream branch, request/update Codex review, then update Linear/Orocsy handoff with branch, PR, commit SHA, and recorded validation evidence.
    - If status differs, validation evidence is missing, or git/GitHub/Linear fails, record a precise blocker/correction and stop.

    Stop rules:

    - Do not read AGENTS.md, skills, workflow docs, issue briefs, broad project docs, historical delivery logs, unrelated tickets, or broad GitHub/Linear context.
    - Do not redo implementation or open a new PR/branch.
    - Never move a review-rework issue to a terminal state; a fresh review request is not proof of a clean review.
    """
    |> String.trim()
  end

  defp pushed_validated_handoff_prompt(issue, checkpoint, attempt) do
    """
    #{checkpoint}

    Minimal review handoff mode:

    - This is #{attempt_label(attempt)} for an already pushed review/handoff checkpoint. Keep scope to the current ticket, current workspace branch/code, and the current GitHub/Codex PR review only.
    - Active issue: `#{issue_value(issue, :identifier)}` — #{issue_value(issue, :title)}
    - Issue URL: #{issue_value(issue, :url)}
    - Current state: #{issue_value(issue, :state)}
    - Description:
    #{indent(truncate_issue_description(issue_value(issue, :description)))}

    Allowed context:

    - `git status --short --branch`, current branch/head, the runtime-provided commit list/diffstat in the checkpoint above, focused `git diff -- <file>` reads, and exact files named by current review feedback. Run bounded `git log` only when the runtime command policy explicitly advertises it; `git diff --stat` and all other denied history commands remain unavailable.
    - The existing PR for the current branch, including current Codex/GitHub review threads, comments, reviews, and head SHA.
    - Focused tests or type/lint checks that cover changed review-fix files.

    Stop rules:

    - Do not read AGENTS.md, skills, broad project docs, historical delivery logs, unrelated tickets, COD-149/COD-150 history, or broad GitHub/Linear context.
    - First action for active review feedback: use the runtime-supplied current PR review threads, read only the referenced in-scope file range, then make the scoped fix or record an explicit blocker. Do not append `review-feedback-classified` as a standalone first action.
    - If the PR exists, the pushed head matches this workspace, and all current review feedback is resolved/outdated/clean, update Linear to the configured review state with branch, PR, commit, validation evidence, and stop.
    - If current review feedback remains, classify only that feedback, edit only the referenced code paths, run focused validation, commit, push, request/update Codex review, leave the issue non-terminal, and stop.
    - If GitHub, Linear, git push, or approval blocks the handoff, record a retry/blocker correction and stop instead of rediscovering the project.
    """
    |> String.trim()
  end

  defp attempt_label(attempt) when is_integer(attempt) and attempt > 0,
    do: "retry attempt ##{attempt}"

  defp attempt_label(_attempt), do: "the first turn"

  defp issue_value(%_{} = issue, key), do: issue |> Map.from_struct() |> issue_value(key)

  defp issue_value(issue, key) when is_map(issue) do
    issue
    |> Map.get(key)
    |> case do
      nil -> "unknown"
      value when is_binary(value) and value != "" -> value
      value when is_binary(value) -> "unknown"
      value -> to_string(value)
    end
  end

  defp issue_value(_issue, _key), do: "unknown"

  defp truncate_issue_description(description) when is_binary(description) do
    description
    |> String.trim()
    |> case do
      "" -> "unknown"
      text -> trim_issue_brief(text)
    end
  end

  defp truncate_issue_description(_description), do: "unknown"

  defp git_status(workspace) do
    case System.cmd("git", ["status", "--short", "--branch", "--untracked-files=all"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {status, 0} -> {:ok, String.trim(status)}
      {error, _exit_code} -> {:error, error}
    end
  rescue
    error -> {:error, error}
  end

  defp local_handoff_risk?(status) when is_binary(status) do
    lines = String.split(status, "\n", trim: true)
    branch_line = List.first(lines) || ""
    dirty_lines = substantive_status_lines(status)

    dirty_lines != [] or String.contains?(branch_line, ["ahead", "diverged"])
  end

  defp local_handoff_risk?(_status), do: false

  defp local_commit_handoff_risk?(workspace) when is_binary(workspace) do
    base_refs =
      ["@{upstream}", "origin/main", "main"]
      |> Enum.filter(&git_ref_exists?(workspace, &1))

    if base_refs == [] do
      false
    else
      args = ["log", "-1", "--format=%H", "HEAD"] ++ Enum.flat_map(base_refs, &[~s(--not), &1])

      case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
        {output, 0} -> String.trim(output) != ""
        {_error, _exit_code} -> false
      end
    end
  rescue
    _error -> false
  end

  defp local_commit_handoff_risk?(_workspace), do: false

  defp git_ref_exists?(workspace, ref) do
    case System.cmd("git", ["rev-parse", "--verify", "--quiet", ref],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      {_output, _exit_code} -> false
    end
  rescue
    _error -> false
  end

  defp pushed_handoff_risk?(status) when is_binary(status) do
    lines = String.split(status, "\n", trim: true)
    branch_line = List.first(lines) || ""
    dirty_lines = substantive_status_lines(status)
    branch = status_branch_name(branch_line)

    dirty_lines == [] and clean_tracking_branch?(branch_line) and handoff_branch?(branch)
  end

  defp pushed_handoff_risk?(_status), do: false

  defp clean_tracking_branch?(branch_line) when is_binary(branch_line) do
    String.contains?(branch_line, "...") and
      not String.contains?(branch_line, ["ahead", "behind", "diverged"])
  end

  defp handoff_branch?(branch) when is_binary(branch) do
    branch = String.trim(branch)
    branch != "" and branch not in ["main", "master", "trunk", "develop", "dev"]
  end

  defp handoff_branch?(_branch), do: false

  defp status_branch_name("## " <> rest) do
    rest
    |> String.split(["...", " "], parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
  end

  defp status_branch_name(_branch_line), do: nil

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

  defp dirty_validated_handoff_checkpoint(status, event_summary, git_context) do
    """
    Dirty validated handoff checkpoint:

    - Current workspace has local work that must be handed off before more investigation.
    - `git status --short --branch`:
    #{indent(status)}
    #{git_context}
    - Recent passed validation/gate evidence:
    #{indent(event_summary)}
    - The commit list and diffstat above are runtime-provided. Run bounded `git log` only when the runtime command policy explicitly advertises it; `git diff --stat`, base-branch diff/history commands, and all other denied history forms remain unavailable.
    - First action: inspect the focused diff with `git diff -- <dirty-file>` and compare it to the recent passed validation/gate evidence listed above.
    - If the focused diff is unchanged since the listed passed evidence, do not rerun the same validation command before committing; use the recorded evidence and proceed to commit, push, PR review request/update, and Linear handoff.
    - Rerun focused validation only when the evidence is missing, stale, or the focused diff is incomplete/invalid.
    - Do not run file-discovery commands such as `git ls-files`, `rg`, `grep`, `find`, or `ls`; the dirty file path is already listed in `git status`.
    - Commit and push only after focused validation passes or after this checkpoint lists current passed evidence covering the focused dirty files.
    - Do not query broad Linear/GitHub context or rerun broad validations before the focused validation unless the focused diff is incomplete or invalid.
    - After the push, request/update PR review and Linear handoff. If network/provider/permission blocks that handoff, record a retry blocker and stop.
    """
    |> String.trim()
  end

  defp unvalidated_local_handoff_checkpoint(status, git_context) do
    """
    Local handoff recovery checkpoint:

    - Current workspace has local work but no recent passed Orocsy validation/gate evidence was found.
    - `git status --short --branch`:
    #{indent(status)}
    #{git_context}
    - The commit list and diffstat above are runtime-provided. Run bounded `git log` only when the runtime command policy explicitly advertises it; `git diff --stat`, base-branch diff/history commands, and all other denied history forms remain unavailable.
    - First action: run the smallest validation needed for the changed files listed above, using a focused `git diff -- <dirty-file>` read only when a dirty file needs inspection.
    - If the focused diff is complete and validation passes, commit any dirty intended files, push the branch, and request/update PR review.
    - For review-rework handoffs, never set Linear to a terminal state; a fresh review request is not proof that the new review is clean.
    - Do not restart or broaden implementation. Edit again only when the focused diff is incomplete, invalid, focused validation names exact in-scope files/assertions, or a current review thread requires another code change.
    - If network/provider/permission blocks handoff, record the blocker with next action `retry` and stop.
    """
    |> String.trim()
  end

  defp pushed_validated_handoff_checkpoint(status, event_summary, git_context) do
    """
    Pushed validated handoff checkpoint:

    - Current workspace is clean on a pushed non-main branch with recent passed validation/gate evidence.
    - `git status --short --branch`:
    #{indent(status)}
    #{git_context}
    - Recent passed validation/gate evidence:
    #{indent(event_summary)}
    - The commit list and diffstat above are runtime-provided. Run bounded `git log` only when the runtime command policy explicitly advertises it; `git diff --stat`, base-branch diff/history commands, and all other denied history forms remain unavailable.
    - First action: verify whether a PR already exists for this branch. If none exists, create one against `main`.
    - Do not redo implementation, broad context scans, or broad validations before the PR/Linear handoff.
    - Request/update PR review and update Linear with branch, PR, commit, validation, and blockers.
    - If network/provider/permission blocks that handoff, record a retry blocker and stop.
    """
    |> String.trim()
  end

  defp recent_passed_event_summary(workspace) do
    workspace
    |> event_paths()
    |> Enum.find_value("", &summarize_passed_events/1)
  end

  defp event_paths(workspace) do
    [
      Path.join(workspace, ".orocsy/delivery/events/events.jsonl"),
      Path.join(workspace, ".codex/delivery/events/events.jsonl")
    ]
  end

  defp summarize_passed_events(path) do
    if File.regular?(path) do
      events = decoded_recent_events(path)

      if blocked_event_after_last_passed?(events) do
        ""
      else
        events
        |> Enum.filter(&passed_validation_event?/1)
        |> Enum.take(-8)
        |> Enum.map(&event_summary_line/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
      end
    else
      ""
    end
  rescue
    _error -> ""
  end

  defp recent_lines(path) do
    path
    |> File.stream!()
    |> Enum.reduce([], fn line, acc ->
      [String.trim(line) | acc] |> Enum.take(@recent_event_limit)
    end)
    |> Enum.reverse()
  end

  defp decoded_recent_events(path) do
    path
    |> recent_lines()
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, decoded} when is_map(decoded) -> [decoded]
        _ -> []
      end
    end)
  end

  defp blocked_event_after_last_passed?(events) when is_list(events) do
    indexed = Enum.with_index(events)

    last_passed_index =
      indexed
      |> Enum.filter(fn {event, _index} -> passed_validation_event?(event) end)
      |> List.last()
      |> case do
        {_event, index} -> index
        nil -> nil
      end

    trailing_blockers =
      if is_integer(last_passed_index) do
        events
        |> Enum.drop(last_passed_index + 1)
        |> Enum.filter(&blocking_event?/1)
      else
        []
      end

    trailing_blockers != [] and
      not Enum.all?(trailing_blockers, &ignorable_handoff_recovery_blocker?/1)
  end

  defp blocked_event_after_last_passed?(_events), do: false

  defp passed_validation_event?(%{} = decoded) do
    case Map.get(decoded, "status") do
      "passed" -> passed_validation_event_decoded?(decoded)
      _ -> false
    end
  end

  defp passed_validation_event?(_decoded), do: false

  defp blocking_event?(%{} = decoded) do
    Map.get(decoded, "status") in ["blocked", "failed", "error"]
  end

  defp blocking_event?(_decoded), do: false

  defp ignorable_handoff_recovery_blocker?(%{} = decoded) do
    text = decoded |> blocker_signal_text() |> String.downcase()

    harness_validation_blocker? =
      String.contains?(text, [
        "blocked before spec execution",
        "turbopackinternalerror",
        "symlink [project]/node_modules",
        "points out of the filesystem root",
        "workspace/toolchain filesystem symlink blocker"
      ])

    generated_cleanup_allowlist_probe? =
      Map.get(decoded, "event") == "symphony.generated.cleanup" and
        String.contains?(text, "not in the generated-clean allowlist")

    harness_validation_blocker? or generated_cleanup_allowlist_probe?
  end

  defp ignorable_handoff_recovery_blocker?(_decoded), do: false

  defp blocker_signal_text(decoded) when is_map(decoded) do
    decoded
    |> inspect(limit: :infinity, printable_limit: :infinity)
  end

  defp passed_validation_event_decoded?(%{"event" => event} = decoded) when is_binary(event) do
    event in ["gate.post-miu", "gate.required-evidence", "gate.declared-scope"] or
      explicit_validation_event?(event, decoded) or
      tool_finished_validation_event?(decoded) or
      String.starts_with?(event, "eval.") or
      Map.get(decoded, "phase") == "eval"
  end

  defp passed_validation_event_decoded?(_decoded), do: false

  defp explicit_validation_event?(event, decoded)
       when event in ["validation", "validation.finished"] and is_map(decoded) do
    decoded
    |> validation_signal_text()
    |> String.downcase()
    |> String.contains?(["test", "vitest", "typecheck", "lint", "build"])
  end

  defp explicit_validation_event?(_event, _decoded), do: false

  defp tool_finished_validation_event?(%{"event" => "tool.finished"} = decoded) do
    tool = decoded |> Map.get("tool", "") |> to_string()

    tool not in @checkpoint_only_tool_labels and
      (tool == "github-pr-created-and-codex-review-requested" or
         decoded
         |> validation_signal_text()
         |> String.downcase()
         |> String.contains?([
           "validation",
           "test",
           "vitest",
           "typecheck",
           "lint",
           "build",
           "playwright",
           "e2e"
         ]))
  end

  defp tool_finished_validation_event?(_decoded), do: false

  defp validation_signal_text(decoded) when is_map(decoded) do
    ["tool", "step", "command", "summary", "details"]
    |> Enum.map_join(" ", fn key -> decoded |> Map.get(key, "") |> to_string() end)
  end

  defp event_summary_line(%{} = decoded) do
    ts = Map.get(decoded, "ts", "unknown-time")
    event = Map.get(decoded, "event", "event")

    detail =
      Map.get(decoded, "tool") || Map.get(decoded, "step") || Map.get(decoded, "gate") ||
        Map.get(decoded, "rubric") || "passed"

    "- #{ts} #{event}: #{detail}"
  end

  defp indent(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map_join("\n", &"  #{&1}")
  end
end
