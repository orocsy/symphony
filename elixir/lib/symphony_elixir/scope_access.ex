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
    case classify_command(command, policy_bundle) do
      %{} = request ->
        decision = decision_for(request)
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

        [
          base
          |> Map.merge(Map.drop(request, ["policy_patch"]))
          |> Map.put("event", "scope.access.requested")
          |> Map.put("status", "requested"),
          base
          |> Map.merge(request)
          |> Map.merge(decision)
          |> Map.put("event", "scope.access.decided")
          |> Map.put("status", decision["status"])
        ]

      _ ->
        []
    end
  end

  def events(_command, _pattern, _policy_bundle, _attrs), do: []

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
    |> strip_quoted_text()
    |> String.contains?(["&&", "||", ";", "|"])
  end

  defp command_chain_operator?(_command), do: false

  defp strip_quoted_text(command) do
    command
    |> String.replace(~r/"(?:\\.|[^"\\])*"/, ~s(""))
    |> String.replace(~r/'(?:\\.|[^'\\])*'/, "''")
  end

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
