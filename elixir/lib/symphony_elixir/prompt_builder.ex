defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]
  @recent_event_limit 80
  @issue_brief_max_bytes 20_000

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    attempt = Keyword.get(opts, :attempt)
    workspace = Keyword.get(opts, :workspace)

    Workflow.current()
    |> prompt_template!()
    |> render_issue_template(issue, opts)
    |> maybe_prepend_issue_brief(issue, workspace)
    |> maybe_prepend_retry_prelude(attempt)
    |> maybe_prepend_workspace_recovery_checkpoint(workspace)
  end

  @spec workspace_recovery_checkpoint(String.t() | nil) :: String.t()
  def workspace_recovery_checkpoint(workspace) when is_binary(workspace) do
    with true <- File.dir?(workspace),
         {:ok, status} <- git_status(workspace) do
      event_summary = recent_passed_event_summary(workspace)
      local_handoff? = local_handoff_risk?(status) or local_commit_handoff_risk?(workspace)

      cond do
        local_handoff? and event_summary != "" ->
          dirty_validated_handoff_checkpoint(status, event_summary)

        local_handoff? ->
          unvalidated_local_handoff_checkpoint(status)

        pushed_handoff_risk?(status) and event_summary != "" ->
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

  defp issue_template_context(%_{} = issue), do: Map.from_struct(issue)

  defp issue_template_context(%{issue_identifier: identifier} = issue_context) do
    %{
      id: Map.get(issue_context, :issue_id),
      identifier: identifier
    }
  end

  defp issue_template_context(%{"issue_identifier" => identifier} = issue_context) do
    %{
      id: Map.get(issue_context, "issue_id"),
      identifier: identifier
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

  defp maybe_prepend_retry_prelude(prompt, attempt) when is_binary(prompt) and is_integer(attempt) and attempt > 0 do
    if retry_prelude_present?(prompt, attempt) do
      prompt
    else
      retry_prelude(attempt) <> "\n\n" <> prompt
    end
  end

  defp maybe_prepend_retry_prelude(prompt, _attempt), do: prompt

  defp maybe_prepend_issue_brief(prompt, issue, workspace) do
    case issue_brief(issue, workspace) do
      "" -> prompt
      brief -> maybe_prepend_issue_brief_content(prompt, brief)
    end
  end

  defp maybe_prepend_issue_brief_content(prompt, brief) do
    if prompt_already_contains_issue_brief?(prompt, brief) do
      prompt
    else
      "Issue technical brief:\n\n" <> brief <> "\n\n" <> prompt
    end
  end

  defp maybe_prepend_workspace_recovery_checkpoint(prompt, workspace) do
    case workspace_recovery_checkpoint(workspace) do
      "" -> prompt
      checkpoint -> checkpoint <> "\n\n" <> prompt
    end
  end

  defp issue_brief(%{identifier: identifier}, workspace) when is_binary(identifier) and is_binary(workspace) do
    path = Path.join([workspace, ".codex/agentic/issue-briefs", "#{safe_issue_identifier(identifier)}.md"])

    with true <- File.regular?(path),
         {:ok, content} <- File.read(path) do
      content
      |> trim_issue_brief()
      |> String.trim()
    else
      _ -> ""
    end
  rescue
    _error -> ""
  end

  defp issue_brief(_issue, _workspace), do: ""

  defp safe_issue_identifier(identifier) do
    identifier
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
  end

  defp trim_issue_brief(content) when byte_size(content) > @issue_brief_max_bytes do
    binary_part(content, 0, @issue_brief_max_bytes) <> "\n\n[Issue brief truncated by Symphony prompt builder.]"
  end

  defp trim_issue_brief(content), do: content

  defp prompt_already_contains_issue_brief?(prompt, brief) do
    brief
    |> markdown_heading()
    |> case do
      nil -> false
      heading -> String.contains?(prompt, heading)
    end
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
    - If the workspace is dirty or ahead and recent `tool.finished`, `gate.post-miu`, `gate.required-evidence`, or `gate.declared-scope` events passed, treat that as a dirty validated handoff checkpoint.
    - At a dirty validated handoff checkpoint, do not redo implementation, broad PR/Linear review scans, or broad validations first. Inspect the focused diff, then stage, commit, push, request/update PR review, and update Linear.
    - If product changes, validation, or gates already exist, enter handoff-recovery mode and only complete the pending commit, push, PR review request, or Linear update.
    - If a provider, network, or permission failure still blocks handoff, record an Orocsy inbox item or workpad blocker with next action `retry` and stop.
    """
    |> String.trim()
  end

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
    - First action: inspect the focused diff, stage the intended files, commit, and push this branch.
    - Do not query broad Linear/GitHub context or rerun broad validations before the commit unless the focused diff is incomplete or invalid.
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
    - If the focused diff is complete and validation passes, commit any dirty intended files, push the branch, request/update PR review, and update Linear.
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
    with true <- String.contains?(line, ~s("status": "passed")),
         {:ok, decoded} <- Jason.decode(line) do
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
