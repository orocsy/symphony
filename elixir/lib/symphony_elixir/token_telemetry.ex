defmodule SymphonyElixir.TokenTelemetry do
  @moduledoc """
  Writes redacted workspace-local token telemetry spans for Codex worker turns.
  """

  require Logger

  @spans_path ".orocsy/delivery/token-telemetry/spans.jsonl"
  @workers_path ".orocsy/delivery/token-telemetry/workers.jsonl"
  @summaries_dir ".orocsy/delivery/token-telemetry/summaries"
  @schema_version 1
  @command_fingerprint_patterns [
    {~r/(^|\s)sed\s+-n\s+/, "sed-read"},
    {~r/(^|\s)rg\s+/, "rg-search"},
    {~r/(^|\s)grep\s+/, "grep-search"},
    {~r/(^|\s)git\s+status(\s|$)/, "git-status"},
    {~r/(^|\s)git\s+diff(\s|$)/, "git-diff"},
    {~r/(^|\s)git\s+show(\s|$)/, "git-show"},
    {~r/(^|\s)gh\s+pr\s+view(\s|$)/, "gh-pr-view"},
    {~r/(^|\s)gh\s+api(\s|$)/, "gh-api"},
    {~r/(^|\s)mix\s+test(\s|$)/, "mix-test"},
    {~r/(^|\s)mix\s+specs\.check(\s|$)/, "mix-specs-check"},
    {~r/(^|\s)make\s+all(\s|$)/, "make-all"},
    {~r/(^|\s)pnpm(\s|$)/, "pnpm"},
    {~r/(^|\s)apply_patch(\s|$)/, "apply-patch"}
  ]

  defstruct [
    :workspace,
    :issue_identifier,
    :issue_id,
    :thread_id,
    :turn_id,
    :turn_number,
    :worker_session_id,
    :started_at,
    :state_pid,
    enabled: false
  ]

  @type usage :: %{
          input_tokens: non_neg_integer(),
          cached_input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @type command_summary :: %{
          command_fingerprint: String.t() | nil,
          files: [String.t()],
          phase: String.t()
        }

  @type t :: %__MODULE__{
          workspace: Path.t() | nil,
          issue_identifier: String.t() | nil,
          issue_id: String.t() | nil,
          thread_id: String.t() | nil,
          turn_id: String.t() | nil,
          turn_number: pos_integer(),
          worker_session_id: String.t() | nil,
          started_at: DateTime.t() | nil,
          state_pid: pid() | nil,
          enabled: boolean()
        }

  @spec start_turn(Path.t(), map() | nil, String.t(), String.t(), keyword()) :: t()
  def start_turn(workspace, issue, thread_id, turn_id, opts \\ []) do
    telemetry = build_turn(workspace, issue, thread_id, turn_id, opts)

    with true <- is_binary(workspace),
         :ok <- File.mkdir_p(spans_dir(workspace)),
         :ok <- File.mkdir_p(summaries_dir(workspace)),
         {:ok, pid} <- Agent.start_link(fn -> initial_state() end) do
      telemetry = %{telemetry | enabled: true, state_pid: pid}
      append_span(telemetry, start_span(telemetry))
      telemetry
    else
      _ ->
        %{telemetry | enabled: false}
    end
  rescue
    error in [File.Error, RuntimeError, ArgumentError] ->
      Logger.warning("Token telemetry disabled for workspace=#{inspect(workspace)} error=#{Exception.message(error)}")
      build_turn(workspace, issue, thread_id, turn_id, opts)
  end

  @spec observe(t(), map()) :: :ok
  def observe(%__MODULE__{enabled: true, state_pid: pid} = telemetry, payload)
      when is_pid(pid) and is_map(payload) do
    spans =
      Agent.get_and_update(pid, fn state ->
        {spans, next_state} = spans_for_payload(telemetry, state, payload)
        {spans, next_state}
      end)

    Enum.each(spans, &append_span(telemetry, &1))
    :ok
  rescue
    error in [File.Error, RuntimeError, ArgumentError] ->
      Logger.warning("Token telemetry observe failed: #{Exception.message(error)}")
      :ok
  end

  def observe(_telemetry, _payload), do: :ok

  @spec stop(t()) :: :ok
  def stop(%__MODULE__{state_pid: pid} = telemetry) when is_pid(pid) do
    telemetry_state = Agent.get(pid, & &1)
    write_worker_summary(telemetry, telemetry_state)
    Agent.stop(pid, :normal, 1_000)
    :ok
  catch
    :exit, _reason -> :ok
  end

  def stop(_telemetry), do: :ok

  @spec delta_from_cumulative(usage(), usage()) :: usage()
  def delta_from_cumulative(previous, current) when is_map(previous) and is_map(current) do
    %{
      input_tokens: positive_delta(previous, current, :input_tokens),
      cached_input_tokens: positive_delta(previous, current, :cached_input_tokens),
      output_tokens: positive_delta(previous, current, :output_tokens),
      total_tokens: positive_delta(previous, current, :total_tokens)
    }
  end

  @spec command_summary(String.t() | nil) :: command_summary()
  def command_summary(command), do: command_summary(command, nil)

  @spec command_summary(String.t() | nil, Path.t() | nil) :: command_summary()
  def command_summary(command, workspace) when is_binary(command) do
    files = command_files(command, workspace)

    %{
      command_fingerprint: command_fingerprint(command, files),
      files: files,
      phase: phase_for_command(command)
    }
  end

  def command_summary(_command, _workspace) do
    %{command_fingerprint: nil, files: [], phase: "command"}
  end

  defp build_turn(workspace, issue, thread_id, turn_id, opts) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:second)

    %__MODULE__{
      workspace: workspace,
      issue_identifier: issue_identifier(issue),
      issue_id: issue_id(issue),
      thread_id: thread_id,
      turn_id: turn_id,
      turn_number: Keyword.get(opts, :turn_number, 1),
      worker_session_id: "#{thread_id}-#{turn_id}",
      started_at: started_at
    }
  end

  defp initial_state do
    %{
      sequence: 1,
      last_usage: zero_usage(),
      phase_totals: %{},
      command_counts_by_phase: %{},
      current_phase: "startup",
      current_item_id: nil,
      current_command_fingerprint: nil,
      current_files: []
    }
  end

  defp spans_for_payload(%__MODULE__{} = telemetry, state, payload) do
    {event_spans, state} = event_spans_for_payload(telemetry, state, payload)
    {token_spans, state} = token_spans_for_payload(telemetry, state, payload)

    (event_spans ++ token_spans)
    |> Enum.map_reduce(state, fn span, acc ->
      sequence = acc.sequence + 1
      {Map.put(span, "span_id", span_id(sequence)), %{acc | sequence: sequence}}
    end)
  end

  defp event_spans_for_payload(%__MODULE__{} = telemetry, state, payload) do
    method = map_value(payload, ["method", :method])
    command = command_text(payload)
    item_id = item_id(payload) || state.current_item_id

    cond do
      is_binary(command) ->
        summary = command_summary(command, telemetry.workspace)

        state =
          state
          |> Map.put(:current_phase, summary.phase)
          |> Map.put(:current_item_id, item_id)
          |> Map.put(:current_command_fingerprint, summary.command_fingerprint)
          |> Map.put(:current_files, summary.files)
          |> count_command(summary.phase, summary.command_fingerprint)

        {[
           base_span(telemetry, state, "command", summary.phase, %{
             "command_fingerprint" => summary.command_fingerprint,
             "files" => summary.files
           })
         ], state}

      method in ["item/started", "item/completed", "item/tool/call"] ->
        phase = phase_for_method(method)
        state = %{state | current_phase: phase, current_item_id: item_id}

        {[base_span(telemetry, state, item_kind(method), phase, %{})], state}

      is_binary(method) and reasoning_method?(method, payload) ->
        state = %{state | current_phase: "reasoning", current_item_id: item_id}
        {[], state}

      true ->
        {[], state}
    end
  end

  defp token_spans_for_payload(%__MODULE__{} = telemetry, state, payload) do
    case cumulative_usage(payload) do
      nil ->
        {[], state}

      current_usage ->
        delta = delta_from_cumulative(state.last_usage, current_usage)
        state = %{state | last_usage: current_usage}

        if positive_usage?(delta) do
          state = %{
            state
            | phase_totals: Map.update(state.phase_totals, state.current_phase, delta.total_tokens, &(&1 + delta.total_tokens))
          }

          span =
            base_span(telemetry, state, "token_update", state.current_phase, %{
              "input_tokens_delta" => delta.input_tokens,
              "cached_input_tokens_delta" => delta.cached_input_tokens,
              "output_tokens_delta" => delta.output_tokens,
              "total_tokens_delta" => delta.total_tokens,
              "counted_guard_tokens_delta" => max(delta.input_tokens - delta.cached_input_tokens, 0),
              "command_fingerprint" => state.current_command_fingerprint,
              "files" => state.current_files
            })

          {[span], state}
        else
          {[], state}
        end
    end
  end

  defp start_span(%__MODULE__{} = telemetry) do
    now = timestamp(telemetry.started_at)

    %{
      "schema_version" => @schema_version,
      "span_id" => span_id(1),
      "issue" => telemetry.issue_identifier,
      "linear_issue_id" => telemetry.issue_id,
      "worker_session_id" => telemetry.worker_session_id,
      "thread_id" => telemetry.thread_id,
      "turn_id" => telemetry.turn_id,
      "turn" => telemetry.turn_number,
      "item_id" => nil,
      "phase" => "startup",
      "kind" => "worker_start",
      "started_at" => now,
      "ended_at" => now,
      "input_tokens_delta" => 0,
      "cached_input_tokens_delta" => 0,
      "output_tokens_delta" => 0,
      "total_tokens_delta" => 0,
      "counted_guard_tokens_delta" => 0,
      "command_fingerprint" => nil,
      "files" => []
    }
  end

  defp base_span(%__MODULE__{} = telemetry, state, kind, phase, attrs) do
    now = timestamp()

    Map.merge(
      %{
        "schema_version" => @schema_version,
        "issue" => telemetry.issue_identifier,
        "linear_issue_id" => telemetry.issue_id,
        "worker_session_id" => telemetry.worker_session_id,
        "thread_id" => telemetry.thread_id,
        "turn_id" => telemetry.turn_id,
        "turn" => telemetry.turn_number,
        "item_id" => state.current_item_id,
        "phase" => phase,
        "kind" => kind,
        "started_at" => now,
        "ended_at" => now,
        "input_tokens_delta" => 0,
        "cached_input_tokens_delta" => 0,
        "output_tokens_delta" => 0,
        "total_tokens_delta" => 0,
        "counted_guard_tokens_delta" => 0,
        "command_fingerprint" => nil,
        "files" => []
      },
      attrs
    )
  end

  defp cumulative_usage(payload) when is_map(payload) do
    [
      ["params", "msg", "payload", "info", "total_token_usage"],
      ["params", "msg", "info", "total_token_usage"],
      ["params", "tokenUsage", "total"],
      ["tokenUsage", "total"]
    ]
    |> Enum.find_value(fn path ->
      payload
      |> map_path(path)
      |> normalize_usage()
    end)
  end

  defp cumulative_usage(_payload), do: nil

  defp normalize_usage(%{} = usage) do
    input_tokens =
      usage
      |> map_value(["input_tokens", "inputTokens", "prompt_tokens", :input_tokens, :inputTokens, :prompt_tokens])
      |> integer_value()

    cached_input_tokens =
      usage
      |> map_value(["cached_input_tokens", "cachedInputTokens", :cached_input_tokens, :cachedInputTokens])
      |> integer_value()

    output_tokens =
      usage
      |> map_value(["output_tokens", "outputTokens", "completion_tokens", :output_tokens, :outputTokens, :completion_tokens])
      |> integer_value()

    explicit_total =
      usage
      |> map_value(["total_tokens", "totalTokens", "total", :total_tokens, :totalTokens, :total])
      |> integer_value()

    total_tokens = explicit_total || sum_if_present(input_tokens, output_tokens)

    if is_integer(total_tokens) do
      %{
        input_tokens: input_tokens || 0,
        cached_input_tokens: cached_input_tokens || 0,
        output_tokens: output_tokens || 0,
        total_tokens: total_tokens
      }
    end
  end

  defp normalize_usage(_usage), do: nil

  defp sum_if_present(left, right) when is_integer(left) and is_integer(right), do: left + right
  defp sum_if_present(_left, _right), do: nil

  defp positive_delta(previous, current, key) do
    max(Map.get(current, key, 0) - Map.get(previous, key, 0), 0)
  end

  defp zero_usage do
    %{input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, total_tokens: 0}
  end

  defp positive_usage?(usage) do
    usage.input_tokens > 0 or usage.cached_input_tokens > 0 or usage.output_tokens > 0 or usage.total_tokens > 0
  end

  defp phase_for_method("item/tool/call"), do: "tool"
  defp phase_for_method(_method), do: "reasoning"

  defp item_kind("item/tool/call"), do: "tool_call"
  defp item_kind("item/started"), do: "item_started"
  defp item_kind("item/completed"), do: "item_completed"
  defp item_kind(_method), do: "item"

  defp reasoning_method?(method, payload) when is_binary(method) do
    String.contains?(method, "reasoning") or wrapper_event_type(payload) in ["agent_reasoning", "agent_reasoning_section_break"]
  end

  defp reasoning_method?(_method, _payload), do: false

  defp phase_for_command(command) do
    normalized = String.downcase(command)

    cond do
      String.contains?(normalized, ["apply_patch", "mix format"]) ->
        "edit"

      Regex.match?(~r/(^|\s)(mix\s+test|mix\s+specs\.check|make\s+(all|test|coverage|dialyzer)|pnpm|npm|yarn|vitest|eslint|tsc|playwright)(\s|$)/, normalized) ->
        "validation"

      Regex.match?(~r/(^|\s)(gh\s+pr|gh\s+api|@codex\s+review)(\s|$)/, normalized) ->
        "review_handoff"

      Regex.match?(~r/(^|\s)(git\s+(status|add|commit|push|fetch|merge)|linear|orocsy\.py.*event\s+append)(\s|$)/, normalized) ->
        "handoff"

      Regex.match?(~r/(^|\s)(sed|cat|head|tail|nl|rg|grep|git\s+show|git\s+diff)(\s|$)/, normalized) ->
        "code_read"

      true ->
        "command"
    end
  end

  defp command_fingerprint(command, files) do
    normalized = normalize_command(command) || ""
    prefix = command_fingerprint_prefix(normalized)

    file_suffix =
      files
      |> Enum.take(3)
      |> Enum.map(&path_fingerprint/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("-")

    [prefix, file_suffix]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("-")
    |> String.slice(0, 160)
  end

  defp command_fingerprint_prefix(command) when is_binary(command) do
    Enum.find_value(@command_fingerprint_patterns, command_head(command), fn {regex, label} ->
      if Regex.match?(regex, command), do: label
    end)
  end

  defp command_head(command) when is_binary(command) do
    command
    |> String.replace(~r/^[A-Z0-9_]+=[^\s]+\s+/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.find_value(fn token ->
      token = token |> String.trim(~s("'")) |> Path.basename()

      if token in ["bash", "zsh", "sh", "-lc"] or String.starts_with?(token, "-") do
        nil
      else
        token
      end
    end)
    |> case do
      nil -> "command"
      token -> token |> String.replace(~r/[^A-Za-z0-9_.-]/, "-") |> String.downcase()
    end
  end

  defp command_files(command, workspace) do
    ~r/(?:^|[\s"'=])((?:\.\/|\/)?[A-Za-z0-9_@~.\-\/\[\]]+\.(?:ex|exs|heex|ts|tsx|js|jsx|mjs|cjs|md|json|yml|yaml|css|scss|html|txt))(?=$|[\s"',:])/
    |> Regex.scan(command, capture: :all_but_first)
    |> Enum.flat_map(fn
      [path] -> [normalize_path(path, workspace)]
      _ -> []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(12)
  end

  defp normalize_path(path, workspace) when is_binary(path) do
    path =
      path
      |> String.trim()
      |> String.trim_leading("./")
      |> String.trim_trailing(".")

    cond do
      String.starts_with?(path, ["http://", "https://"]) ->
        nil

      is_binary(workspace) and Path.type(path) == :absolute ->
        relative_path(path, workspace)

      String.starts_with?(path, "../") or String.contains?(path, "/../") ->
        nil

      true ->
        path
    end
  end

  defp normalize_path(_path, _workspace), do: nil

  defp relative_path(path, workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_path = Path.expand(path)

    if String.starts_with?(expanded_path, expanded_workspace <> "/") do
      Path.relative_to(expanded_path, expanded_workspace)
    end
  end

  defp path_fingerprint(path) do
    path
    |> String.replace(~r/[^A-Za-z0-9.\/_-]/, "-")
    |> String.trim("/")
    |> String.replace("/", "-")
    |> String.downcase()
  end

  defp command_text(payload) do
    payload
    |> command_candidate()
    |> normalize_command()
    |> case do
      nil -> function_call_command_text(payload)
      command -> command
    end
  end

  defp function_call_command_text(payload) do
    payload
    |> function_call_candidates()
    |> Enum.find_value(&exec_command_function_call_text/1)
  end

  defp function_call_candidates(payload) do
    [
      payload,
      map_path(payload, ["payload"]),
      map_path(payload, ["params"]),
      map_path(payload, ["params", "payload"]),
      map_path(payload, ["params", "msg"]),
      map_path(payload, ["params", "msg", "payload"]),
      map_path(payload, ["params", "item"]),
      map_path(payload, ["params", "item", "payload"])
    ]
    |> Enum.filter(&is_map/1)
  end

  defp exec_command_function_call_text(%{"type" => "function_call", "name" => name} = item)
       when is_binary(name) do
    if name == "exec_command" or String.ends_with?(name, ".exec_command") do
      item
      |> Map.get("arguments")
      |> decode_function_call_arguments()
      |> command_from_function_call_arguments()
      |> normalize_command()
    end
  end

  defp exec_command_function_call_text(_item), do: nil

  defp decode_function_call_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{"cmd" => arguments}
    end
  end

  defp decode_function_call_arguments(%{} = arguments), do: arguments
  defp decode_function_call_arguments(_arguments), do: nil

  defp command_from_function_call_arguments(%{} = arguments) do
    map_value(arguments, ["cmd", "command", "parsedCmd"])
  end

  defp command_from_function_call_arguments(_arguments), do: nil

  defp command_candidate(payload) do
    map_path(payload, ["params", "msg", "command"]) ||
      map_path(payload, ["params", "command"]) ||
      map_path(payload, ["params", "parsedCmd"]) ||
      map_path(payload, ["params", "cmd"]) ||
      map_path(payload, ["params", "item", "command"]) ||
      map_path(payload, ["params", "item", "parsedCmd"])
  end

  defp normalize_command(command) when is_binary(command) do
    command
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      command
      |> Enum.join(" ")
      |> normalize_command()
    end
  end

  defp normalize_command(%{} = command) do
    binary_command = map_value(command, ["parsedCmd", "command", "cmd"])
    args = map_value(command, ["args", "argv"])

    cond do
      is_binary(binary_command) and is_list(args) -> normalize_command([binary_command | args])
      is_binary(binary_command) -> normalize_command(binary_command)
      is_list(args) -> normalize_command(args)
      true -> nil
    end
  end

  defp normalize_command(_command), do: nil

  defp item_id(payload) do
    map_path(payload, ["params", "item", "id"]) ||
      map_path(payload, ["params", "itemId"]) ||
      map_path(payload, ["params", "callId"]) ||
      map_path(payload, ["params", "msg", "id"]) ||
      map_value(payload, ["id", :id])
  end

  defp wrapper_event_type(payload) do
    map_path(payload, ["params", "msg", "type"]) ||
      map_path(payload, ["params", "type"])
  end

  defp issue_identifier(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(%{"identifier" => identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue), do: nil

  defp issue_id(%{id: id}) when is_binary(id), do: id
  defp issue_id(%{"id" => id}) when is_binary(id), do: id
  defp issue_id(_issue), do: nil

  defp append_span(%__MODULE__{workspace: workspace}, span) do
    File.write!(spans_file(workspace), Jason.encode!(span) <> "\n", [:append])
  end

  defp write_worker_summary(%__MODULE__{enabled: true, workspace: workspace} = telemetry, state)
       when is_binary(workspace) and is_map(state) do
    summary = worker_summary(telemetry, state)
    File.write!(workers_file(workspace), Jason.encode!(summary) <> "\n", [:append])
    File.write!(summary_file(workspace, telemetry), markdown_summary(summary))
    :ok
  rescue
    error in [File.Error, RuntimeError, ArgumentError] ->
      Logger.warning("Token telemetry summary failed: #{Exception.message(error)}")
      :ok
  end

  defp write_worker_summary(_telemetry, _state), do: :ok

  defp worker_summary(%__MODULE__{} = telemetry, state) do
    progress = progress_evidence(telemetry)
    usage = state.last_usage
    counted_guard_tokens = max(usage.input_tokens - usage.cached_input_tokens, 0)
    status = worker_status(progress)

    %{
      "schema_version" => @schema_version,
      "issue" => telemetry.issue_identifier,
      "linear_issue_id" => telemetry.issue_id,
      "worker_session_id" => telemetry.worker_session_id,
      "thread_id" => telemetry.thread_id,
      "turn_id" => telemetry.turn_id,
      "turn" => telemetry.turn_number,
      "started_at" => timestamp(telemetry.started_at),
      "ended_at" => timestamp(),
      "status" => status,
      "total_tokens" => usage.total_tokens,
      "input_tokens" => usage.input_tokens,
      "cached_input_tokens" => usage.cached_input_tokens,
      "output_tokens" => usage.output_tokens,
      "counted_guard_tokens" => counted_guard_tokens,
      "durable_progress_events" => progress.events,
      "dirty_files" => progress.dirty_files,
      "new_commits" => progress.new_commits,
      "top_phases" => top_phases(state.phase_totals),
      "loop_signatures" => loop_signatures(status, state)
    }
  end

  defp progress_evidence(%__MODULE__{workspace: workspace, started_at: started_at})
       when is_binary(workspace) and not is_nil(started_at) do
    %{
      dirty_files: git_dirty_files(workspace),
      new_commits: git_new_commits(workspace),
      events: durable_progress_events(workspace, started_at)
    }
  end

  defp progress_evidence(_telemetry), do: %{dirty_files: [], new_commits: [], events: []}

  defp worker_status(%{dirty_files: [_ | _]}), do: "productive"
  defp worker_status(%{new_commits: [_ | _]}), do: "handoff_recovery"
  defp worker_status(%{events: [_ | _]}), do: "productive"
  defp worker_status(_progress), do: "blocked_no_durable_progress"

  defp count_command(state, phase, fingerprint)
       when is_binary(phase) and is_binary(fingerprint) and fingerprint != "" do
    command_counts_by_phase =
      Map.update(state.command_counts_by_phase, phase, %{fingerprint => 1}, fn phase_counts ->
        Map.update(phase_counts, fingerprint, 1, &(&1 + 1))
      end)

    %{state | command_counts_by_phase: command_counts_by_phase}
  end

  defp count_command(state, _phase, _fingerprint), do: state

  defp loop_signatures(status, state) do
    no_progress_signatures(status) ++ command_loop_signatures(state)
  end

  defp no_progress_signatures("blocked_no_durable_progress"), do: ["no_durable_progress"]
  defp no_progress_signatures(_status), do: []

  defp command_loop_signatures(%{command_counts_by_phase: counts}) when is_map(counts) do
    [
      {"code_read", "read_loop"},
      {"review_handoff", "review_loop"},
      {"validation", "validation_loop"},
      {"handoff", "handoff_loop"}
    ]
    |> Enum.flat_map(fn {phase, signature} ->
      if repeated_command_phase?(counts, phase), do: [signature], else: []
    end)
  end

  defp command_loop_signatures(_state), do: []

  defp repeated_command_phase?(counts, phase) do
    counts
    |> Map.get(phase, %{})
    |> Enum.any?(fn {_fingerprint, count} -> count >= 2 end)
  end

  defp top_phases(phase_totals) when is_map(phase_totals) do
    phase_totals
    |> Enum.map(fn {phase, total_tokens} -> %{"phase" => phase, "total_tokens" => total_tokens} end)
    |> Enum.sort_by(& &1["total_tokens"], :desc)
  end

  defp git_dirty_files(workspace) do
    case System.cmd("git", ["status", "--porcelain=v1"], cd: workspace, stderr_to_stdout: true) do
      {status, 0} ->
        status
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&porcelain_status_paths/1)
        |> Enum.reject(&generated_runtime_path?/1)
        |> Enum.uniq()

      {_output, _exit_code} ->
        []
    end
  rescue
    _error -> []
  end

  defp git_new_commits(workspace) do
    base_refs =
      ["@{upstream}", "origin/main", "main"]
      |> Enum.filter(&git_ref_exists?(workspace, &1))

    if base_refs == [] do
      []
    else
      args = ["log", "--format=%H", "HEAD"] ++ Enum.flat_map(base_refs, &[~s(--not), &1])

      case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
        {output, 0} -> String.split(output, "\n", trim: true)
        {_output, _exit_code} -> []
      end
    end
  rescue
    _error -> []
  end

  defp git_ref_exists?(workspace, ref) do
    case System.cmd("git", ["rev-parse", "--verify", "--quiet", ref], cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _exit_code} -> false
    end
  rescue
    _error -> false
  end

  defp durable_progress_events(workspace, %DateTime{} = started_at) do
    workspace
    |> event_paths()
    |> Enum.flat_map(&durable_progress_events_from_path(&1, started_at))
  end

  defp event_paths(workspace) do
    [
      Path.join(workspace, ".orocsy/delivery/events/events.jsonl"),
      Path.join(workspace, ".codex/delivery/events/events.jsonl")
    ]
  end

  defp durable_progress_events_from_path(path, started_at) do
    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.flat_map(&durable_progress_event_from_line(&1, started_at))
    else
      []
    end
  rescue
    _error -> []
  end

  defp durable_progress_event_from_line(line, %DateTime{} = started_at) when is_binary(line) do
    with {:ok, %{} = event} <- Jason.decode(line),
         true <- Map.get(event, "status") == "passed",
         true <- durable_progress_event?(event),
         %DateTime{} = occurred_at <- event |> Map.get("ts") |> datetime_from_iso8601(),
         true <- datetime_at_or_after?(occurred_at, started_at) do
      [
        %{
          "event" => event_name(event),
          "tool" => Map.get(event, "tool"),
          "phase" => Map.get(event, "phase"),
          "ts" => DateTime.to_iso8601(occurred_at)
        }
      ]
    else
      _ -> []
    end
  end

  defp durable_progress_event?(event) when is_map(event) do
    event_name(event)
    |> case do
      "tool.finished" -> true
      "gate." <> _rest -> true
      "eval." <> _rest -> true
      "handoff." <> _rest -> true
      _ -> false
    end
  end

  defp event_name(event) do
    event
    |> map_value(["event", "type"])
    |> case do
      name when is_binary(name) -> name
      _ -> ""
    end
  end

  defp datetime_from_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp datetime_from_iso8601(_value), do: nil

  defp datetime_at_or_after?(%DateTime{} = datetime, %DateTime{} = cutoff) do
    DateTime.compare(datetime, cutoff) in [:eq, :gt]
  end

  defp porcelain_status_paths(line) when byte_size(line) >= 4 do
    path =
      line
      |> String.slice(3..-1//1)
      |> String.replace_prefix(~s("), "")
      |> String.replace_suffix(~s("), "")

    case path do
      "" -> []
      path -> [path |> String.split(" -> ") |> List.last()]
    end
  end

  defp porcelain_status_paths(_line), do: []

  defp generated_runtime_path?(path) when is_binary(path) do
    String.starts_with?(path, [".orocsy/", ".codex/"])
  end

  defp generated_runtime_path?(_path), do: false

  defp markdown_summary(summary) do
    """
    #{summary["issue"] || "unknown issue"} / #{summary["worker_session_id"]} / turn #{summary["turn"]}

    Status: #{summary["status"]}
    Total: #{summary["total_tokens"]} tokens
    Cached input: #{summary["cached_input_tokens"]}
    Counted guard tokens: #{summary["counted_guard_tokens"]}
    Output: #{summary["output_tokens"]}

    Top phases:
    #{markdown_phase_lines(summary["top_phases"])}

    Durable progress:
    - dirty files: #{markdown_value_list(summary["dirty_files"])}
    - commits: #{markdown_value_list(summary["new_commits"])}
    - current-run Orocsy progress events: #{markdown_event_list(summary["durable_progress_events"])}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp markdown_phase_lines([]), do: "- none"

  defp markdown_phase_lines(phases) when is_list(phases) do
    phases
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {phase, index} ->
      "#{index}. #{phase["phase"]}: #{phase["total_tokens"]}"
    end)
  end

  defp markdown_value_list([]), do: "none"
  defp markdown_value_list(values) when is_list(values), do: Enum.join(values, ", ")

  defp markdown_event_list([]), do: "none"

  defp markdown_event_list(events) when is_list(events) do
    events
    |> Enum.map(fn event -> event["event"] end)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> case do
      [] -> "none"
      names -> Enum.join(names, ", ")
    end
  end

  defp spans_dir(workspace), do: workspace |> Path.join(@spans_path) |> Path.dirname()
  defp spans_file(workspace), do: Path.join(workspace, @spans_path)
  defp workers_file(workspace), do: Path.join(workspace, @workers_path)
  defp summaries_dir(workspace), do: Path.join(workspace, @summaries_dir)

  defp summary_file(workspace, %__MODULE__{} = telemetry) do
    file_name = "#{telemetry.issue_identifier || "unknown"}-#{telemetry.worker_session_id}-turn-#{telemetry.turn_number}.md"
    Path.join(summaries_dir(workspace), file_name)
  end

  defp span_id(sequence), do: "span_#{System.unique_integer([:positive, :monotonic])}_#{sequence}"

  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp integer_value(value) when is_integer(value) and value >= 0, do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp map_path(value, []), do: value

  defp map_path(%{} = map, [key | rest]) do
    case Map.fetch(map, key) do
      {:ok, value} -> map_path(value, rest)
      :error -> nil
    end
  end

  defp map_path(_value, _path), do: nil

  defp map_value(%{} = map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_value(_map, _keys), do: nil
end
