defmodule SymphonyElixir.IssueRequirements do
  @moduledoc """
  Derives bounded, machine-readable issue requirements from tracker issues.
  """

  alias SymphonyElixir.Linear.Issue

  @required_keys [:identifier, :write_scope, :mius, :validation]

  @spec from_issue(Issue.t() | map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def from_issue(issue, workspace \\ nil)

  def from_issue(%Issue{} = issue, workspace) do
    description =
      issue
      |> issue_description()
      |> maybe_append_issue_brief(issue.identifier, workspace)

    if not requirements_description?(description) do
      {:error, :no_issue_requirements}
    else
      requirements = %{
        "identifier" => string(issue.identifier),
        "title" => string(issue.title),
        "state" => string(issue.state),
        "branch" => string(issue.branch_name),
        "base_branch" => scalar_section(description, "Base Branch"),
        "integration_branch" => scalar_section(description, "Integration Branch"),
        "feature_group" => scalar_section(description, "Feature Group"),
        "ticket_type" => scalar_section(description, "Ticket Type"),
        "expected_test_state" => scalar_section(description, "Expected Test State"),
        "test_activation" => scalar_section(description, "Test Activation"),
        "project" => "",
        "write_scope" => write_scope(description),
        "shared_files" => section_list(description, "Shared Files"),
        "dependencies" => dependencies(description),
        "mius" => miu_list(description),
        "validation" => validation(description),
        "out_of_scope" => out_of_scope(description),
        "issue_brief" => issue_brief_reference(issue.identifier, workspace)
      }

      case validate(requirements) do
        :ok -> {:ok, requirements}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def from_issue(%{} = issue, workspace) do
    issue
    |> struct_from_map()
    |> from_issue(workspace)
  end

  def from_issue(_issue, _workspace), do: {:error, :unsupported_issue}

  @spec write_workspace_files(String.t(), Issue.t() | map()) :: {:ok, map()} | {:error, term()}
  def write_workspace_files(workspace, issue) when is_binary(workspace) do
    with {:ok, requirements} <- from_issue(issue, workspace),
         :ok <- ensure_delivery_dirs(workspace),
         :ok <- write_issue_file(workspace, requirements),
         :ok <- merge_current_state(workspace, requirements),
         :ok <- merge_policy(workspace, requirements) do
      {:ok, requirements}
    end
  end

  def write_workspace_files(_workspace, _issue), do: {:error, :invalid_workspace}

  defp requirements_description?(description) when is_binary(description) do
    description =~ ~r/^##\s+(Write Scope|Scope|Validation|Validation Commands|Required Tests|Out Of Scope)\s*$/mi
  end

  defp requirements_description?(_description), do: false

  defp issue_description(%Issue{description: description}) when is_binary(description), do: description
  defp issue_description(_issue), do: ""

  defp maybe_append_issue_brief(description, identifier, workspace)
       when is_binary(description) and is_binary(identifier) and is_binary(workspace) do
    case issue_brief_body(identifier, workspace) do
      "" -> description
      brief -> [description, brief] |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
    end
  end

  defp maybe_append_issue_brief(description, _identifier, _workspace), do: description

  defp issue_brief_body(identifier, workspace) do
    workspace
    |> issue_brief_candidate_paths(identifier)
    |> Enum.find_value("", fn path ->
      if File.regular?(path) do
        body = File.read!(path)

        if String.trim(body) == "" do
          nil
        else
          body
        end
      end
    end)
  rescue
    _error -> ""
  end

  defp issue_brief_candidate_paths(workspace, identifier) do
    safe = safe_identifier(identifier)

    [
      Path.join(workspace, ".orocsy/delivery/issue-brief.md"),
      Path.join(workspace, ".codex/agentic/issue-briefs/#{safe}.md")
    ]
  end

  defp struct_from_map(issue) do
    %Issue{
      id: Map.get(issue, :id) || Map.get(issue, "id"),
      identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      title: Map.get(issue, :title) || Map.get(issue, "title"),
      description: Map.get(issue, :description) || Map.get(issue, "description"),
      state: Map.get(issue, :state) || Map.get(issue, "state"),
      branch_name: Map.get(issue, :branch_name) || Map.get(issue, "branch_name") || Map.get(issue, "branch")
    }
  end

  defp validate(requirements) do
    missing =
      Enum.filter(@required_keys, fn key ->
        value = Map.get(requirements, Atom.to_string(key))
        empty?(value)
      end)

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_issue_requirements, Enum.map(keys, &Atom.to_string/1)}}
    end
  end

  defp validation(description) do
    commands =
      validation_text(description)
      |> code_block_lines()
      |> Enum.concat(validation_text(description) |> bullet_lines())
      |> Enum.concat(section_text(description, "Required Tests") |> bullet_lines())
      |> Enum.filter(&String.contains?(&1, ["pnpm", "mix", "npm", "yarn", "cargo", "pytest"]))
      |> Enum.uniq()

    scenarios =
      section_text(description, "Required Tests")
      |> bullet_lines()
      |> Enum.reject(&String.contains?(&1, ["pnpm", "mix", "npm", "yarn", "cargo", "pytest"]))

    %{
      "commands" => commands,
      "files" => [],
      "events" => [],
      "scenarios" => scenarios
    }
  end

  defp validation_text(description) do
    [
      section_text(description, "Validation"),
      section_text(description, "Validation Commands")
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp miu_list(description) do
    mius =
      Regex.scan(~r/^###\s+(.+)$/m, description, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case mius do
      [] -> fallback_miu_list(description)
      mius -> mius
    end
  end

  defp fallback_miu_list(description) do
    [
      scalar_section(description, "Runtime Problem"),
      scalar_section(description, "Goal"),
      scalar_section(description, "Requirements")
    ]
    |> List.flatten()
    |> Enum.map(&string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.wrap()
    |> case do
      [] -> []
      [first | _] -> [first]
    end
  end

  defp dependencies(description) do
    description
    |> section_list("Dependencies")
    |> Kernel.++(inline_depends_on(description))
    |> Enum.uniq()
  end

  defp inline_depends_on(description) do
    Regex.scan(~r/^\s*Depends on:\s*(.+)$/mi, description, capture: :all_but_first)
    |> List.flatten()
    |> Enum.flat_map(fn text ->
      text
      |> String.split([",", ";"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end)
  end

  defp section_list(description, heading) do
    description
    |> section_text(heading)
    |> bullet_lines()
  end

  defp write_scope(description) do
    case section_list(description, "Write Scope") do
      [] -> scope_subsection_list(description, "In")
      scope -> scope
    end
  end

  defp out_of_scope(description) do
    (section_list(description, "Out Of Scope") ++ scope_subsection_list(description, "Out"))
    |> Enum.uniq()
  end

  defp scalar_section(description, heading) do
    description
    |> section_text(heading)
    |> scalar_text()
  end

  defp scalar_text(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      line
      |> String.trim()
      |> String.trim_leading("*")
      |> String.trim_leading("-")
      |> String.trim()
      |> strip_markdown_code()
    end)
    |> Enum.reject(&(&1 == ""))
    |> List.first()
  end

  defp bullet_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      line
      |> String.trim()
      |> String.trim_leading("*")
      |> String.trim_leading("-")
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ["In:", "Out:"])))
    |> Enum.map(&strip_markdown_code/1)
  end

  defp scope_subsection_list(description, heading) do
    description
    |> section_text("Scope")
    |> subsection_text(heading)
    |> bullet_lines()
  end

  defp subsection_text(text, heading) do
    lines = String.split(text || "", "\n")

    lines
    |> Enum.reduce({false, []}, fn line, {collecting?, acc} ->
      trimmed = String.trim(line)

      cond do
        String.downcase(trimmed) == String.downcase("#{heading}:") ->
          {true, acc}

        collecting? and String.match?(trimmed, ~r/^[A-Za-z][A-Za-z0-9 _-]*:\s*$/) ->
          {false, acc}

        collecting? ->
          {collecting?, [line | acc]}

        true ->
          {collecting?, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim()
  end

  defp code_block_lines(text) do
    Regex.scan(~r/```(?:[a-zA-Z]+)?\n(.*?)```/s, text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.flat_map(&String.split(&1, "\n"))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp section_text(description, heading) do
    pattern = ~r/^##\s+#{Regex.escape(heading)}\s*\n(.*?)(?=^(?:##|###)\s+|\z)/ms

    case Regex.run(pattern, description || "", capture: :all_but_first) do
      [body] -> String.trim(body)
      _ -> ""
    end
  end

  defp issue_brief_reference(identifier, workspace) when is_binary(identifier) and is_binary(workspace) do
    workspace
    |> issue_brief_candidate_paths(identifier)
    |> Enum.find_value(fn path ->
      if File.regular?(path) do
        body = File.read!(path)

        if String.trim(body) != "" do
          %{"path" => Path.relative_to(path, workspace), "bytes" => File.stat!(path).size}
        end
      end
    end)
  end

  defp issue_brief_reference(_identifier, _workspace), do: nil

  defp ensure_delivery_dirs(workspace) do
    File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/state"))
    File.mkdir_p!(Path.join(workspace, ".orocsy/delivery/events"))
    :ok
  end

  defp write_issue_file(workspace, requirements) do
    path = Path.join(workspace, ".orocsy/delivery/issue-requirements.json")
    File.write!(path, Jason.encode!(requirements, pretty: true) <> "\n")
    :ok
  end

  defp merge_current_state(workspace, requirements) do
    path = Path.join(workspace, ".orocsy/delivery/state/current.json")

    state =
      case File.read(path) do
        {:ok, body} -> Jason.decode!(body)
        {:error, _reason} -> %{"schema_version" => 1}
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    state =
      state
      |> Map.put("issue_requirements", requirements)
      |> Map.put("issue", requirements["identifier"])
      |> Map.put("intent", requirements["title"])
      |> Map.put("updated_at", now)

    File.write!(path, Jason.encode!(state, pretty: true) <> "\n")
    :ok
  end

  defp merge_policy(workspace, requirements) do
    path = Path.join(workspace, ".orocsy/delivery/policy.yml")
    existing = if File.regular?(path), do: File.read!(path), else: ""

    policy = %{
      "declared_scope" => merge_list(simple_list(existing, "declared_scope"), write_scope_patterns(requirements["write_scope"])),
      "required_evidence_files" => simple_list(existing, "required_evidence_files"),
      "required_event_types" => simple_list(existing, "required_event_types"),
      "required_commands" => merge_list(simple_list(existing, "required_commands"), requirements["validation"]["commands"])
    }

    File.write!(path, render_policy(policy))
    :ok
  end

  defp render_policy(policy) do
    [
      "# Orocsy project policy.",
      render_list("declared_scope", policy["declared_scope"]),
      render_list("required_evidence_files", policy["required_evidence_files"]),
      render_list("required_event_types", policy["required_event_types"]),
      render_list("required_commands", policy["required_commands"])
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp render_list(key, values) do
    case values do
      [] -> "#{key}:"
      values -> "#{key}:\n" <> Enum.map_join(values, "\n", &"  - #{&1}")
    end
  end

  defp simple_list(content, key) do
    pattern = ~r/^#{Regex.escape(key)}:\s*\n((?:\s+- .*\n?)*)/m

    case Regex.run(pattern, content, capture: :all_but_first) do
      [body] ->
        body
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, "- "))
        |> Enum.map(&String.trim_leading(&1, "- "))

      _ ->
        []
    end
  end

  defp merge_list(left, right) do
    (List.wrap(left) ++ List.wrap(right))
    |> Enum.map(&string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp write_scope_patterns(scope_items) when is_list(scope_items) do
    scope_items
    |> Enum.flat_map(&path_like_patterns/1)
    |> Enum.uniq()
  end

  defp write_scope_patterns(scope_item), do: path_like_patterns(scope_item)

  defp path_like_patterns(value) do
    text = value |> string() |> strip_markdown_code()

    matches =
      ~r/(?:^|[\s,;:])([A-Za-z0-9._*?{}\[\]-]+(?:\/[A-Za-z0-9._*?{}\[\]-]+)+)/
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.trim_trailing(&1, ".,;:"))
      |> Enum.reject(&(&1 == ""))

    case matches do
      [] -> [text]
      patterns -> patterns
    end
  end

  defp empty?(value), do: value in [nil, "", [], %{}]

  defp strip_markdown_code(value) do
    value
    |> String.replace("`", "")
    |> String.trim()
  end

  defp safe_identifier(identifier) do
    identifier
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
  end

  defp string(nil), do: ""
  defp string(value) when is_binary(value), do: String.trim(value)
  defp string(value), do: value |> to_string() |> String.trim()
end
