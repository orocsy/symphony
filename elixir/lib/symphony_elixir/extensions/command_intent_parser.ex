defmodule SymphonyElixir.Extensions.CommandIntentParser do
  @moduledoc false

  alias SymphonyElixir.Extensions.CommandIntent
  alias SymphonyElixir.Extensions.CommandIntent.CommandExecution
  alias SymphonyElixir.Extensions.CommandIntent.DynamicToolCall
  alias SymphonyElixir.Extensions.CommandIntent.FileChangeApproval
  alias SymphonyElixir.Extensions.CommandIntent.LegacyApplyPatch
  alias SymphonyElixir.Extensions.CommandIntent.LegacyExecCommand
  alias SymphonyElixir.Extensions.CommandIntent.ToolApproval
  alias SymphonyElixir.Extensions.TurnContext

  @command_method "item/commandExecution/requestApproval"
  @file_method "item/fileChange/requestApproval"
  @legacy_exec_method "execCommandApproval"
  @legacy_patch_method "applyPatchApproval"
  @dynamic_tool_method "item/tool/call"
  @tool_approval_method "item/tool/requestUserInput"

  @type request_facts :: {String.t(), map()}
  @type result :: {:ok, CommandIntent.t()} | {:error, atom()}

  @spec parse(request_facts(), TurnContext.t()) :: result()
  def parse({method, payload}, %TurnContext{} = context)
      when is_binary(method) and is_map(payload) do
    with {:ok, request_id} <- request_id(payload),
         :ok <- matching_method(payload, method),
         {:ok, params} <- required_map(payload, "params"),
         {:ok, operation} <- parse_operation(method, params, context) do
      {:ok, %CommandIntent{request_id: request_id, operation: operation}}
    end
  end

  defp parse_operation(@command_method, params, context),
    do: parse_command_execution(params, context)

  defp parse_operation(@file_method, params, context),
    do: parse_file_change(params, context)

  defp parse_operation(@legacy_exec_method, params, context),
    do: parse_legacy_exec(params, context)

  defp parse_operation(@legacy_patch_method, params, context),
    do: parse_legacy_patch(params, context)

  defp parse_operation(@dynamic_tool_method, params, context),
    do: parse_dynamic_tool(params, context)

  defp parse_operation(@tool_approval_method, params, context),
    do: parse_tool_approval(params, context)

  defp parse_operation(_method, _params, _context), do: {:error, :unknown_authorization_method}

  defp parse_command_execution(params, context) do
    with {:ok, item_id} <- required_binary(params, "itemId"),
         {:ok, thread_id} <- required_binary(params, "threadId"),
         {:ok, turn_id} <- required_binary(params, "turnId"),
         :ok <- match_turn(thread_id, turn_id, context),
         {:ok, approval_id} <- optional_binary(params, "approvalId"),
         {:ok, command} <- optional_binary(params, "command"),
         {:ok, cwd} <- optional_absolute_path(params, "cwd"),
         {:ok, reason} <- optional_binary(params, "reason"),
         {:ok, actions} <- optional_list(params, "commandActions", &parse_command_action(&1, cwd || context.workspace)),
         {:ok, network_approval} <- optional_network_approval(params),
         {:ok, execpolicy} <- optional_string_list(params, "proposedExecpolicyAmendment"),
         {:ok, network_amendments} <- optional_list(params, "proposedNetworkPolicyAmendments", &parse_network_amendment/1) do
      {:ok,
       %CommandExecution{
         approval_id: approval_id,
         command: command,
         command_actions: actions,
         cwd: cwd,
         item_id: item_id,
         network_approval: network_approval,
         proposed_execpolicy_amendment: execpolicy,
         proposed_network_policy_amendments: network_amendments,
         reason: reason,
         thread_id: thread_id,
         turn_id: turn_id
       }}
    end
  end

  defp parse_file_change(params, context) do
    with {:ok, item_id} <- required_binary(params, "itemId"),
         {:ok, thread_id} <- required_binary(params, "threadId"),
         {:ok, turn_id} <- required_binary(params, "turnId"),
         :ok <- match_turn(thread_id, turn_id, context),
         {:ok, grant_root} <- optional_path(params, "grantRoot", context.workspace),
         {:ok, reason} <- optional_binary(params, "reason") do
      {:ok,
       %FileChangeApproval{
         grant_root: grant_root,
         item_id: item_id,
         reason: reason,
         thread_id: thread_id,
         turn_id: turn_id
       }}
    end
  end

  defp parse_legacy_exec(params, context) do
    with {:ok, call_id} <- required_binary(params, "callId"),
         {:ok, conversation_id} <- required_binary(params, "conversationId"),
         :ok <- match_thread(conversation_id, context),
         {:ok, argv} <- required_string_list(params, "command"),
         {:ok, cwd} <- required_path(params, "cwd", context.workspace),
         {:ok, parsed_actions} <- required_list(params, "parsedCmd", &parse_legacy_action(&1, cwd)),
         {:ok, reason} <- optional_binary(params, "reason"),
         {:ok, approval_id} <- optional_binary(params, "approvalId") do
      {:ok,
       %LegacyExecCommand{
         approval_id: approval_id,
         argv: argv,
         call_id: call_id,
         conversation_id: conversation_id,
         cwd: cwd,
         parsed_actions: parsed_actions,
         reason: reason
       }}
    end
  end

  defp parse_legacy_patch(params, context) do
    with {:ok, call_id} <- required_binary(params, "callId"),
         {:ok, conversation_id} <- required_binary(params, "conversationId"),
         :ok <- match_thread(conversation_id, context),
         {:ok, changes} <- parse_changes(params, context.workspace),
         {:ok, grant_root} <- optional_path(params, "grantRoot", context.workspace),
         {:ok, reason} <- optional_binary(params, "reason") do
      {:ok,
       %LegacyApplyPatch{
         call_id: call_id,
         changes: changes,
         conversation_id: conversation_id,
         grant_root: grant_root,
         reason: reason
       }}
    end
  end

  defp parse_dynamic_tool(params, context) do
    with {:ok, tool} <- required_binary(params, "tool"),
         {:ok, call_id} <- required_binary(params, "callId"),
         {:ok, thread_id} <- required_binary(params, "threadId"),
         {:ok, turn_id} <- required_binary(params, "turnId"),
         :ok <- match_turn(thread_id, turn_id, context),
         {:ok, arguments} <- required_json(params, "arguments") do
      {:ok,
       %DynamicToolCall{
         arguments: arguments,
         arguments_validated?: false,
         call_id: call_id,
         thread_id: thread_id,
         tool: tool,
         turn_id: turn_id
       }}
    end
  end

  defp parse_tool_approval(params, context) do
    with {:ok, item_id} <- required_binary(params, "itemId"),
         {:ok, thread_id} <- required_binary(params, "threadId"),
         {:ok, turn_id} <- required_binary(params, "turnId"),
         {:ok, questions} <- required_nonempty_list(params, "questions", &parse_question/1),
         :ok <- unique_question_ids(questions),
         :ok <- match_turn(thread_id, turn_id, context) do
      {:ok,
       %ToolApproval{
         item_id: item_id,
         questions: questions,
         thread_id: thread_id,
         turn_id: turn_id
       }}
    end
  end

  defp parse_command_action(
         %{"type" => "read", "command" => command, "name" => name, "path" => path},
         base
       )
       when is_binary(command) and is_binary(name) and is_binary(path) do
    if Path.type(path) == :absolute do
      {:ok,
       %CommandExecution.ReadAction{
         command: command,
         name: name,
         path: normalize_path(path, base)
       }}
    else
      {:error, :command_action_invalid}
    end
  end

  defp parse_command_action(%{"type" => "listFiles", "command" => command} = action, base)
       when is_binary(command) do
    with {:ok, path} <- optional_path(action, "path", base) do
      {:ok, %CommandExecution.ListFilesAction{command: command, path: path}}
    end
  end

  defp parse_command_action(%{"type" => "search", "command" => command} = action, base)
       when is_binary(command) do
    with {:ok, path} <- optional_path(action, "path", base),
         {:ok, query} <- optional_binary(action, "query") do
      {:ok, %CommandExecution.SearchAction{command: command, path: path, query: query}}
    end
  end

  defp parse_command_action(%{"type" => "unknown", "command" => command}, _base)
       when is_binary(command) do
    {:ok, %CommandExecution.UnknownAction{command: command}}
  end

  defp parse_command_action(_action, _base), do: {:error, :command_action_invalid}

  defp parse_legacy_action(
         %{"type" => "read", "cmd" => command, "name" => name, "path" => path},
         base
       )
       when is_binary(command) and is_binary(name) and is_binary(path) do
    {:ok,
     %LegacyExecCommand.ReadAction{
       command: command,
       name: name,
       path: normalize_path(path, base)
     }}
  end

  defp parse_legacy_action(%{"type" => "list_files", "cmd" => command} = action, base)
       when is_binary(command) do
    with {:ok, path} <- optional_path(action, "path", base) do
      {:ok, %LegacyExecCommand.ListFilesAction{command: command, path: path}}
    end
  end

  defp parse_legacy_action(%{"type" => "search", "cmd" => command} = action, base)
       when is_binary(command) do
    with {:ok, path} <- optional_path(action, "path", base),
         {:ok, query} <- optional_binary(action, "query") do
      {:ok, %LegacyExecCommand.SearchAction{command: command, path: path, query: query}}
    end
  end

  defp parse_legacy_action(%{"type" => "unknown", "cmd" => command}, _base)
       when is_binary(command) do
    {:ok, %LegacyExecCommand.UnknownAction{command: command}}
  end

  defp parse_legacy_action(_action, _base), do: {:error, :parsed_command_invalid}

  defp optional_network_approval(params) do
    case Map.get(params, "networkApprovalContext") do
      nil ->
        {:ok, nil}

      %{"host" => host, "protocol" => protocol} when is_binary(host) ->
        with {:ok, normalized} <- network_protocol(protocol) do
          {:ok, %CommandExecution.NetworkApproval{host: host, protocol: normalized}}
        end

      _other ->
        {:error, :network_approval_invalid}
    end
  end

  defp parse_network_amendment(%{"action" => action, "host" => host}) when is_binary(host) do
    case action do
      "allow" -> {:ok, %CommandExecution.NetworkAmendment{action: :allow, host: host}}
      "deny" -> {:ok, %CommandExecution.NetworkAmendment{action: :deny, host: host}}
      _other -> {:error, :network_amendment_invalid}
    end
  end

  defp parse_network_amendment(_amendment), do: {:error, :network_amendment_invalid}

  defp network_protocol("http"), do: {:ok, :http}
  defp network_protocol("https"), do: {:ok, :https}
  defp network_protocol("socks5Tcp"), do: {:ok, :socks5_tcp}
  defp network_protocol("socks5Udp"), do: {:ok, :socks5_udp}
  defp network_protocol(_protocol), do: {:error, :network_protocol_invalid}

  defp parse_changes(params, base) do
    case Map.fetch(params, "fileChanges") do
      {:ok, changes} when is_map(changes) ->
        changes
        |> Enum.sort_by(fn {path, _change} -> path end)
        |> map_items(fn {path, change} -> parse_change(path, change, base) end)

      _other ->
        {:error, :file_changes_invalid}
    end
  end

  defp parse_change(path, %{"type" => "add", "content" => content}, base)
       when is_binary(path) and is_binary(content) do
    {:ok,
     %LegacyApplyPatch.TargetChange{
       move_path: nil,
       operation: :add,
       path: normalize_path(path, base)
     }}
  end

  defp parse_change(path, %{"type" => "delete", "content" => content}, base)
       when is_binary(path) and is_binary(content) do
    {:ok,
     %LegacyApplyPatch.TargetChange{
       move_path: nil,
       operation: :delete,
       path: normalize_path(path, base)
     }}
  end

  defp parse_change(path, %{"type" => "update", "unified_diff" => diff} = change, base)
       when is_binary(path) and is_binary(diff) do
    normalized_path = normalize_path(path, base)

    with {:ok, move_path} <- optional_path(change, "move_path", Path.dirname(normalized_path)) do
      {:ok,
       %LegacyApplyPatch.TargetChange{
         move_path: move_path,
         operation: :update,
         path: normalized_path
       }}
    end
  end

  defp parse_change(_path, _change, _base), do: {:error, :file_change_invalid}

  defp parse_question(
         %{
           "header" => header,
           "id" => id,
           "question" => question,
           "options" => options
         } = question_payload
       )
       when is_binary(header) and is_binary(id) and is_binary(question) and is_list(options) do
    with :ok <- optional_boolean_field(question_payload, "isOther"),
         :ok <- optional_boolean_field(question_payload, "isSecret"),
         :ok <- prefixed_nonempty_id(id),
         {:ok, labels} <- option_labels(options),
         :ok <- valid_approval_labels(labels) do
      {:ok, %ToolApproval.Question{id: id, option_labels: labels}}
    end
  end

  defp parse_question(_question), do: {:error, :approval_question_invalid}

  defp option_labels(options) do
    map_items(options, fn
      %{"description" => description, "label" => label}
      when is_binary(description) and is_binary(label) ->
        if String.trim(label) == "",
          do: {:error, :approval_option_invalid},
          else: {:ok, label}

      _option ->
        {:error, :approval_option_invalid}
    end)
  end

  defp valid_approval_labels(labels) do
    cond do
      labels == [] -> {:error, :approval_options_empty}
      Enum.uniq(labels) != labels -> {:error, :approval_option_labels_duplicate}
      Enum.count(labels, &(&1 == "Approve Once")) != 1 -> {:error, :approval_option_missing}
      Enum.count(labels, &(&1 == "Deny")) != 1 -> {:error, :approval_option_missing}
      true -> :ok
    end
  end

  defp unique_question_ids(questions) do
    ids = Enum.map(questions, & &1.id)
    if Enum.uniq(ids) == ids, do: :ok, else: {:error, :approval_question_ids_duplicate}
  end

  defp prefixed_nonempty_id(id) do
    if String.starts_with?(id, "mcp_tool_call_approval_") and id != "" do
      :ok
    else
      {:error, :approval_question_invalid}
    end
  end

  defp request_id(payload) do
    case Map.fetch(payload, "id") do
      {:ok, id} when is_binary(id) or is_integer(id) -> {:ok, id}
      _other -> {:error, :request_id_invalid}
    end
  end

  defp matching_method(payload, method) do
    case Map.fetch(payload, "method") do
      :error -> :ok
      {:ok, ^method} -> :ok
      _other -> {:error, :request_method_mismatch}
    end
  end

  defp match_turn(thread_id, turn_id, context) do
    if thread_id == context.thread_id and turn_id == context.turn_id do
      :ok
    else
      {:error, :turn_correlation_mismatch}
    end
  end

  defp match_thread(thread_id, context) do
    if thread_id == context.thread_id,
      do: :ok,
      else: {:error, :turn_correlation_mismatch}
  end

  defp required_binary(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _other -> {:error, :required_binary_invalid}
    end
  end

  defp optional_binary(map, key) do
    case Map.fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, value}
      _other -> {:error, :optional_binary_invalid}
    end
  end

  defp required_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _other -> {:error, :required_map_invalid}
    end
  end

  defp required_path(map, key, base) do
    with {:ok, value} <- required_binary(map, key) do
      {:ok, normalize_path(value, base)}
    end
  end

  defp optional_path(map, key, base) do
    with {:ok, value} <- optional_binary(map, key) do
      {:ok, if(is_nil(value), do: nil, else: normalize_path(value, base))}
    end
  end

  defp optional_absolute_path(map, key) do
    case optional_binary(map, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, path} -> normalize_absolute_path(path)
      {:error, _reason} = error -> error
    end
  end

  defp normalize_absolute_path(path) do
    if Path.type(path) == :absolute,
      do: {:ok, Path.expand(path)},
      else: {:error, :absolute_path_invalid}
  end

  defp normalize_path(path, base), do: Path.expand(path, base)

  defp required_string_list(map, key) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &is_binary/1),
          do: {:ok, values},
          else: {:error, :string_list_invalid}

      _other ->
        {:error, :string_list_invalid}
    end
  end

  defp optional_string_list(map, key) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &is_binary/1),
          do: {:ok, values},
          else: {:error, :string_list_invalid}

      _other ->
        {:error, :string_list_invalid}
    end
  end

  defp required_list(map, key, parser) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) -> map_items(values, parser)
      _other -> {:error, :required_list_invalid}
    end
  end

  defp required_nonempty_list(map, key, parser) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) and values != [] -> map_items(values, parser)
      _other -> {:error, :required_nonempty_list_invalid}
    end
  end

  defp optional_list(map, key, parser) do
    case Map.fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, values} when is_list(values) -> map_items(values, parser)
      _other -> {:error, :optional_list_invalid}
    end
  end

  defp map_items(values, parser) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, parsed} ->
      case parser.(value) do
        {:ok, item} -> {:cont, {:ok, [item | parsed]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _reason} = error -> error
    end
  end

  defp required_json(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> if(json_value?(value), do: {:ok, value}, else: {:error, :json_invalid})
      :error -> {:error, :required_json_missing}
    end
  end

  defp json_value?(value) when is_nil(value) or is_boolean(value) or is_binary(value), do: true
  defp json_value?(value) when is_integer(value) or is_float(value), do: true
  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  defp json_value?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end)
  end

  defp json_value?(_value), do: false

  defp optional_boolean_field(map, key) do
    case Map.fetch(map, key) do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      _other -> {:error, :optional_boolean_invalid}
    end
  end
end
