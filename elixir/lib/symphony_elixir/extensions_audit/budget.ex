defmodule SymphonyElixir.ExtensionsAudit.BudgetManifest do
  @moduledoc false

  @type file_entry :: %{
          path: String.t(),
          max_changed_lines: pos_integer(),
          required: boolean(),
          expected_patch_sha256: String.t(),
          hooks: [map()]
        }

  @type t :: %__MODULE__{
          schema_version: 1,
          baseline_commit: String.t(),
          kernel_root: String.t(),
          prototype_checkpoint: String.t(),
          prototype_total_patch_sha256: String.t(),
          total_max_changed_lines: pos_integer(),
          files: [file_entry()]
        }

  defstruct [
    :schema_version,
    :baseline_commit,
    :kernel_root,
    :prototype_checkpoint,
    :prototype_total_patch_sha256,
    :total_max_changed_lines,
    files: []
  ]
end

defmodule SymphonyElixir.ExtensionsAudit.BudgetReport do
  @moduledoc false

  alias SymphonyElixir.ExtensionsAudit.Finding

  @type t :: %__MODULE__{
          check: :budget,
          baseline_commit: String.t(),
          head: String.t(),
          changed_kernel_files: [String.t()],
          changed_lines: non_neg_integer(),
          maximum_changed_lines: pos_integer(),
          findings: [Finding.t()]
        }

  defstruct [
    :check,
    :baseline_commit,
    :head,
    :changed_kernel_files,
    :changed_lines,
    :maximum_changed_lines,
    findings: []
  ]
end

defmodule SymphonyElixir.ExtensionsAudit.Budget do
  @moduledoc false

  alias SymphonyElixir.ExtensionsAudit.{BudgetManifest, BudgetReport, Finding, Git}
  alias SymphonyElixir.PathSafety

  @manifest_file "UPSTREAM_PATCH_BUDGET.yml"
  @baseline_file "UPSTREAM_BASE.yml"
  @top_keys ~w(schema_version baseline_commit kernel_root prototype_checkpoint prototype_total_patch_sha256 total_max_changed_lines files)
  @file_keys ~w(path max_changed_lines required expected_patch_sha256 hooks)
  @hook_keys ~w(id max_changed_lines prototype_patch_sha256)
  @sha1_pattern ~r/^[0-9a-f]{40}$/
  @sha256_pattern ~r/^[0-9a-f]{64}$/
  @finding_order [
    :kernel_path_unregistered,
    :kernel_file_deleted,
    :kernel_patch_binary,
    :kernel_patch_fingerprint_mismatch,
    :kernel_file_budget_exceeded,
    :kernel_direct_orocsy_dependency,
    :kernel_required_hook_missing,
    :kernel_total_budget_exceeded
  ]

  @spec verify(Path.t(), keyword()) :: {:ok, BudgetReport.t()} | {:error, [Finding.t()]}
  def verify(repo_root, opts \\ []) do
    git = Keyword.get(opts, :git, &System.cmd/3)

    with {:ok, source} <- read_file(Path.join(repo_root, @manifest_file), @manifest_file),
         {:ok, decoded} <- decode_manifest(source),
         {:ok, manifest} <- validate_manifest(decoded),
         {:ok, baseline_commit} <- read_baseline_commit(repo_root),
         :ok <- compare_baselines(manifest, baseline_commit),
         {:ok, evidence} <- collect_evidence(repo_root, manifest, git) do
      evaluate_evidence(repo_root, manifest, evidence, git)
    else
      {:error, findings} when is_list(findings) -> {:error, findings}
    end
  end

  defp read_file(path, field) do
    case File.read(path) do
      {:ok, source} ->
        {:ok, source}

      {:error, :enoent} ->
        {:error, [%Finding{code: :budget_manifest_missing, field: field}]}

      {:error, reason} ->
        {:error,
         [
           %Finding{
             code: :budget_manifest_unreadable,
             field: field,
             detail: "manifest could not be read: #{:file.format_error(reason)}"
           }
         ]}
    end
  end

  defp decode_manifest(source) do
    case YamlElixir.read_all_from_string(source, maps_as_keywords: true) do
      {:ok, [document]} ->
        case decode_node(document, []) do
          {:ok, %{} = mapping} -> {:ok, mapping}
          {:ok, _other} -> invalid_yaml("expected a mapping")
          {:error, detail} -> invalid_yaml(detail)
        end

      {:ok, _documents} ->
        invalid_yaml("expected exactly one YAML document")

      {:error, _reason} ->
        invalid_yaml("manifest could not be decoded")
    end
  end

  defp decode_node([], _path), do: {:ok, []}

  defp decode_node(pairs, path) when is_list(pairs) do
    if Enum.all?(pairs, &match?({_key, _value}, &1)) do
      decode_mapping(pairs, path)
    else
      decode_sequence(pairs, path)
    end
  end

  defp decode_node(value, _path), do: {:ok, value}

  defp decode_sequence(values, path) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case decode_node(value, path ++ [index]) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, detail} -> {:halt, {:error, detail}}
      end
    end)
    |> reverse_decoded()
  end

  defp reverse_decoded({:ok, decoded}), do: {:ok, Enum.reverse(decoded)}
  defp reverse_decoded(error), do: error

  defp decode_mapping(pairs, path) do
    case duplicate_mapping_key(pairs) do
      nil -> decode_mapping_pairs(pairs, path)
      duplicate -> {:error, "duplicate key: #{format_path(path ++ [key_name(duplicate)])}"}
    end
  end

  defp duplicate_mapping_key(pairs) do
    pairs
    |> Enum.group_by(fn {key, _value} -> key end)
    |> Enum.filter(fn {_key, entries} -> length(entries) > 1 end)
    |> Enum.map(fn {key, _entries} -> key end)
    |> Enum.sort_by(&key_name/1)
    |> List.first()
  end

  defp decode_mapping_pairs(pairs, path) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      decode_mapping_pair(key_name(key), value, path, acc)
    end)
  end

  defp decode_mapping_pair(key, value, path, acc) do
    case decode_node(value, path ++ [key]) do
      {:ok, decoded} -> {:cont, {:ok, Map.put(acc, key, decoded)}}
      {:error, detail} -> {:halt, {:error, detail}}
    end
  end

  defp invalid_yaml(detail) do
    {:error, [%Finding{code: :budget_manifest_invalid_yaml, field: @manifest_file, detail: detail}]}
  end

  defp validate_manifest(%{} = manifest) do
    with :ok <- validate_schema(manifest),
         :ok <- validate_unknown_keys(manifest),
         :ok <- validate_top_fields(manifest),
         :ok <- validate_file_entries(manifest["files"], manifest["kernel_root"], manifest["total_max_changed_lines"]) do
      {:ok,
       %BudgetManifest{
         schema_version: 1,
         baseline_commit: manifest["baseline_commit"],
         kernel_root: manifest["kernel_root"],
         prototype_checkpoint: manifest["prototype_checkpoint"],
         prototype_total_patch_sha256: manifest["prototype_total_patch_sha256"],
         total_max_changed_lines: manifest["total_max_changed_lines"],
         files: Enum.map(manifest["files"], &normalize_file/1)
       }}
    else
      findings when is_list(findings) -> {:error, findings}
    end
  end

  defp validate_schema(%{"schema_version" => 1}), do: :ok

  defp validate_schema(%{"schema_version" => value}) do
    [%Finding{code: :budget_manifest_schema_unsupported, field: "schema_version", expected: 1, actual: value}]
  end

  defp validate_schema(manifest), do: field_invalid("schema_version", 1, manifest["schema_version"])

  defp validate_unknown_keys(manifest) do
    findings =
      unknown_key_findings(manifest, @top_keys, "") ++
        nested_unknown_key_findings(manifest["files"])

    if findings == [], do: :ok, else: findings
  end

  defp nested_unknown_key_findings(files) when is_list(files) do
    files
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{} = file, index} ->
        unknown_key_findings(file, @file_keys, "files[#{index}].") ++
          hook_unknown_key_findings(file["hooks"], index)

      {_other, _index} ->
        []
    end)
  end

  defp nested_unknown_key_findings(_files), do: []

  defp hook_unknown_key_findings(hooks, file_index) when is_list(hooks) do
    hooks
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{} = hook, hook_index} ->
        unknown_key_findings(hook, @hook_keys, "files[#{file_index}].hooks[#{hook_index}].")

      {_other, _hook_index} ->
        []
    end)
  end

  defp hook_unknown_key_findings(_hooks, _file_index), do: []

  defp unknown_key_findings(map, allowed, prefix) do
    map
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.sort()
    |> Enum.map(&%Finding{code: :budget_manifest_unknown_key, field: prefix <> &1})
  end

  defp validate_top_fields(manifest) do
    validators = [
      {"baseline_commit", &sha1?/1, "full lowercase 40-character object ID"},
      {"kernel_root", &normalized_path?/1, "normalized repository-relative path"},
      {"prototype_checkpoint", &sha1?/1, "full lowercase 40-character object ID"},
      {"prototype_total_patch_sha256", &sha256?/1, "full lowercase SHA-256"},
      {"total_max_changed_lines", &positive_integer?/1, "positive integer"},
      {"files", &(is_list(&1) and &1 != []), "non-empty list"}
    ]

    case Enum.find(validators, fn {field, valid?, _expected} -> not valid?.(manifest[field]) end) do
      nil -> :ok
      {field, _valid?, expected} -> field_invalid(field, expected, manifest[field])
    end
  end

  defp validate_file_entries(files, kernel_root, total_max)
       when is_list(files) and is_binary(kernel_root) and is_integer(total_max) do
    findings =
      files
      |> Enum.with_index()
      |> Enum.flat_map(fn {file, index} -> validate_file_entry(file, index, kernel_root, total_max) end)

    duplicate_paths = duplicate_values(files, "path")

    duplicate_hooks =
      files
      |> Enum.flat_map(fn
        %{"hooks" => hooks} when is_list(hooks) -> hooks
        _ -> []
      end)
      |> duplicate_values("id")

    findings =
      findings ++
        Enum.map(duplicate_paths, &manifest_field_finding("files.path", "unique paths", &1)) ++
        Enum.map(duplicate_hooks, &manifest_field_finding("files.hooks.id", "globally unique hook IDs", &1))

    if findings == [], do: :ok, else: findings
  end

  defp validate_file_entry(%{} = file, index, kernel_root, _total_max) do
    prefix = "files[#{index}]"

    validators = [
      {"path", &(normalized_path?(&1) and descendant_path?(&1, kernel_root)), "normalized path below kernel_root"},
      {"max_changed_lines", &positive_integer?/1, "positive integer"},
      {"required", &(&1 in [true, false]), "boolean"},
      {"expected_patch_sha256", &sha256?/1, "full lowercase SHA-256"},
      {"hooks", &(is_list(&1) and &1 != []), "non-empty list"}
    ]

    field_findings =
      validators
      |> Enum.filter(fn {field, valid?, _expected} -> not valid?.(file[field]) end)
      |> Enum.map(fn {field, _valid?, expected} ->
        manifest_field_finding("#{prefix}.#{field}", expected, file[field])
      end)

    field_findings ++ validate_hooks(file["hooks"], prefix, file["max_changed_lines"])
  end

  defp validate_file_entry(other, index, _kernel_root, _total_max),
    do: [manifest_field_finding("files[#{index}]", "mapping", other)]

  defp validate_hooks(hooks, prefix, file_max) when is_list(hooks) do
    hooks
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{} = hook, index} ->
        hook_prefix = "#{prefix}.hooks[#{index}]"

        [
          {"id", &valid_hook_id?/1, "non-empty technical hook ID"},
          {"max_changed_lines", &(positive_integer?(&1) and is_integer(file_max) and &1 <= file_max), "positive integer no greater than file budget"},
          {"prototype_patch_sha256", &sha256?/1, "full lowercase SHA-256"}
        ]
        |> Enum.filter(fn {field, valid?, _expected} -> not valid?.(hook[field]) end)
        |> Enum.map(fn {field, _valid?, expected} ->
          manifest_field_finding("#{hook_prefix}.#{field}", expected, hook[field])
        end)

      {other, index} ->
        [manifest_field_finding("#{prefix}.hooks[#{index}]", "mapping", other)]
    end)
  end

  defp validate_hooks(other, prefix, _file_max),
    do: [manifest_field_finding("#{prefix}.hooks", "non-empty list", other)]

  defp normalize_file(file) do
    %{
      path: file["path"],
      max_changed_lines: file["max_changed_lines"],
      required: file["required"],
      expected_patch_sha256: file["expected_patch_sha256"],
      hooks:
        Enum.map(file["hooks"], fn hook ->
          %{
            id: hook["id"],
            max_changed_lines: hook["max_changed_lines"],
            prototype_patch_sha256: hook["prototype_patch_sha256"]
          }
        end)
    }
  end

  defp read_baseline_commit(repo_root) do
    path = Path.join(repo_root, @baseline_file)

    with {:ok, source} <- File.read(path),
         {:ok, [pairs]} <- YamlElixir.read_all_from_string(source, maps_as_keywords: true),
         true <- is_list(pairs),
         commits <- for({"commit", value} <- pairs, do: value),
         [commit] when is_binary(commit) <- commits do
      {:ok, commit}
    else
      _ ->
        {:error,
         [
           %Finding{
             code: :budget_baseline_mismatch,
             field: "baseline_commit",
             detail: "UPSTREAM_BASE.yml has no unique valid commit"
           }
         ]}
    end
  end

  defp compare_baselines(%BudgetManifest{baseline_commit: commit}, commit), do: :ok

  defp compare_baselines(%BudgetManifest{baseline_commit: actual}, expected) do
    {:error,
     [
       %Finding{
         code: :budget_baseline_mismatch,
         field: "baseline_commit",
         expected: expected,
         actual: actual
       }
     ]}
  end

  defp collect_evidence(repo_root, manifest, git) do
    with {:ok, root} <- git_success(git, repo_root, ["rev-parse", "--show-toplevel"], "proving worktree"),
         true <- same_path?(String.trim(root), repo_root),
         {:ok, object_type} <-
           git_success(git, repo_root, ["cat-file", "-t", manifest.baseline_commit], "resolving baseline object"),
         true <- String.trim(object_type) == "commit",
         {:ok, head_output} <- git_success(git, repo_root, ["rev-parse", "HEAD"], "resolving HEAD"),
         head when is_binary(head) <- String.trim(head_output),
         true <- sha1?(head),
         {:ok, tree_output} <-
           git_success(
             git,
             repo_root,
             ["ls-tree", "-r", "--name-only", manifest.baseline_commit, "--", manifest.kernel_root],
             "listing pinned kernel"
           ),
         {:ok, kernel_paths} <- parse_lines(tree_output, "listing pinned kernel"),
         {:ok, status_output} <-
           git_success(
             git,
             repo_root,
             diff_args(["--name-status"], manifest.baseline_commit, manifest.kernel_root),
             "listing kernel divergence"
           ),
         {:ok, worktree_changes} <- parse_name_status(status_output),
         {:ok, index_status_output} <-
           git_success(
             git,
             repo_root,
             diff_args(["--cached", "--name-status"], manifest.baseline_commit, manifest.kernel_root),
             "listing staged kernel divergence"
           ),
         {:ok, index_changes} <- parse_name_status(index_status_output) do
      {:ok,
       %{
         head: head,
         kernel_paths: MapSet.new(kernel_paths),
         changes: tag_changes(worktree_changes, :worktree) ++ tag_changes(index_changes, :index)
       }}
    else
      false -> budget_git_error("Git evidence did not match the requested repository or object type")
      {:error, findings} when is_list(findings) -> {:error, findings}
    end
  end

  defp evaluate_evidence(repo_root, manifest, evidence, git) do
    registered = Map.new(manifest.files, &{&1.path, &1})

    manifest_path_findings =
      manifest.files
      |> Enum.reject(&MapSet.member?(evidence.kernel_paths, &1.path))
      |> Enum.map(&manifest_field_finding(&1.path, "path present in pinned kernel tree", &1.path))

    pinned_changes = Enum.filter(evidence.changes, &MapSet.member?(evidence.kernel_paths, &1.path))

    {file_results, operational_findings} = inspect_changes(pinned_changes, registered, repo_root, manifest, git)

    if operational_findings != [] do
      {:error, sort_findings(operational_findings)}
    else
      build_budget_result(manifest, evidence, pinned_changes, Enum.reverse(file_results), manifest_path_findings)
    end
  end

  defp inspect_changes(changes, registered, repo_root, manifest, git) do
    changes
    |> Enum.sort_by(& &1.path)
    |> Enum.reduce({[], []}, fn change, acc ->
      inspect_change(change, registered[change.path], repo_root, manifest, git, acc)
    end)
  end

  defp inspect_change(change, nil, _repo_root, _manifest, _git, {results, errors}) do
    result = %{path: change.path, changed_lines: 0, findings: [%Finding{code: :kernel_path_unregistered, field: change.path}]}
    {[result | results], errors}
  end

  defp inspect_change(change, file, repo_root, manifest, git, {results, errors}) do
    case inspect_registered_change(repo_root, manifest, file, change, git) do
      {:ok, result} -> {[result | results], errors}
      {:error, findings} -> {results, findings ++ errors}
    end
  end

  defp build_budget_result(manifest, evidence, pinned_changes, file_results, manifest_path_findings) do
    file_results = merge_file_results(file_results)
    changed_paths = MapSet.new(Enum.map(pinned_changes, & &1.path))
    required_findings = required_findings(manifest.files, changed_paths)
    changed_lines = Enum.sum(Enum.map(file_results, & &1.changed_lines))
    total_findings = total_findings(changed_lines, manifest.total_max_changed_lines)

    findings =
      manifest_path_findings ++
        Enum.flat_map(file_results, & &1.findings) ++ required_findings ++ total_findings

    budget_result(findings, manifest, evidence, file_results, changed_lines)
  end

  defp required_findings(files, changed_paths) do
    files
    |> Enum.filter(&(&1.required and not MapSet.member?(changed_paths, &1.path)))
    |> Enum.map(&%Finding{code: :kernel_required_hook_missing, field: &1.path})
  end

  defp total_findings(changed_lines, maximum) when changed_lines > maximum do
    [%Finding{code: :kernel_total_budget_exceeded, field: "total_max_changed_lines", expected: maximum, actual: changed_lines}]
  end

  defp total_findings(_changed_lines, _maximum), do: []

  defp merge_file_results(file_results) do
    file_results
    |> Enum.group_by(& &1.path)
    |> Enum.map(fn {path, results} ->
      %{
        path: path,
        changed_lines: results |> Enum.map(& &1.changed_lines) |> Enum.max(),
        findings: results |> Enum.flat_map(& &1.findings) |> Enum.uniq()
      }
    end)
    |> Enum.sort_by(& &1.path)
  end

  defp budget_result([], manifest, evidence, file_results, changed_lines) do
    {:ok,
     %BudgetReport{
       check: :budget,
       baseline_commit: manifest.baseline_commit,
       head: evidence.head,
       changed_kernel_files: file_results |> Enum.map(& &1.path) |> Enum.sort(),
       changed_lines: changed_lines,
       maximum_changed_lines: manifest.total_max_changed_lines,
       findings: []
     }}
  end

  defp budget_result(findings, _manifest, _evidence, _file_results, _changed_lines) do
    {:error, sort_findings(findings)}
  end

  defp inspect_registered_change(_repo_root, _manifest, _file, %{status: "D", path: path}, _git) do
    {:ok, %{path: path, changed_lines: 0, findings: [%Finding{code: :kernel_file_deleted, field: path}]}}
  end

  defp inspect_registered_change(repo_root, manifest, file, change, git) do
    with {:ok, numstat} <-
           git_success(
             git,
             repo_root,
             diff_args(change_mode_args(change, ["--numstat"]), manifest.baseline_commit, file.path),
             "measuring registered kernel patch"
           ),
         {:ok, changed_lines} <- parse_numstat(numstat, file.path),
         {:ok, patch} <-
           git_success(
             git,
             repo_root,
             diff_args(
               change_mode_args(change, ["--full-index", "--unified=3"]),
               manifest.baseline_commit,
               file.path
             ),
             "fingerprinting registered kernel patch"
           ) do
      fingerprint = sha256(patch)

      findings =
        []
        |> maybe_add(
          fingerprint != file.expected_patch_sha256,
          %Finding{
            code: :kernel_patch_fingerprint_mismatch,
            field: file.path,
            expected: file.expected_patch_sha256,
            actual: fingerprint
          }
        )
        |> maybe_add(
          changed_lines > file.max_changed_lines,
          %Finding{
            code: :kernel_file_budget_exceeded,
            field: file.path,
            expected: file.max_changed_lines,
            actual: changed_lines
          }
        )
        |> maybe_add(
          direct_orocsy_dependency?(patch),
          %Finding{code: :kernel_direct_orocsy_dependency, field: file.path}
        )

      {:ok, %{path: change.path, changed_lines: changed_lines, findings: findings}}
    end
  end

  defp git_success(git, repo_root, args, operation) do
    case Git.run(git, repo_root, args) do
      {:ok, output, 0} -> {:ok, output}
      {:ok, _output, status} -> budget_git_error("git command failed while #{operation} (status #{status})")
      {:error, detail} -> budget_git_error(detail)
    end
  end

  defp diff_args(mode_args, baseline, path) do
    ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--no-color"] ++
      mode_args ++ [baseline, "--", path]
  end

  defp change_mode_args(%{source: :index}, args), do: ["--cached" | args]
  defp change_mode_args(_change, args), do: args

  defp tag_changes(changes, source), do: Enum.map(changes, &Map.put(&1, :source, source))

  defp parse_lines(output, _operation) do
    {:ok, String.split(output, ~r/\R/, trim: true)}
  end

  defp parse_name_status(output) do
    output
    |> String.split(~r/\R/, trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case String.split(line, "\t", parts: 2) do
        [status, path] when status in ["A", "D", "M", "T"] and path != "" ->
          {:cont, {:ok, [%{status: status, path: path} | acc]}}

        _ ->
          {:halt, budget_git_error("Git name-status evidence was malformed")}
      end
    end)
    |> case do
      {:ok, changes} ->
        paths = Enum.map(changes, & &1.path)

        if length(paths) == MapSet.size(MapSet.new(paths)) do
          {:ok, Enum.reverse(changes)}
        else
          budget_git_error("Git name-status evidence contained duplicate paths")
        end

      error ->
        error
    end
  end

  defp parse_numstat(output, expected_path) do
    case String.split(output, ~r/\R/, trim: true) do
      [line] ->
        parse_numstat_row(String.split(line, "\t", parts: 3), expected_path)

      _ ->
        budget_git_error("Git numstat evidence contained an unexpected row count")
    end
  end

  defp parse_numstat_row(["-", "-", expected_path], expected_path) do
    {:error, [%Finding{code: :kernel_patch_binary, field: expected_path}]}
  end

  defp parse_numstat_row([added, deleted, expected_path], expected_path) do
    parse_numstat_counts(added, deleted)
  end

  defp parse_numstat_row(_row, _expected_path) do
    budget_git_error("Git numstat evidence did not match the registered path")
  end

  defp parse_numstat_counts(added, deleted) do
    with {added, ""} <- Integer.parse(added),
         {deleted, ""} <- Integer.parse(deleted),
         true <- added >= 0 and deleted >= 0 do
      {:ok, added + deleted}
    else
      _ -> budget_git_error("Git numstat evidence was malformed")
    end
  end

  defp direct_orocsy_dependency?(patch) do
    patch
    |> String.split(~r/\R/)
    |> Enum.any?(fn line ->
      String.starts_with?(line, "+") and not String.starts_with?(line, "+++") and
        String.contains?(line, "SymphonyElixir.Orocsy")
    end)
  end

  defp same_path?(left, right) do
    with {:ok, canonical_left} <- PathSafety.canonicalize(left),
         {:ok, canonical_right} <- PathSafety.canonicalize(right) do
      canonical_left == canonical_right
    else
      _error -> false
    end
  end

  defp sha1?(value), do: is_binary(value) and Regex.match?(@sha1_pattern, value)
  defp sha256?(value), do: is_binary(value) and Regex.match?(@sha256_pattern, value)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp normalized_path?(path) when is_binary(path) do
    path != "" and Path.type(path) == :relative and not String.contains?(path, "\\") and
      not Regex.match?(~r/[\x00-\x1F\x7F]/, path) and
      path == Path.join(Path.split(path)) and
      Enum.all?(Path.split(path), &(&1 not in ["", ".", ".."]))
  end

  defp normalized_path?(_path), do: false

  defp descendant_path?(path, root), do: String.starts_with?(path, root <> "/")
  defp valid_hook_id?(value), do: is_binary(value) and value != "" and String.trim(value) == value

  defp duplicate_values(entries, field) do
    entries
    |> Enum.flat_map(fn
      %{} = entry -> [entry[field]]
      _ -> []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
    |> Enum.sort()
  end

  defp field_invalid(field, expected, actual),
    do: [manifest_field_finding(field, expected, actual)]

  defp manifest_field_finding(field, expected, actual) do
    %Finding{
      code: :budget_manifest_field_invalid,
      field: field,
      expected: expected,
      actual: actual
    }
  end

  defp budget_git_error(detail),
    do: {:error, [%Finding{code: :budget_git_unavailable, field: "git", detail: detail}]}

  defp maybe_add(findings, true, finding), do: [finding | findings]
  defp maybe_add(findings, false, _finding), do: findings

  defp sort_findings(findings) do
    Enum.sort_by(findings, fn finding ->
      {finding.field || "", Enum.find_index(@finding_order, &(&1 == finding.code)) || 999, finding.code}
    end)
  end

  defp key_name(key) when is_binary(key), do: key
  defp key_name(key), do: inspect(key)

  defp format_path(parts) do
    Enum.map_join(parts, ".", fn
      index when is_integer(index) -> "[#{index}]"
      part -> part
    end)
  end
end
