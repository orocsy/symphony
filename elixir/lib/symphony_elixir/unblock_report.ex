defmodule SymphonyElixir.UnblockReport do
  @moduledoc """
  Builds operator-facing summaries for runtime scope unblocks.
  """

  @type t :: %{String.t() => term()}

  @spec from_correction(map()) :: t() | nil
  def from_correction(%{} = correction) do
    case existing_report(correction) do
      %{} = report ->
        report

      nil ->
        correction
        |> report_inputs()
        |> build_report()
    end
  end

  def from_correction(_correction), do: nil

  @spec markdown(map() | nil) :: String.t() | nil
  def markdown(nil), do: nil

  def markdown(%{} = source) do
    source
    |> report_from_source()
    |> markdown_lines()
  end

  def markdown(_source), do: nil

  @spec summary_line(map() | nil) :: String.t() | nil
  def summary_line(nil), do: nil

  def summary_line(%{} = source) do
    case report_from_source(source) do
      %{} = report ->
        blocked = value(report, "blocker_class") || "scope_blocked"
        asked_for = value(report, "worker_asked_for") || "unknown request"
        next_action = value(report, "next_action") || "inspect correction"

        "Blocked: #{blocked} | Worker asked for: #{asked_for} | Next action: #{next_action}"

      nil ->
        nil
    end
  end

  def summary_line(_source), do: nil

  defp existing_report(%{"unblock_report" => %{} = report}), do: normalize_report(report)
  defp existing_report(_correction), do: nil

  defp report_from_source(%{"blocker_class" => _} = report), do: normalize_report(report)
  defp report_from_source(%{blocker_class: _} = report), do: normalize_report(report)
  defp report_from_source(%{} = correction), do: from_correction(correction)

  defp report_inputs(%{} = correction) do
    guard = map_value(correction, "guard")
    scope_access = map_value(guard, "scope_access")
    retry_fingerprint = map_value(guard, "retry_fingerprint")

    %{
      correction: correction,
      guard: guard || %{},
      scope_access: scope_access || %{},
      retry_fingerprint: retry_fingerprint || %{},
      reason_class: text_value(guard, "reason_class"),
      decision: text_value(guard, "decision") || text_value(scope_access, "decision"),
      source: text_value(correction, "source"),
      next_action: text_value(correction, "next_action"),
      operation: text_value(scope_access, "operation") || text_value(retry_fingerprint, "operation"),
      paths: list_value(scope_access, "paths") || list_value(retry_fingerprint, "paths"),
      policy_hash: text_value(retry_fingerprint, "policy_hash"),
      head_sha: text_value(retry_fingerprint, "head_sha"),
      command_fingerprint:
        text_value(scope_access, "command_fingerprint") ||
          text_value(retry_fingerprint, "command_fingerprint")
    }
  end

  defp build_report(%{source: source, scope_access: scope_access, retry_fingerprint: retry_fingerprint} = inputs) do
    if reportable_scope_access?(source, scope_access, retry_fingerprint) do
      blocker_class = blocker_class(inputs)
      operation = inputs.operation || "unknown"
      paths = inputs.paths || []

      %{
        "blocker_class" => blocker_class,
        "requested_operation" => operation,
        "requested_paths" => paths,
        "worker_asked_for" => worker_asked_for(operation, paths),
        "runtime_decision" => runtime_decision(blocker_class, inputs),
        "why_no_retry" => why_no_retry(blocker_class, inputs),
        "next_action" => next_action(blocker_class, inputs),
        "policy_hash" => inputs.policy_hash,
        "head_sha" => inputs.head_sha,
        "command_fingerprint" => inputs.command_fingerprint
      }
      |> reject_blank_values()
    end
  end

  defp reportable_scope_access?(source, scope_access, retry_fingerprint) do
    source == "symphony.runtime.scope-access" or scope_access != %{} or retry_fingerprint != %{}
  end

  defp blocker_class(%{reason_class: "write_scope_expansion_requires_operator"}) do
    "write_scope_expansion_required"
  end

  defp blocker_class(%{next_action: "retry", retry_fingerprint: retry_fingerprint}) when retry_fingerprint != %{} do
    "scope_policy_stale"
  end

  defp blocker_class(%{decision: "allow_once", reason_class: "safe_read_context"}) do
    "read_context_allowed"
  end

  defp blocker_class(%{operation: "read"}) do
    "safe_read_context_required"
  end

  defp blocker_class(%{reason_class: reason_class}) when is_binary(reason_class) and reason_class != "" do
    reason_class
  end

  defp blocker_class(_inputs), do: "scope_access_blocked"

  defp runtime_decision("scope_policy_stale", _inputs), do: "blocked by stale write_scope policy"

  defp runtime_decision("write_scope_expansion_required", _inputs) do
    "blocked because write scope expansion requires an operator"
  end

  defp runtime_decision("read_context_allowed", _inputs), do: "allowed once as read-only context"

  defp runtime_decision("safe_read_context_required", _inputs) do
    "blocked until read_context or write_scope policy changes"
  end

  defp runtime_decision(_blocker_class, %{reason_class: reason_class})
       when is_binary(reason_class) and reason_class != "" do
    "blocked by #{reason_class}"
  end

  defp runtime_decision(_blocker_class, _inputs), do: "blocked by runtime scope policy"

  defp why_no_retry("scope_policy_stale", _inputs), do: "same head and same policy hash"

  defp why_no_retry("write_scope_expansion_required", _inputs) do
    "write access cannot be auto-promoted from read context"
  end

  defp why_no_retry("read_context_allowed", _inputs), do: "read request is scoped and read-only"

  defp why_no_retry("safe_read_context_required", _inputs) do
    "requested path is outside current read_context and write_scope"
  end

  defp why_no_retry(_blocker_class, _inputs), do: "runtime policy needs operator review"

  defp next_action("write_scope_expansion_required", _inputs) do
    "update Linear write scope or narrow the worker command, then redispatch"
  end

  defp next_action("read_context_allowed", _inputs), do: "continue worker with read-context policy patch"

  defp next_action(_blocker_class, _inputs) do
    "add read_context or update Linear write scope, then redispatch"
  end

  defp worker_asked_for(operation, []), do: operation
  defp worker_asked_for(operation, paths), do: "#{operation} #{Enum.join(paths, ", ")}"

  defp markdown_lines(nil), do: nil

  defp markdown_lines(%{} = report) do
    [
      "Blocked: #{value(report, "blocker_class") || "scope_access_blocked"}",
      "Worker asked for: #{value(report, "worker_asked_for") || "unknown request"}",
      "Runtime decision: #{value(report, "runtime_decision") || "blocked by runtime scope policy"}",
      optional_line("Policy hash", value(report, "policy_hash")),
      optional_line("Head SHA", value(report, "head_sha")),
      optional_line("Why no retry", value(report, "why_no_retry")),
      "Next action: #{value(report, "next_action") || "inspect correction"}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp optional_line(_label, value) when value in [nil, "", []], do: nil
  defp optional_line(label, value), do: "#{label}: #{value}"

  defp normalize_report(%{} = report) do
    report
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Map.new()
    |> reject_blank_values()
  end

  defp reject_blank_values(%{} = map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp map_value(%{} = map, key) do
    case value(map, key) do
      %{} = nested -> nested
      _ -> nil
    end
  end

  defp map_value(_map, _key), do: nil

  defp text_value(%{} = map, key) do
    case value(map, key) do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> nil
    end
  end

  defp text_value(_map, _key), do: nil

  defp list_value(%{} = map, key) do
    case value(map, key) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      value when is_binary(value) and value != "" -> [value]
      _ -> nil
    end
  end

  defp list_value(_map, _key), do: nil

  defp value(%{} = map, key) when is_binary(key) do
    Map.get(map, key) || existing_atom_value(map, key)
  end

  defp value(_map, _key), do: nil

  defp existing_atom_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end
end
