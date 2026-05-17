defmodule SymphonyElixir.DispatchPreflight do
  @moduledoc """
  Writes a small machine-owned dispatch checkpoint before Codex starts.
  """

  alias SymphonyElixir.{Config, IssueRequirements, ReviewMonitor}
  alias SymphonyElixir.Linear.Issue

  @preflight_path ".orocsy/delivery/state/dispatch-preflight.json"
  @event_path ".orocsy/delivery/events/events.jsonl"
  @feedback_body_max_bytes 1_200

  @spec prepare(String.t(), Issue.t() | map()) :: {:ok, map()} | {:error, term()}
  def prepare(workspace, issue) when is_binary(workspace) do
    with :ok <- ensure_dirs(workspace),
         {:ok, requirements} <- requirements_for(workspace, issue),
         {:ok, inspection} <- inspect_review(issue) do
      preflight =
        if review_feedback?(inspection) do
          review_rework_preflight(workspace, issue, requirements, inspection)
        else
          fresh_implementation_preflight(workspace, issue, requirements, inspection)
        end

      :ok = write_preflight(workspace, preflight)
      :ok = append_checkpoint_event(workspace, preflight)
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
        {:ok, fallback_requirements(issue)}

      {:error, {:missing_issue_requirements, _missing}} ->
        {:ok, fallback_requirements(issue)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inspect_review(%Issue{} = issue) do
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

  defp inspect_review(issue) when is_map(issue) do
    issue
    |> struct_issue()
    |> inspect_review()
  end

  defp inspect_review(_issue), do: {:ok, %{pr: nil, pr_number: nil, pr_url: nil, head_sha: nil, feedback: [], feedback_source: :none}}

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

  defp review_rework_preflight(workspace, issue, requirements, inspection) do
    feedback = Map.get(inspection, :feedback, [])

    %{
      "schema_version" => 1,
      "mode" => "review_rework",
      "created_at" => now_iso8601(),
      "issue" => issue_value(issue, :identifier),
      "state" => issue_value(issue, :state),
      "branch" => requirements["branch"] || issue_value(issue, :branch_name),
      "checkpoint_event" => "review-feedback-classified",
      "first_task" =>
        "Fix only the listed current-head review feedback on the existing PR branch, then run focused validation, push, and request a fresh Codex review. Do not move Linear to Done; review/rework transitions belong to Symphony's review monitor.",
      "requirements" => compact_requirements(requirements),
      "toolchain" => toolchain_snapshot(workspace),
      "review" => %{
        "pr_number" => Map.get(inspection, :pr_number),
        "pr_url" => Map.get(inspection, :pr_url),
        "head_sha" => Map.get(inspection, :head_sha),
        "feedback_source" => Map.get(inspection, :feedback_source) |> to_string(),
        "feedback_count" => length(feedback),
        "feedback" => Enum.map(feedback, &feedback_summary/1)
      }
    }
  end

  defp fresh_implementation_preflight(workspace, issue, requirements, inspection) do
    %{
      "schema_version" => 1,
      "mode" => "fresh_implementation",
      "created_at" => now_iso8601(),
      "issue" => issue_value(issue, :identifier),
      "state" => issue_value(issue, :state),
      "branch" => requirements["branch"] || issue_value(issue, :branch_name),
      "checkpoint_event" => "technical-miu-trace",
      "first_task" => "Start with the first MIU and the first declared write-scope path only; make a scoped code/test change or record an explicit blocker before broad project scanning.",
      "requirements" => compact_requirements(requirements),
      "toolchain" => toolchain_snapshot(workspace),
      "review" => %{
        "pr_number" => Map.get(inspection, :pr_number),
        "pr_url" => Map.get(inspection, :pr_url),
        "head_sha" => Map.get(inspection, :head_sha),
        "feedback_source" => Map.get(inspection, :feedback_source) |> to_string(),
        "feedback_count" => 0,
        "feedback" => []
      }
    }
  end

  defp write_preflight(workspace, preflight) do
    path = Path.join(workspace, @preflight_path)
    File.write!(path, Jason.encode!(preflight, pretty: true) <> "\n")
    :ok
  end

  defp append_checkpoint_event(workspace, preflight) do
    event = %{
      "event" => "tool.finished",
      "status" => "passed",
      "tool" => preflight["checkpoint_event"],
      "ts" => now_iso8601(),
      "issue" => preflight["issue"],
      "branch" => preflight["branch"],
      "mode" => preflight["mode"],
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

    """
    Runtime dispatch preflight:

    - Mode: review rework
    - Preflight file: `#{@preflight_path}`
    - Branch: `#{preflight["branch"] || "unknown"}`
    - PR: #{review["pr_url"] || review["pr_number"] || "unknown"}
    - Reviewed head: `#{short_sha(review["head_sha"])}`
    - Durable checkpoint already recorded: `#{preflight["checkpoint_event"]}`
    - Preflight file is read-only runtime context; do not edit it.
    - First task: #{preflight["first_task"]}
    - Target feedback file(s): #{format_inline_items(feedback_paths(feedback))}
    - Toolchain preflight: #{format_toolchain(preflight["toolchain"])}
    - Validation command guidance: #{toolchain_guidance(preflight["toolchain"])}

    Current-head review feedback:
    #{format_items(feedback)}

    Review rework limits:
    - Use the target feedback file as the first read/edit path.
    - Read only directly related tests, imported local types, or the nearest caller before the first edit.
    - Do not read workflow docs, issue briefs, previous Codex session JSONL, broad CSS, or unrelated components before the first edit unless listed above.
    - Produce a scoped edit plus focused validation, or record an explicit blocker/correction. Do not stop after analysis.
    """
    |> String.trim()
  end

  defp fresh_prompt_context(preflight) do
    requirements = preflight["requirements"] || %{}

    """
    Runtime dispatch preflight:

    - Mode: fresh implementation
    - Preflight file: `#{@preflight_path}`
    - Branch: `#{preflight["branch"] || "unknown"}`
    - Durable checkpoint already recorded: `#{preflight["checkpoint_event"]}`
    - First task: #{preflight["first_task"]}
    - First MIU: #{first_item(requirements["mius"])}
    - First write-scope path: #{first_item(requirements["write_scope"])}
    - First validation command: #{first_item(get_in(requirements, ["validation", "commands"]))}
    - Toolchain preflight: #{format_toolchain(preflight["toolchain"])}
    - Validation command guidance: #{toolchain_guidance(preflight["toolchain"])}

    Do not inspect broad project history before producing scoped file/test progress or an explicit blocker.
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
    Map.take(requirements, ["identifier", "title", "state", "branch", "write_scope", "dependencies", "mius", "validation", "out_of_scope", "issue_brief"])
  end

  defp compact_requirements(_requirements), do: %{}

  defp fallback_requirements(issue) do
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
      "issue_brief" => nil
    }
  end

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
    |> Enum.map(& &1["path"])
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp feedback_paths(_items), do: []

  defp format_inline_items([]), do: "unknown"
  defp format_inline_items(items), do: Enum.map_join(items, ", ", &"`#{&1}`")

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
