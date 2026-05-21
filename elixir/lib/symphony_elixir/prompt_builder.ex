defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, DispatchPreflight, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]
  @recent_event_limit 80
  @issue_brief_max_bytes 20_000
  @issue_brief_heading_max_bytes 4_000
  @issue_description_max_bytes 8_000
  @workflow_prompt_inline_max_bytes 18_500
  @compact_issue_description_max_bytes 4_000

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    attempt = Keyword.get(opts, :attempt)
    workspace = Keyword.get(opts, :workspace)
    checkpoint = workspace_recovery_checkpoint(workspace)
    workflow = Workflow.current()

    prompt =
      workflow
      |> prompt_template!()
      |> render_prompt_template(issue, opts)
      |> maybe_prepend_issue_brief_reference(issue, workspace)
      |> maybe_prepend_retry_prelude(attempt)

    prompt =
      cond do
        pushed_validated_handoff_checkpoint?(checkpoint) ->
          pushed_validated_handoff_prompt(issue, checkpoint, attempt)

        checkpoint != "" ->
          checkpoint <> "\n\n" <> prompt

        true ->
          prompt
      end

    maybe_prepend_dispatch_preflight(prompt, workspace)
  end

  @spec workspace_recovery_checkpoint(String.t() | nil) :: String.t()
  def workspace_recovery_checkpoint(workspace) when is_binary(workspace) do
    with true <- File.dir?(workspace),
         {:ok, status} <- git_status(workspace) do
      event_summary = recent_passed_event_summary(workspace)
      pushed_handoff? = pushed_handoff_risk?(status)
      local_handoff? = local_handoff_risk?(status) or (not pushed_handoff? and local_commit_handoff_risk?(workspace))

      cond do
        local_handoff? and event_summary != "" ->
          dirty_validated_handoff_checkpoint(status, event_summary)

        local_handoff? ->
          unvalidated_local_handoff_checkpoint(status)

        pushed_handoff? and event_summary != "" ->
          pushed_validated_handoff_checkpoint(status, event_summary)

        true ->
          ""
      end
    else
      _ -> ""
    end
  end

  def workspace_recovery_checkpoint(_workspace), do: ""

  @spec render_issue_template(String.t(), SymphonyElixir.Linear.Issue.t() | map() | String.t() | nil, keyword()) ::
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

  defp issue_template_context(identifier) when is_binary(identifier), do: %{id: nil, identifier: identifier}
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

  defp render_prompt_template(prompt, issue, opts) when byte_size(prompt) > @workflow_prompt_inline_max_bytes do
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
    - Start from `git status --short --branch`, the issue branch, latest `origin/main`, and the focused files named by the issue/brief. Avoid broad logs, historical tickets, unrelated docs, and unrelated GitHub/Linear data.
    - If `.codex/agentic/issue-briefs/#{safe_issue_identifier(issue_value(issue, :identifier))}.md` exists, read that focused brief before broad rediscovery.
    - First substantive progress guard: before optional skills, broad docs, recursive listings, or scanning more than eight implementation files, produce one real checkpoint:
      - Rework/existing PR: inspect only the current PR review threads for this branch, classify current-head feedback, then append `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . event append --type tool.finished --status passed --tool "review-feedback-classified"`. After that, edit only the referenced in-scope files or record a blocker; do not rediscover the whole project.
      - Fresh implementation: first run `git status --short --branch`, switch/create the exact Linear branch from `origin/main` if needed, read the issue brief plus only the first target file/test, then make a scoped code/test edit or write the Technical MIU trace with exact files/tests. Append `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . event append --type tool.finished --status passed --tool "technical-miu-trace"` before any wider context read.
      - Blocked issue: create an Orocsy inbox correction with the exact blocker and stop.
      - `first-turn-miu-handoff` alone only proves the worker is alive; it is not substantive progress.
    - If the issue shape is missing code-level scope, dependencies are unfinished, approvals/auth/network block required work, or review feedback is outside scope, record a blocker/correction and stop instead of exploring broadly.
    - If any required command fails because a binary is missing, PATH differs, credentials are absent, network/provider access fails, or approval/input is required, record the exact command, stderr/output, failure kind, and next action in an Orocsy blocker/correction before stopping.
    - Implement one MIU at a time. In a fresh implementation first turn, stop after one scoped code/test/doc edit or blocker plus `technical-miu-trace`; a later dirty handoff-recovery turn handles focused validation, evidence, commit, push, PR review request, and Linear handoff.
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
        trim_text(text, @compact_issue_description_max_bytes, "[Linear issue description compacted by Symphony prompt builder. Use the issue brief or Linear only if required fields are missing.]")
    end
  end

  defp compact_issue_description(_description), do: "unknown"

  defp maybe_prepend_dispatch_preflight(prompt, workspace) do
    case DispatchPreflight.read(workspace) do
      {:ok, %{"mode" => "review_rework"}} ->
        [
          workspace_recovery_checkpoint(workspace),
          DispatchPreflight.prompt_context(workspace),
          review_rework_micro_prompt()
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

  defp review_rework_micro_prompt do
    """
    Review rework execution contract:

    - Treat this as a bounded PR review fix, not a fresh implementation turn.
    - If a dirty/local handoff checkpoint appears above, follow that checkpoint first: inspect only the focused local diff, run the smallest validation needed for that diff, then commit, push, and request fresh review.
    - Do not read workflow docs, issue briefs, previous Codex session JSONL, broad CSS, or unrelated components before the first code/test edit unless the listed feedback path is one of those files.
    - Do not run `rg`, `grep`, `find`, `ls`, `git ls-files`, `gh api`, shell pipelines, or chained shell commands in review-rework mode; the current-head feedback body and target file path are already in this prompt.
    - Start from the listed review feedback path. Read one short `sed -n` range around that path only, then edit only directly related code/tests or record a blocker.
    - Before the first code/test edit, do not run `sed`, `cat`, `head`, `tail`, or `nl` on files outside the listed feedback path.
    - In this turn, either make the scoped edit and focused test update, or write an explicit Orocsy blocker/correction. Do not stop after analysis.
    - If validation, git push, GitHub, Linear, PATH, auth, or approval fails, record the exact command/failure and next action in an Orocsy blocker/correction before stopping.
    - After a code/test edit, run focused validation, then commit, push the same branch, and request fresh Codex review; the runtime captures validation output, so do not edit `.orocsy/delivery/state/dispatch-preflight.json`.
    - Never move a review-rework issue to `Done`, `Closed`, or another terminal Linear state. A fresh review request is not proof of a clean review; Symphony's review monitor owns review/rework transitions after the new review result exists.
    - If the listed feedback is already resolved or outdated at the current head, record that classification, update the handoff state, and stop without editing.
    """
    |> String.trim()
  end

  defp maybe_prepend_retry_prelude(prompt, attempt) when is_binary(prompt) and is_integer(attempt) and attempt > 0 do
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

  defp issue_brief_reference(%{identifier: identifier}, workspace) when is_binary(identifier) and is_binary(workspace) do
    relative_paths = [
      Path.join([".codex/agentic/issue-briefs", "#{safe_issue_identifier(identifier)}.md"]),
      ".orocsy/delivery/issue-brief.md"
    ]

    with relative_path when is_binary(relative_path) <- Enum.find(relative_paths, &File.regular?(Path.join(workspace, &1))),
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
    trim_text(content, @issue_brief_max_bytes, "[Issue brief truncated by Symphony prompt builder.]")
  end

  defp trim_issue_brief(content), do: content

  defp trim_text(content, max_bytes, notice)
       when is_binary(content) and is_integer(max_bytes) and max_bytes > 0 and byte_size(content) > max_bytes do
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
    - Resume from the current workspace state; inspect `git status --short --branch`, recent commits, and `.orocsy/delivery/events/events.jsonl` before editing.
    - If the workspace is dirty or ahead and recent `tool.finished`, `gate.post-miu`, `gate.required-evidence`, or `gate.declared-scope` events passed, treat that as a dirty handoff checkpoint.
    - At a dirty handoff checkpoint, do not redo implementation, broad PR/Linear review scans, or broad validations first. Inspect the focused diff, run the smallest validation needed for the dirty file, then stage, commit, push, and request/update PR review.
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

    - `git status --short --branch`, current branch/head, focused diffs/commits, and exact files named by current review feedback.
    - The existing PR for the current branch, including current Codex/GitHub review threads, comments, reviews, and head SHA.
    - Focused tests or type/lint checks that cover changed review-fix files.

    Stop rules:

    - Do not read AGENTS.md, skills, broad project docs, historical delivery logs, unrelated tickets, COD-149/COD-150 history, or broad GitHub/Linear context.
    - First action for active review feedback: classify the current PR review threads, then append `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . event append --type tool.finished --status passed --tool "review-feedback-classified"` before editing or scanning beyond the referenced files.
    - If the PR exists, the pushed head matches this workspace, and all current review feedback is resolved/outdated/clean, update Linear to the configured review state with branch, PR, commit, validation evidence, and stop.
    - If current review feedback remains, classify only that feedback, edit only the referenced code paths, run focused validation, commit, push, request/update Codex review, leave the issue non-terminal, and stop.
    - If GitHub, Linear, git push, or approval blocks the handoff, record a retry/blocker correction and stop instead of rediscovering the project.
    """
    |> String.trim()
  end

  defp attempt_label(attempt) when is_integer(attempt) and attempt > 0, do: "retry attempt ##{attempt}"
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
    case System.cmd("git", ["status", "--short", "--branch"], cd: workspace, stderr_to_stdout: true) do
      {status, 0} -> {:ok, String.trim(status)}
      {error, _exit_code} -> {:error, error}
    end
  rescue
    error -> {:error, error}
  end

  defp local_handoff_risk?(status) when is_binary(status) do
    lines = String.split(status, "\n", trim: true)
    branch_line = List.first(lines) || ""
    dirty_lines = Enum.reject(lines, &String.starts_with?(&1, "##"))

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
    case System.cmd("git", ["rev-parse", "--verify", "--quiet", ref], cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _exit_code} -> false
    end
  rescue
    _error -> false
  end

  defp pushed_handoff_risk?(status) when is_binary(status) do
    lines = String.split(status, "\n", trim: true)
    branch_line = List.first(lines) || ""
    dirty_lines = Enum.reject(lines, &String.starts_with?(&1, "##"))
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

  defp dirty_validated_handoff_checkpoint(status, event_summary) do
    """
    Dirty validated handoff checkpoint:

    - Current workspace has local work that must be handed off before more investigation.
    - `git status --short --branch`:
    #{indent(status)}
    - Recent passed validation/gate evidence:
    #{indent(event_summary)}
    - First action: inspect the focused diff with `git diff -- <dirty-file>`, then run the smallest focused validation for that dirty file before committing.
    - Do not run file-discovery commands such as `git ls-files`, `rg`, `grep`, `find`, or `ls`; the dirty file path is already listed in `git status`.
    - Commit and push only after focused validation passes.
    - Do not query broad Linear/GitHub context or rerun broad validations before the focused validation unless the focused diff is incomplete or invalid.
    - After the push, request/update PR review and Linear handoff. If network/provider/permission blocks that handoff, record a retry blocker and stop.
    """
    |> String.trim()
  end

  defp unvalidated_local_handoff_checkpoint(status) do
    """
    Local handoff recovery checkpoint:

    - Current workspace has local work but no recent passed Orocsy validation/gate evidence was found.
    - `git status --short --branch`:
    #{indent(status)}
    - First action: inspect the focused local diff and local commits, then run the smallest validation needed for those changed files.
    - If the focused diff is complete and validation passes, commit any dirty intended files, push the branch, and request/update PR review.
    - For review-rework handoffs, never set Linear to a terminal state; a fresh review request is not proof that the new review is clean.
    - Do not redo implementation, broad codebase scans, or broad validations first unless the focused diff is incomplete, invalid, or a current review thread requires another code change.
    - If network/provider/permission blocks handoff, record the blocker with next action `retry` and stop.
    """
    |> String.trim()
  end

  defp pushed_validated_handoff_checkpoint(status, event_summary) do
    """
    Pushed validated handoff checkpoint:

    - Current workspace is clean on a pushed non-main branch with recent passed validation/gate evidence.
    - `git status --short --branch`:
    #{indent(status)}
    - Recent passed validation/gate evidence:
    #{indent(event_summary)}
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
      path
      |> recent_lines()
      |> Enum.filter(&passed_validation_event?/1)
      |> Enum.take(-8)
      |> Enum.map(&event_summary_line/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
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

  defp passed_validation_event?(line) do
    with {:ok, decoded} <- Jason.decode(line),
         "passed" <- Map.get(decoded, "status") do
      passed_validation_event_decoded?(decoded)
    else
      _ -> false
    end
  end

  defp passed_validation_event_decoded?(%{"event" => event} = decoded) when is_binary(event) do
    event in ["tool.finished", "gate.post-miu", "gate.required-evidence", "gate.declared-scope"] or
      String.starts_with?(event, "eval.") or
      String.starts_with?(event, "handoff.") or
      Map.get(decoded, "phase") == "eval"
  end

  defp passed_validation_event_decoded?(_decoded), do: false

  defp event_summary_line(line) do
    with {:ok, decoded} <- Jason.decode(line) do
      ts = Map.get(decoded, "ts", "unknown-time")
      event = Map.get(decoded, "event", "event")
      detail = Map.get(decoded, "tool") || Map.get(decoded, "step") || Map.get(decoded, "gate") || Map.get(decoded, "rubric") || "passed"

      "- #{ts} #{event}: #{detail}"
    else
      _ -> ""
    end
  end

  defp indent(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map_join("\n", &"  #{&1}")
  end
end
