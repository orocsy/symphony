defmodule SymphonyElixir.ScopeAccess do
  @moduledoc false

  @broad_roots ~w(. src app apps packages lib tests docs design)
  @root_config_paths ~w(
    AGENTS.md
    DESIGN.md
    README.md
    deno.json
    mix.exs
    mix.lock
    next.config.js
    next.config.mjs
    next.config.ts
    opennext.js
    open-next.config.js
    open-next.config.mjs
    open-next.config.ts
    package.json
    pnpm-lock.yaml
    tsconfig.json
    vitest.config.js
    vitest.config.mjs
    vitest.config.ts
    wrangler.json
    wrangler.jsonc
    wrangler.toml
  )

  @type access_request :: map()

  @spec classify_command(String.t() | nil) :: access_request() | nil
  def classify_command(command), do: classify_command(command, nil)

  @spec classify_command(String.t() | nil, map() | nil) :: access_request() | nil
  def classify_command(command, policy_bundle) when is_binary(command) do
    command
    |> normalize_command()
    |> command_request(policy_bundle)
  end

  def classify_command(_command, _policy_bundle), do: nil

  defp command_request("", _policy_bundle), do: nil

  defp command_request(command, policy_bundle) do
    [
      &bounded_read_chain_request/2,
      &shell_chain_request/2,
      &sed_read_request/2,
      &simple_read_request/2,
      &rg_search_request/2,
      &grep_search_request/2,
      &find_search_request/2,
      &ls_search_request/2,
      &git_diff_request/2,
      &git_discovery_request/2,
      &gh_api_request/2,
      &patch_request/2
    ]
    |> Enum.find_value(fn classifier -> classifier.(command, policy_bundle) end)
  end

  defp bounded_read_chain_request(command, policy_bundle) do
    with {:ok, segments} when length(segments) > 1 <- split_read_chain(command),
         requests when length(requests) == length(segments) <-
           Enum.map(segments, &bounded_read_segment_request(&1, policy_bundle)),
         true <- Enum.all?(requests, &bounded_exact_read_request?/1) do
      paths = requests |> Enum.flat_map(& &1["paths"]) |> Enum.uniq()
      request(command, "read", "bounded_read_chain", paths, false, policy_bundle)
    else
      _ -> nil
    end
  end

  defp bounded_read_segment_request(command, policy_bundle) do
    case exact_read_segment(command) do
      {:ok, operation, command_class, paths} ->
        request(command, operation, command_class, paths, broad_paths?(paths), policy_bundle)

      :error ->
        nil
    end
  end

  defp exact_read_segment(command) when is_binary(command) do
    case normalized_segment_argv(command) do
      ["sed", "-n", slice, path] ->
        if Regex.match?(~r/\A\d+(?:,\d+)?p\z/, slice),
          do: exact_segment_paths("read", "bounded_file_read", [path]),
          else: :error

      [tool | args] when tool in ["cat", "head", "tail", "nl"] ->
        case simple_read_segment_paths(tool, args) do
          [_ | _] = paths -> exact_segment_paths("read", "bounded_file_read", paths)
          _ -> :error
        end

      [tool | args] when tool in ["rg", "grep"] ->
        case search_segment_paths(tool, args) do
          [_ | _] = paths -> exact_segment_paths("search", "bounded_file_search", paths)
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _error -> :error
  end

  defp exact_read_segment(_command), do: :error

  defp normalized_segment_argv(command) when is_binary(command) do
    command
    |> OptionParser.split()
    |> normalize_segment_tokens()
  rescue
    _error -> :unclassified
  end

  defp normalized_segment_argv(_command), do: :unclassified

  defp normalize_segment_tokens([executable | args]) do
    case Path.basename(executable) do
      "env" -> args |> drop_optional_segment_delimiter() |> normalize_direct_segment()
      "command" -> args |> drop_optional_segment_delimiter() |> normalize_direct_segment()
      _ -> normalize_direct_segment([executable | args])
    end
  end

  defp normalize_segment_tokens(_tokens), do: :unclassified

  defp drop_optional_segment_delimiter(["--" | rest]), do: rest
  defp drop_optional_segment_delimiter(args), do: args

  defp normalize_direct_segment([executable | args]) do
    tool = Path.basename(executable)

    if tool in ["sed", "cat", "head", "tail", "nl", "rg", "grep"] and
         (executable == tool or Path.dirname(executable) in ["/bin", "/usr/bin"]),
       do: [tool | args],
       else: :unclassified
  end

  defp normalize_direct_segment(_args), do: :unclassified

  defp exact_segment_paths(operation, command_class, paths) do
    if Enum.all?(paths, &exact_relative_operand?/1) do
      {:ok, operation, command_class, paths}
    else
      :error
    end
  end

  defp simple_read_segment_paths("cat", args), do: optionless_segment_paths(args)
  defp simple_read_segment_paths("nl", args), do: optionless_segment_paths(args)

  defp simple_read_segment_paths(tool, args) when tool in ["head", "tail"] do
    parse_finite_segment_operands(args, [], false, tool)
  end

  defp simple_read_segment_paths(_tool, _args), do: :error

  defp parse_finite_segment_operands([], operands, _after_options?, _tool) do
    operands |> Enum.reverse() |> optionless_segment_paths()
  end

  defp parse_finite_segment_operands(["--" | rest], operands, false, tool),
    do: parse_finite_segment_operands(rest, operands, true, tool)

  defp parse_finite_segment_operands([option, count | rest], operands, false, tool)
       when option in ["-n", "--lines", "-c", "--bytes"] do
    if finite_count_token?(count),
      do: parse_finite_segment_operands(rest, operands, false, tool),
      else: :error
  end

  defp parse_finite_segment_operands([token | rest], operands, after_options?, tool)
       when is_binary(token) do
    cond do
      token == "-" -> :error
      after_options? -> parse_finite_segment_operands(rest, [token | operands], true, tool)
      finite_inline_count_option?(token) -> parse_finite_segment_operands(rest, operands, false, tool)
      finite_head_tail_flag?(tool, token) -> parse_finite_segment_operands(rest, operands, false, tool)
      String.starts_with?(token, "-") -> :error
      true -> parse_finite_segment_operands(rest, [token | operands], false, tool)
    end
  end

  defp parse_finite_segment_operands(_args, _operands, _after_options?, _tool), do: :error

  defp finite_count_token?(count) when is_binary(count),
    do: Regex.match?(~r/\A[+-]?\d+(?:b|[kKMGTPEZY](?:i?B)?)?\z/, count)

  defp finite_count_token?(_count), do: false

  defp finite_inline_count_option?(option) when is_binary(option) do
    Regex.match?(~r/\A-(?:n|c)?[+-]?\d+(?:b|[kKMGTPEZY](?:i?B)?)?\z/, option) or
      Regex.match?(~r/\A--(?:lines|bytes)=[+-]?\d+(?:b|[kKMGTPEZY](?:i?B)?)?\z/, option)
  end

  defp finite_inline_count_option?(_option), do: false

  defp finite_head_tail_flag?(tool, option) when tool in ["head", "tail"] and is_binary(option) do
    option in ["-q", "-v", "-z", "--quiet", "--silent", "--verbose", "--zero-terminated"] or
      Regex.match?(~r/\A-[qvz]+\z/, option)
  end

  defp finite_head_tail_flag?(_tool, _option), do: false

  defp optionless_segment_paths(args) when is_list(args) do
    if args != [] and Enum.all?(args, &(is_binary(&1) and not String.starts_with?(&1, "-"))),
      do: args,
      else: :error
  end

  defp optionless_segment_paths(_args), do: :error

  defp search_segment_paths(tool, args) when tool in ["rg", "grep"] and is_list(args) do
    case parse_search_segment_args(tool, args, false, []) do
      {:ok, true, paths} -> Enum.reverse(paths)
      {:ok, false, paths} -> paths |> Enum.reverse() |> Enum.drop(1)
      _ -> :error
    end
  end

  defp search_segment_paths(_tool, _args), do: :error

  defp parse_search_segment_args(_tool, [], pattern_from_option?, paths),
    do: {:ok, pattern_from_option?, paths}

  defp parse_search_segment_args(_tool, ["--" | rest], pattern_from_option?, paths),
    do: {:ok, pattern_from_option?, Enum.reverse(rest) ++ paths}

  defp parse_search_segment_args(tool, [option, pattern | rest], _pattern_from_option?, paths)
       when option in ["-e", "--regexp"] and is_binary(pattern),
       do: parse_search_segment_args(tool, rest, true, paths)

  defp parse_search_segment_args("rg", [option, encoding | rest], pattern_from_option?, paths)
       when option in ["-E", "--encoding"] and is_binary(encoding),
       do: parse_search_segment_args("rg", rest, pattern_from_option?, paths)

  defp parse_search_segment_args(tool, [option | rest], pattern_from_option?, paths)
       when is_binary(option) do
    cond do
      Regex.match?(~r/\A-e.+\z/, option) or String.starts_with?(option, "--regexp=") ->
        parse_search_segment_args(tool, rest, true, paths)

      tool == "rg" and
          (Regex.match?(~r/\A-E.+\z/, option) or String.starts_with?(option, "--encoding=")) ->
        parse_search_segment_args(tool, rest, pattern_from_option?, paths)

      safe_search_segment_flag?(tool, option) ->
        parse_search_segment_args(tool, rest, pattern_from_option?, paths)

      String.starts_with?(option, "-") ->
        :error

      true ->
        parse_search_segment_args(tool, rest, pattern_from_option?, [option | paths])
    end
  end

  defp parse_search_segment_args(_tool, _args, _pattern_from_option?, _paths), do: :error

  defp safe_search_segment_flag?(tool, option) when tool in ["rg", "grep"] do
    short_flags = if tool == "grep", do: ~r/\A-[nEHhIiJLlOoPqsvwxyz]+\z/, else: ~r/\A-[nHhIiJlOoPqsvwxyz]+\z/

    Regex.match?(short_flags, option) or
      option in [
        "--line-number",
        "--extended-regexp",
        "--fixed-strings",
        "--ignore-case",
        "--word-regexp",
        "--invert-match",
        "--count",
        "--files-with-matches",
        "--files-without-match",
        "--no-messages",
        "--text",
        "--binary",
        "--null",
        "--only-matching",
        "--quiet"
      ]
  end

  defp safe_search_segment_flag?(_tool, _option), do: false

  defp exact_relative_operand?(path) when is_binary(path) do
    path = normalize_path(path)

    path != "" and Path.type(path) != :absolute and
      not String.contains?(path, ["*", "?", "[", "]", "{", "}"])
  end

  defp exact_relative_operand?(_path), do: false

  defp bounded_exact_read_request?(%{"operation" => operation, "paths" => [_ | _], "broad" => false})
       when operation in ["read", "search"],
       do: true

  defp bounded_exact_read_request?(_request), do: false

  defp shell_chain_request(command, policy_bundle) do
    if command_chain_operator?(command) do
      request(command, "unknown", "shell_chain", paths_from_command(command), true, policy_bundle)
    end
  end

  defp sed_read_request(command, policy_bundle) do
    regex_paths_request(
      command,
      policy_bundle,
      ~r/(^|\s|["'])sed\s+-n(\s|$)/,
      "read",
      "bounded_file_read"
    )
  end

  defp simple_read_request(command, policy_bundle) do
    regex_paths_request(
      command,
      policy_bundle,
      ~r/(^|\s|["'])(cat|head|tail|nl)\s+/,
      "read",
      "bounded_file_read"
    )
  end

  defp rg_search_request(command, policy_bundle) do
    regex_paths_request(
      command,
      policy_bundle,
      ~r/(^|\s|["'])rg(\s|$)/,
      "search",
      "bounded_file_search",
      broad_when_empty?: true
    )
  end

  defp grep_search_request(command, policy_bundle) do
    regex_paths_request(
      command,
      policy_bundle,
      ~r/(^|\s|["'])grep(\s|$)/,
      "search",
      "bounded_file_search",
      broad_when_empty?: true
    )
  end

  defp find_search_request(command, policy_bundle) do
    regex_static_request(
      command,
      policy_bundle,
      ~r/(^|\s|["'])find(\s|$)/,
      "search",
      "directory_discovery"
    )
  end

  defp ls_search_request(command, policy_bundle) do
    regex_static_request(
      command,
      policy_bundle,
      ~r/(^|\s|["'])ls(\s|$)/,
      "search",
      "directory_listing"
    )
  end

  defp git_diff_request(command, policy_bundle) do
    regex_paths_request(
      command,
      policy_bundle,
      ~r/(^|\s|["'])git\s+diff(\s|$)/,
      "read",
      "git_diff",
      broad_when_empty?: true
    )
  end

  defp git_discovery_request(command, policy_bundle) do
    regex_static_request(
      command,
      policy_bundle,
      ~r/(^|\s|["'])git\s+(log|ls-files)(\s|$)/,
      "search",
      "git_discovery"
    )
  end

  defp gh_api_request(command, policy_bundle) do
    if Regex.match?(~r/(^|\s|["'])gh\s+api(\s|$)/, command) do
      request(command, "read", "github_api", [], true, policy_bundle)
    end
  end

  defp patch_request(command, policy_bundle) do
    if String.contains?(command, "apply_patch") do
      paths = patch_paths(command)
      request(command, "write", "patch", paths, paths == [] or broad_paths?(paths), policy_bundle)
    end
  end

  defp regex_paths_request(command, policy_bundle, regex, operation, command_class, opts \\ []) do
    if Regex.match?(regex, command) do
      paths = paths_from_command(command)
      broad? = Keyword.get(opts, :broad_when_empty?, false) and paths == []
      request(command, operation, command_class, paths, broad? or broad_paths?(paths), policy_bundle)
    end
  end

  defp regex_static_request(command, policy_bundle, regex, operation, command_class) do
    if Regex.match?(regex, command) do
      request(command, operation, command_class, paths_from_command(command), true, policy_bundle)
    end
  end

  @spec decision_for(access_request() | nil) :: map() | nil
  def decision_for(%{"operation" => "write"} = request) do
    base_decision(request, "escalate", "write_scope_expansion_requires_operator")
  end

  def decision_for(%{"broad" => true} = request) do
    base_decision(request, "block", "broad_scope_drift")
  end

  def decision_for(%{"operation" => operation} = request) when operation in ["read", "search"] do
    base_decision(request, "block", "read_context_controller_not_enabled")
  end

  def decision_for(%{} = request) do
    base_decision(request, "block", "unclassified_scope_request")
  end

  def decision_for(_request), do: nil

  @spec events(String.t(), String.t()) :: [map()]
  def events(command, pattern), do: events(command, pattern, nil, %{})

  @spec events(String.t(), String.t(), map() | nil) :: [map()]
  def events(command, pattern, policy_bundle), do: events(command, pattern, policy_bundle, %{})

  @spec events(String.t(), String.t(), map() | nil, map()) :: [map()]
  def events(command, pattern, policy_bundle, attrs) when is_binary(command) and is_binary(pattern) do
    scope_access_events(command, pattern, policy_bundle, attrs, nil)
  end

  def events(_command, _pattern, _policy_bundle, _attrs), do: []

  @spec events(String.t(), String.t(), map() | nil, map(), map() | nil) :: [map()]
  def events(command, pattern, policy_bundle, attrs, decision)
      when is_binary(command) and is_binary(pattern) do
    scope_access_events(command, pattern, policy_bundle, attrs, decision)
  end

  def events(_command, _pattern, _policy_bundle, _attrs, _decision), do: []

  defp scope_access_events(command, pattern, policy_bundle, attrs, decision) do
    case classify_command(command, policy_bundle) do
      %{} = request ->
        request_id = request_id(command, pattern, request)
        ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        base =
          attrs
          |> stringify_keys()
          |> Map.merge(%{
            "schema_version" => 1,
            "ts" => ts,
            "tool" => "command-guard",
            "source" => "symphony.runtime.command-guard",
            "request_id" => request_id,
            "command" => command,
            "pattern" => pattern
          })

        requested =
          base
          |> Map.merge(Map.drop(request, ["policy_patch"]))
          |> Map.put("event", "scope.access.requested")
          |> Map.put("status", "requested")

        case normalize_decision(decision) do
          %{} = actual_decision ->
            decided =
              base
              |> Map.merge(request)
              |> Map.merge(actual_decision)
              |> Map.put("event", "scope.access.decided")
              |> Map.put(
                "status",
                decision_status(actual_decision["decision"]) || actual_decision["status"]
              )

            [requested, decided]

          nil ->
            [requested]
        end

      _ ->
        []
    end
  end

  defp normalize_decision(%{} = decision) do
    decision
    |> stringify_keys()
    |> case do
      %{"guard" => %{} = guard} = attrs -> Map.merge(attrs, stringify_keys(guard))
      attrs -> attrs
    end
  end

  defp normalize_decision(_decision), do: nil

  defp request(command, operation, command_class, paths, broad?, policy_bundle) do
    %{
      "operation" => operation,
      "paths" => normalize_paths(paths),
      "command_class" => command_class,
      "broad" => broad?,
      "policy_hash" => policy_hash(policy_bundle),
      "policy_patch" => policy_patch(operation, normalize_paths(paths), broad?)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.put("command_fingerprint", command_fingerprint(command))
  end

  defp base_decision(request, decision, reason_class) do
    %{
      "decision" => decision,
      "decision_class" => decision,
      "reason_class" => reason_class,
      "status" => decision_status(decision),
      "requires_policy_patch" => not is_nil(request["policy_patch"])
    }
  end

  defp decision_status("allow_once"), do: "allowed"
  defp decision_status("block"), do: "blocked"
  defp decision_status("escalate"), do: "blocked"
  defp decision_status(decision) when is_binary(decision), do: decision
  defp decision_status(_decision), do: "blocked"

  defp policy_patch(_operation, _paths, true), do: nil
  defp policy_patch(_operation, [], _broad?), do: nil

  defp policy_patch("write", paths, _broad?) do
    %{"op" => "add", "target" => "write_scope", "paths" => paths, "expires" => "operator_review"}
  end

  defp policy_patch(operation, paths, _broad?) when operation in ["read", "search"] do
    %{"op" => "add", "target" => "read_context", "paths" => paths, "expires" => "turn"}
  end

  defp policy_patch(_operation, _paths, _broad?), do: nil

  defp paths_from_command(command) when is_binary(command) do
    command
    |> String.replace(~r/\\(["'])/, "\\1")
    |> then(fn text ->
      Regex.scan(
        ~r/(?:^|[\s"'`])(\.?\/?(?:(?:src|app|apps|packages|lib|tests|docs|design)(?:\/[A-Za-z0-9_\-.()\[\]@+]+)*|(?:AGENTS\.md|DESIGN\.md|README\.md|deno\.json|mix\.exs|mix\.lock|next\.config\.(?:ts|js|mjs)|opennext\.js|open-next\.config\.(?:ts|js|mjs)|package\.json|pnpm-lock\.yaml|tsconfig\.json|vitest\.config\.[A-Za-z0-9]+|wrangler\.(?:toml|json|jsonc))))(?=$|[\s"'`])/,
        text,
        capture: :all_but_first
      )
    end)
    |> Enum.flat_map(fn
      [path] when is_binary(path) -> [normalize_path(path)]
      _ -> []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp paths_from_command(_command), do: []

  defp patch_paths(command) when is_binary(command) do
    ~r/\*\*\* (?:Add|Update|Delete) File: ([^\n\r]+)/
    |> Regex.scan(command, capture: :all_but_first)
    |> Enum.flat_map(fn
      [path] when is_binary(path) -> [normalize_path(path)]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp broad_paths?([]), do: true

  defp broad_paths?(paths) when is_list(paths) do
    Enum.any?(paths, fn path ->
      normalized = normalize_path(path)
      root = normalized |> String.split("/", parts: 2) |> List.first()

      normalized in @broad_roots or
        String.ends_with?(normalized, "/") or
        (Path.extname(normalized) == "" and normalized not in @root_config_paths and root in @broad_roots)
    end)
  end

  defp broad_paths?(_paths), do: true

  defp command_chain_operator?(command) when is_binary(command) do
    command
    |> unwrap_shell_payload()
    |> strip_quoted_text()
    |> String.contains?(["&&", "||", ";", "|"])
  end

  defp command_chain_operator?(_command), do: false

  defp strip_quoted_text(command) do
    command
    |> String.replace(~r/"(?:\\.|[^"\\])*"/, ~s(""))
    |> String.replace(~r/'(?:\\.|[^'\\])*'/, "''")
  end

  defp split_read_chain(command) when is_binary(command) do
    command
    |> unwrap_shell_payload()
    |> String.graphemes()
    |> split_read_chain_chars(nil, false, [], [], false)
  end

  defp split_read_chain(_command), do: :error

  defp split_read_chain_chars([], nil, false, current, parts, true) do
    case chain_segment(current) do
      "" -> :error
      segment -> {:ok, Enum.reverse([segment | parts])}
    end
  end

  defp split_read_chain_chars([], _quote, _escaped?, _current, _parts, _found?), do: :error

  defp split_read_chain_chars([char | rest], quote, true, current, parts, found?) do
    split_read_chain_chars(rest, quote, false, [char, "\\" | current], parts, found?)
  end

  defp split_read_chain_chars(["\\" | rest], quote, false, current, parts, found?)
       when quote in ["'", "\""] do
    split_read_chain_chars(rest, quote, true, current, parts, found?)
  end

  defp split_read_chain_chars([char | rest], nil, false, current, parts, found?)
       when char in ["'", "\""] do
    split_read_chain_chars(rest, char, false, [char | current], parts, found?)
  end

  defp split_read_chain_chars([char | rest], char, false, current, parts, found?) do
    split_read_chain_chars(rest, nil, false, [char | current], parts, found?)
  end

  defp split_read_chain_chars(["&", "&" | rest], nil, false, current, parts, _found?) do
    case chain_segment(current) do
      "" -> :error
      segment -> split_read_chain_chars(rest, nil, false, [], [segment | parts], true)
    end
  end

  defp split_read_chain_chars([char | _rest], nil, false, _current, _parts, _found?)
       when char in ["&", "|", ";", "<", ">", "`"],
       do: :error

  defp split_read_chain_chars(["$", "(" | _rest], nil, false, _current, _parts, _found?),
    do: :error

  defp split_read_chain_chars([char | rest], quote, false, current, parts, found?) do
    split_read_chain_chars(rest, quote, false, [char | current], parts, found?)
  end

  defp chain_segment(chars), do: chars |> Enum.reverse() |> Enum.join() |> String.trim()

  defp unwrap_shell_payload(command) when is_binary(command) do
    case Regex.run(~r/\A(?:\/bin\/)?(?:zsh|bash|sh)\s+-(?:l)?c\s+(.+)\z/, String.trim(command), capture: :all_but_first) do
      [payload] -> unquote_shell_payload(String.trim(payload))
      _ -> command
    end
  end

  defp unwrap_shell_payload(command), do: command

  defp unquote_shell_payload(<<quote::binary-size(1), rest::binary>>) when quote in ["'", "\""] do
    if String.ends_with?(rest, quote) do
      rest
      |> binary_part(0, byte_size(rest) - 1)
      |> String.replace("\\#{quote}", quote)
    else
      quote <> rest
    end
  end

  defp unquote_shell_payload(payload), do: payload

  defp normalize_paths(paths) when is_list(paths) do
    paths
    |> Enum.map(&normalize_path/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_paths(_paths), do: []

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.trim_leading("./")
    |> String.trim_trailing(".")
    |> String.trim_trailing(",")
  end

  defp normalize_path(_path), do: ""

  defp normalize_command(command) when is_binary(command) do
    command
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp policy_hash(%{"policy_hash" => hash}) when is_binary(hash), do: hash
  defp policy_hash(%{policy_hash: hash}) when is_binary(hash), do: hash
  defp policy_hash(%{"requirements" => %{"scope_bundle" => %{"policy_hash" => hash}}}) when is_binary(hash), do: hash
  defp policy_hash(%{"scope_bundle" => %{"policy_hash" => hash}}) when is_binary(hash), do: hash
  defp policy_hash(%{scope_bundle: %{policy_hash: hash}}) when is_binary(hash), do: hash
  defp policy_hash(_policy_bundle), do: nil

  defp request_id(command, pattern, request) do
    :sha256
    |> :crypto.hash("#{command}\n#{pattern}\n#{inspect(request, limit: :infinity)}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp command_fingerprint(command) do
    :sha256
    |> :crypto.hash(command)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_keys(_map), do: %{}
end
