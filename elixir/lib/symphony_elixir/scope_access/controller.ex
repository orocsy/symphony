defmodule SymphonyElixir.ScopeAccess.Controller do
  @moduledoc false

  @policy_patch_dir ".orocsy/delivery/policy-patches"
  @supported_extensions ~w(.ts .tsx .js .jsx .mjs .cjs)

  @type decision ::
          {:allow_once, map()}
          | {:block, map()}
          | {:escalate, map()}

  @spec decide(map() | nil, map() | nil, String.t() | nil) :: decision()
  def decide(%{"operation" => operation, "paths" => paths} = request, policy, workspace)
      when operation in ["read", "search"] and is_list(paths) do
    cond do
      Map.get(request, "broad") == true ->
        {:block, correction(request, "broad_scope_drift", "The denied command asks for broad project discovery.")}

      paths == [] ->
        {:block, correction(request, "missing_exact_path", "The denied command did not name an exact workspace file.")}

      policy_patch_exists?(workspace, request) ->
        {:block, correction(request, "policy_patch_already_applied", "The same read-only policy patch has already been applied.")}

      true ->
        case safe_read_entries(request, policy, workspace) do
          {:ok, entries} ->
            {:allow_once, policy_patch(request, policy, entries)}

          {:error, reason_class} ->
            {:block, correction(request, reason_class, "The requested read is not proven by current scope inputs.")}
        end
    end
  end

  def decide(%{"operation" => "write"} = request, _policy, _workspace) do
    {:escalate, correction(request, "write_scope_expansion_requires_operator", "The denied command would broaden write scope.")}
  end

  def decide(%{} = request, _policy, _workspace) do
    {:block, correction(request, "unclassified_scope_request", "The denied command could not be safely auto-unblocked.")}
  end

  def decide(_request, _policy, _workspace) do
    {:block, correction(%{}, "missing_scope_request", "No parseable scope access request was available.")}
  end

  @spec write_policy_patch(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def write_policy_patch(workspace, %{"patch_id" => patch_id} = patch) when is_binary(workspace) and is_binary(patch_id) do
    dir = Path.join(workspace, @policy_patch_dir)
    relative_path = Path.join(@policy_patch_dir, "#{safe_patch_id(patch_id)}.json")
    path = Path.join(workspace, relative_path)
    File.mkdir_p!(dir)

    patch =
      patch
      |> Map.put("path", relative_path)
      |> Map.put_new("created_at", DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())

    File.write!(path, Jason.encode!(patch, pretty: true) <> "\n")
    {:ok, patch}
  rescue
    error -> {:error, {:policy_patch_write_failed, Exception.message(error)}}
  end

  def write_policy_patch(_workspace, _patch), do: {:error, :invalid_policy_patch}

  @spec policy_patch_dir() :: String.t()
  def policy_patch_dir, do: @policy_patch_dir

  defp safe_read_entries(%{"paths" => paths} = request, policy, workspace) do
    paths
    |> Enum.reduce_while([], fn path, acc ->
      case safe_read_entry(path, request, policy, workspace) do
        %{} = entry -> {:cont, [entry | acc]}
        nil -> {:halt, {:error, "not_safe_read_context"}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      entries -> {:ok, Enum.reverse(entries)}
    end
  end

  defp safe_read_entry(path, _request, policy, workspace) do
    cond do
      current_review_path?(path, policy) ->
        scope_entry(path, "scope_access.auto.current_review_path", "Current review feedback names this path.")

      conflict_path?(path, policy) ->
        scope_entry(path, "scope_access.auto.conflict_path", "Current mergeability/conflict scope names this path.")

      focused_test_path?(path, policy) ->
        scope_entry(path, "scope_access.auto.focused_test", "Focused validation already names this exact test path.")

      nearest_caller_context?(path, policy, workspace) ->
        scope_entry(path, "scope_access.auto.nearest_caller", "The requested file directly imports a write-scope file.")

      direct_import_context?(path, policy, workspace) ->
        scope_entry(path, "scope_access.auto.direct_import", "A write-scope file directly imports this path.")

      existing_read_context?(path, policy) ->
        scope_entry(path, "scope_access.auto.existing_policy", "Current policy already names this read context path.")

      true ->
        nil
    end
  end

  defp scope_entry(path, source, reason) do
    %{
      "path" => normalize_path(path),
      "source" => source,
      "operation" => "read",
      "expires" => "turn",
      "reason" => reason
    }
  end

  defp policy_patch(request, policy, entries) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    patch_id = patch_id(request)

    %{
      "schema_version" => 1,
      "patch_id" => patch_id,
      "status" => "active",
      "decision" => "allow_once",
      "decision_class" => "allow_once",
      "reason_class" => "safe_read_context",
      "source" => "symphony.runtime.scope-access-controller",
      "target" => "read_context",
      "operation" => "add",
      "entries" => entries,
      "request" => request,
      "policy_hash_before" => policy_hash(policy),
      "created_at" => now
    }
  end

  defp correction(request, reason_class, summary) do
    %{
      source: "symphony.runtime.scope-access",
      source_status: "blocked",
      summary: "Scope access blocked: #{reason_class}",
      findings: [
        summary,
        "Operation: #{request |> Map.get("operation", "unknown")}",
        "Path(s): #{request |> Map.get("paths", []) |> Enum.join(", ")}"
      ],
      required_corrections: [
        "Update the issue scope, add a safe read-context policy patch, or narrow the worker command to an exact in-scope path before redispatch."
      ],
      next_action: "block",
      guard: %{
        "scope_access" => request,
        "decision" => "block",
        "reason_class" => reason_class
      }
    }
  end

  defp current_review_path?(path, policy) do
    normalized = normalize_path(path)

    normalized in review_feedback_paths(policy) or
      normalized in scope_bundle_paths(policy, "write_scope", ["write", "write-if-conflicted"])
  end

  defp conflict_path?(path, policy) do
    normalize_path(path) in scope_bundle_paths(policy, "conflict_scope", ["write-if-conflicted", "read"])
  end

  defp focused_test_path?(path, policy) do
    normalized = normalize_path(path)
    normalized in validation_paths(policy) and test_path?(normalized)
  end

  defp existing_read_context?(path, policy) do
    normalize_path(path) in scope_bundle_paths(policy, "read_context", ["read", "search"])
  end

  defp direct_import_context?(path, policy, workspace) when is_binary(workspace) do
    normalized = normalize_path(path)

    policy
    |> write_scope_paths()
    |> Enum.any?(fn source_path ->
      normalized in direct_import_paths(workspace, source_path)
    end)
  end

  defp direct_import_context?(_path, _policy, _workspace), do: false

  defp nearest_caller_context?(path, policy, workspace) when is_binary(workspace) do
    normalized_write_paths = MapSet.new(write_scope_paths(policy))

    workspace
    |> direct_import_paths(path)
    |> Enum.any?(&MapSet.member?(normalized_write_paths, &1))
  end

  defp nearest_caller_context?(_path, _policy, _workspace), do: false

  defp write_scope_paths(policy) do
    (scope_bundle_paths(policy, "write_scope", ["write", "write-if-conflicted"]) ++
       requirement_paths(policy, "write_scope"))
    |> Enum.uniq()
  end

  defp validation_paths(policy) do
    requirements = requirements(policy)
    validation = Map.get(requirements, "validation", %{})

    [Map.get(validation, "files"), Map.get(validation, "commands")]
    |> Enum.flat_map(&string_values/1)
    |> Enum.flat_map(&paths_from_text/1)
    |> Enum.uniq()
  end

  defp review_feedback_paths(%{"review" => %{"feedback" => feedback}}) when is_list(feedback) do
    feedback
    |> Enum.flat_map(fn
      %{"path" => path} when is_binary(path) -> [normalize_path(path)]
      _ -> []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp review_feedback_paths(_policy), do: []

  defp requirement_paths(policy, key) do
    policy
    |> requirements()
    |> Map.get(key, [])
    |> string_values()
    |> Enum.flat_map(&paths_from_text/1)
    |> Enum.uniq()
  end

  defp scope_bundle_paths(policy, key, allowed_operations) do
    policy
    |> scope_bundle()
    |> Map.get(key, [])
    |> Enum.flat_map(fn
      %{"path" => path, "operation" => operation}
      when is_binary(path) and (is_binary(operation) or is_nil(operation)) ->
        if operation in allowed_operations or is_nil(operation), do: [normalize_path(path)], else: []

      %{"path" => path} when is_binary(path) ->
        [normalize_path(path)]

      _ ->
        []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp scope_bundle(%{"requirements" => %{"scope_bundle" => bundle}}) when is_map(bundle), do: bundle
  defp scope_bundle(%{"scope_bundle" => bundle}) when is_map(bundle), do: bundle
  defp scope_bundle(%{} = bundle), do: bundle
  defp scope_bundle(_policy), do: %{}

  defp requirements(%{"requirements" => requirements}) when is_map(requirements), do: requirements
  defp requirements(%{} = requirements), do: requirements
  defp requirements(_policy), do: %{}

  defp policy_hash(%{"policy_hash" => hash}) when is_binary(hash), do: hash
  defp policy_hash(%{"requirements" => %{"scope_bundle" => %{"policy_hash" => hash}}}) when is_binary(hash), do: hash
  defp policy_hash(%{"scope_bundle" => %{"policy_hash" => hash}}) when is_binary(hash), do: hash
  defp policy_hash(_policy), do: nil

  defp direct_import_paths(workspace, source_path) do
    path = Path.join(workspace, source_path)

    with true <- File.regular?(path),
         {:ok, content} <- File.read(path) do
      content
      |> import_specifiers()
      |> Enum.flat_map(&resolve_import_specifier(workspace, source_path, &1))
      |> Enum.uniq()
    else
      _ -> []
    end
  rescue
    _error -> []
  end

  defp import_specifiers(content) when is_binary(content) do
    ~r/(?:import|export)\s+(?:[^'"]+\s+from\s+)?['"]([^'"]+)['"]|require\(['"]([^'"]+)['"]\)/
    |> Regex.scan(content)
    |> Enum.flat_map(fn captures ->
      captures
      |> tl()
      |> Enum.reject(&(&1 == ""))
    end)
    |> Enum.uniq()
  end

  defp resolve_import_specifier(workspace, source_path, "." <> _ = specifier) do
    source_dir = Path.dirname(source_path)
    base = Path.expand(specifier, Path.join(workspace, source_dir))

    import_candidates(base)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, workspace))
    |> Enum.map(&normalize_path/1)
  end

  defp resolve_import_specifier(_workspace, _source_path, _specifier), do: []

  defp import_candidates(base) do
    [base] ++
      Enum.map(@supported_extensions, &(base <> &1)) ++
      Enum.map(@supported_extensions, &Path.join(base, "index#{&1}"))
  end

  defp policy_patch_exists?(workspace, request) when is_binary(workspace) do
    workspace
    |> policy_patch_path(patch_id(request))
    |> File.regular?()
  end

  defp policy_patch_exists?(_workspace, _request), do: false

  defp policy_patch_path(workspace, patch_id) do
    Path.join([workspace, @policy_patch_dir, "#{safe_patch_id(patch_id)}.json"])
  end

  defp patch_id(request) do
    paths = request |> Map.get("paths", []) |> Enum.map(&normalize_path/1) |> Enum.sort() |> Enum.join(",")
    fingerprint = request["command_fingerprint"] || hash("#{request["operation"]}:#{paths}")
    "scope_access_#{fingerprint}_#{hash(paths)}"
  end

  defp hash(value) do
    :sha256
    |> :crypto.hash(to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp safe_patch_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
  end

  defp paths_from_text(text) when is_binary(text) do
    ~r{`([^`]+)`|(?:^|[\s,;:"'(])((?:\./)?[A-Za-z0-9_.@+\-][A-Za-z0-9_\-./()\[\]@+]*\.(?:tsx|ts|jsx|js|mjs|cjs|ex|exs|md|json|yml|yaml|css|scss|html|svg|png))}
    |> Regex.scan(text)
    |> Enum.flat_map(fn captures ->
      captures
      |> tl()
      |> Enum.find(&(&1 != ""))
      |> case do
        path when is_binary(path) -> [normalize_path(path)]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp paths_from_text(_text), do: []

  defp string_values(values) when is_list(values), do: Enum.flat_map(values, &string_values/1)
  defp string_values(value) when is_binary(value), do: [value]
  defp string_values(_value), do: []

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.trim_leading("./")
    |> String.trim_trailing(".")
    |> String.trim_trailing(",")
  end

  defp normalize_path(_path), do: ""

  defp test_path?(path) when is_binary(path) do
    String.starts_with?(path, "tests/") or
      Regex.match?(~r/(^|\/)[^\/]+\.(test|spec)\.(ts|tsx|js|jsx|mjs|cjs)$/, path)
  end

  defp test_path?(_path), do: false
end
