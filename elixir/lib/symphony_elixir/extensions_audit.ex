defmodule SymphonyElixir.ExtensionsAudit.Finding do
  @moduledoc false

  @type t :: %__MODULE__{
          code: atom(),
          field: String.t() | nil,
          expected: term(),
          actual: term(),
          detail: String.t() | nil
        }

  defstruct [:code, :field, :expected, :actual, :detail]
end

defmodule SymphonyElixir.ExtensionsAudit.Manifest do
  @moduledoc false

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          repository: String.t(),
          commit: String.t(),
          tree: String.t(),
          elixir_tree: String.t(),
          version: String.t(),
          spec_status: String.t(),
          verified_at: String.t()
        }

  defstruct [:schema_version, :repository, :commit, :tree, :elixir_tree, :version, :spec_status, :verified_at]
end

defmodule SymphonyElixir.ExtensionsAudit.Report do
  @moduledoc false

  alias SymphonyElixir.ExtensionsAudit.Finding

  @type t :: %__MODULE__{
          check: :baseline,
          baseline_commit: String.t(),
          head: String.t(),
          repository_tree: String.t(),
          elixir_tree: String.t(),
          first_parent_verified: boolean(),
          findings: [Finding.t()]
        }

  defstruct [:check, :baseline_commit, :head, :repository_tree, :elixir_tree, :first_parent_verified, findings: []]
end

defmodule SymphonyElixir.ExtensionsAudit do
  @moduledoc false

  alias SymphonyElixir.PathSafety
  alias __MODULE__.{Finding, Manifest, Report}

  @manifest_file "UPSTREAM_BASE.yml"
  @manifest_keys ~w(schema_version repository commit tree elixir_tree version spec_status verified_at)
  @git_env [
    {"GIT_NO_LAZY_FETCH", "1"},
    {"GIT_OPTIONAL_LOCKS", "0"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_CONFIG_COUNT", "0"},
    {"GIT_CONFIG_PARAMETERS", nil},
    {"GIT_NO_REPLACE_OBJECTS", "1"},
    {"GIT_REPLACE_REF_BASE", nil},
    {"GIT_SHALLOW_FILE", nil},
    {"GIT_DIR", nil},
    {"GIT_WORK_TREE", nil},
    {"GIT_COMMON_DIR", nil},
    {"GIT_OBJECT_DIRECTORY", nil},
    {"GIT_ALTERNATE_OBJECT_DIRECTORIES", nil},
    {"GIT_INDEX_FILE", nil},
    {"GIT_NAMESPACE", nil},
    {"GIT_CEILING_DIRECTORIES", nil},
    {"GIT_DISCOVERY_ACROSS_FILESYSTEM", nil}
  ]

  @sha_pattern ~r/^[0-9a-f]{40}$/

  @spec verify_baseline(Path.t(), keyword()) :: {:ok, Report.t()} | {:error, [Finding.t()]}
  def verify_baseline(repo_root, opts \\ []) do
    manifest_path = Path.join(repo_root, @manifest_file)
    git = Keyword.get(opts, :git, &System.cmd/3)

    with {:ok, source} <- read_manifest(manifest_path),
         {:ok, manifest} <- decode_manifest(source),
         :ok <- validate_mapping(manifest),
         :ok <- validate_schema_version(manifest),
         :ok <- reject_unknown_keys(manifest),
         {:ok, manifest} <- validate_manifest(manifest),
         :ok <- verify_worktree(repo_root, git),
         :ok <- verify_commit_object(repo_root, manifest, git),
         :ok <- verify_repository_tree(repo_root, manifest, git),
         :ok <- verify_elixir_tree(repo_root, manifest, git),
         {:ok, head} <- resolve_head(repo_root, git),
         :ok <- verify_ordinary_ancestry(repo_root, manifest, head, git),
         :ok <- verify_first_parent(repo_root, manifest, head, git) do
      {:ok,
       %Report{
         check: :baseline,
         baseline_commit: manifest.commit,
         head: head,
         repository_tree: manifest.tree,
         elixir_tree: manifest.elixir_tree,
         first_parent_verified: true,
         findings: []
       }}
    else
      {:error, :enoent} ->
        {:error, [%Finding{code: :manifest_missing, field: @manifest_file}]}

      {:error, {:manifest_unreadable, reason}} ->
        {:error,
         [
           %Finding{
             code: :manifest_unreadable,
             field: @manifest_file,
             detail: "manifest could not be read: #{:file.format_error(reason)}"
           }
         ]}

      {:error, _reason} ->
        {:error, invalid_yaml("manifest could not be decoded")}

      findings when is_list(findings) ->
        {:error, findings}
    end
  end

  defp read_manifest(path) do
    case File.read(path) do
      {:ok, source} -> {:ok, source}
      {:error, :enoent} = error -> error
      {:error, reason} -> {:error, {:manifest_unreadable, reason}}
    end
  end

  defp decode_manifest(source) do
    case YamlElixir.read_all_from_string(source, maps_as_keywords: true) do
      {:ok, [pairs]} when is_list(pairs) ->
        decode_mapping_pairs(pairs)

      {:ok, [_document]} ->
        {:ok, :not_a_mapping}

      {:ok, _documents} ->
        invalid_yaml("expected exactly one YAML document")

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_mapping_pairs(pairs) do
    if Enum.all?(pairs, &match?({_key, _value}, &1)) do
      decode_unique_mapping_pairs(pairs)
    else
      {:ok, :not_a_mapping}
    end
  end

  defp decode_unique_mapping_pairs(pairs) do
    case duplicate_key(pairs) do
      nil -> {:ok, Map.new(pairs)}
      key -> invalid_yaml("duplicate top-level key: #{unknown_key_name(key)}")
    end
  end

  defp duplicate_key(pairs) do
    pairs
    |> Enum.group_by(fn {key, _value} -> key end)
    |> Enum.filter(fn {_key, entries} -> length(entries) > 1 end)
    |> Enum.map(fn {key, _entries} -> key end)
    |> Enum.sort_by(&unknown_key_name/1)
    |> List.first()
  end

  defp invalid_yaml(detail) do
    [%Finding{code: :manifest_invalid_yaml, field: @manifest_file, detail: detail}]
  end

  defp reject_unknown_keys(manifest) when is_map(manifest) do
    unknown_keys =
      manifest
      |> Map.keys()
      |> Enum.reject(&(&1 in @manifest_keys))
      |> Enum.map(&unknown_key_name/1)
      |> Enum.sort()

    case unknown_keys do
      [] -> :ok
      keys -> Enum.map(keys, &%Finding{code: :manifest_unknown_key, field: &1})
    end
  end

  defp unknown_key_name(key) when is_binary(key), do: key
  defp unknown_key_name(key), do: inspect(key)

  defp validate_mapping(manifest) when is_map(manifest), do: :ok

  defp validate_mapping(_manifest) do
    [%Finding{code: :manifest_invalid_yaml, field: @manifest_file, detail: "expected a mapping"}]
  end

  defp validate_schema_version(%{"schema_version" => 1}), do: :ok

  defp validate_schema_version(%{"schema_version" => schema_version}) do
    [%Finding{code: :manifest_schema_unsupported, field: "schema_version", expected: 1, actual: schema_version}]
  end

  defp validate_schema_version(manifest) do
    invalid_field("schema_version", 1, manifest["schema_version"])
  end

  defp validate_manifest(manifest) do
    validators = [
      {"repository", &valid_nonempty_string?/1, "non-empty repository URL"},
      {"commit", &valid_sha?/1, "full lowercase 40-character object ID"},
      {"tree", &valid_sha?/1, "full lowercase 40-character object ID"},
      {"elixir_tree", &valid_sha?/1, "full lowercase 40-character object ID"},
      {"version", &valid_nonempty_string?/1, "non-empty version"},
      {"spec_status", &valid_nonempty_string?/1, "non-empty spec status"},
      {"verified_at", &valid_date?/1, "ISO 8601 date"}
    ]

    case Enum.find(validators, fn {field, valid?, _expected} -> not valid?.(manifest[field]) end) do
      nil ->
        {:ok,
         %Manifest{
           schema_version: manifest["schema_version"],
           repository: manifest["repository"],
           commit: manifest["commit"],
           tree: manifest["tree"],
           elixir_tree: manifest["elixir_tree"],
           version: manifest["version"],
           spec_status: manifest["spec_status"],
           verified_at: manifest["verified_at"]
         }}

      {field, _valid?, expected} ->
        invalid_field(field, expected, manifest[field])
    end
  end

  defp valid_sha?(value), do: is_binary(value) and Regex.match?(@sha_pattern, value)
  defp valid_nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_date?(value) when is_binary(value) do
    match?({:ok, _date}, Date.from_iso8601(value))
  end

  defp valid_date?(_value), do: false

  defp invalid_field(field, expected, actual) do
    [%Finding{code: :manifest_field_invalid, field: field, expected: expected, actual: actual}]
  end

  defp verify_worktree(repo_root, git) do
    case run_git(git, repo_root, ["rev-parse", "--show-toplevel"]) do
      {:ok, output, 0} ->
        actual_root = String.trim(output)

        if same_path?(actual_root, repo_root) do
          :ok
        else
          [%Finding{code: :not_a_git_worktree, field: "repo_root", expected: Path.expand(repo_root), actual: actual_root}]
        end

      {:ok, _output, _status} ->
        [%Finding{code: :not_a_git_worktree, field: "repo_root", actual: Path.expand(repo_root)}]

      {:error, detail} ->
        [%Finding{code: :git_unavailable, field: "git", detail: detail}]
    end
  end

  defp same_path?(left, right) do
    with {:ok, canonical_left} <- PathSafety.canonicalize(left),
         {:ok, canonical_right} <- PathSafety.canonicalize(right) do
      canonical_left == canonical_right
    else
      _error -> false
    end
  end

  defp verify_commit_object(repo_root, manifest, git) do
    case run_git(git, repo_root, ["cat-file", "-t", manifest.commit]) do
      {:ok, output, 0} ->
        if String.trim(output) == "commit" do
          :ok
        else
          [%Finding{code: :baseline_object_not_commit, field: "commit", expected: "commit", actual: String.trim(output)}]
        end

      {:ok, _output, _status} ->
        [%Finding{code: :baseline_object_missing, field: "commit", expected: manifest.commit, detail: "pinned commit is absent; fetch sufficient history outside the audit and retry"}]

      {:error, detail} ->
        [%Finding{code: :git_unavailable, field: "git", detail: detail}]
    end
  end

  defp verify_repository_tree(repo_root, manifest, git) do
    case run_git(git, repo_root, ["rev-parse", "#{manifest.commit}^{tree}"]) do
      {:ok, output, 0} ->
        actual = String.trim(output)

        if actual == manifest.tree do
          :ok
        else
          [%Finding{code: :baseline_tree_mismatch, field: "tree", expected: manifest.tree, actual: actual}]
        end

      {:ok, _output, status} ->
        git_command_failed("resolving repository tree", status)

      {:error, detail} ->
        [%Finding{code: :git_unavailable, field: "git", detail: detail}]
    end
  end

  defp verify_elixir_tree(repo_root, manifest, git) do
    case run_git(git, repo_root, ["rev-parse", "#{manifest.commit}:elixir"]) do
      {:ok, output, 0} ->
        actual = String.trim(output)

        if actual == manifest.elixir_tree do
          :ok
        else
          [%Finding{code: :baseline_elixir_tree_mismatch, field: "elixir_tree", expected: manifest.elixir_tree, actual: actual}]
        end

      {:ok, _output, _status} ->
        [%Finding{code: :baseline_elixir_tree_missing, field: "elixir_tree", expected: manifest.elixir_tree}]

      {:error, detail} ->
        [%Finding{code: :git_unavailable, field: "git", detail: detail}]
    end
  end

  defp resolve_head(repo_root, git) do
    case run_git(git, repo_root, ["rev-parse", "HEAD"]) do
      {:ok, output, 0} ->
        head = String.trim(output)

        if valid_sha?(head) do
          {:ok, head}
        else
          [%Finding{code: :head_unavailable, field: "HEAD", actual: head}]
        end

      {:ok, _output, _status} ->
        [%Finding{code: :head_unavailable, field: "HEAD"}]

      {:error, detail} ->
        [%Finding{code: :git_unavailable, field: "git", detail: detail}]
    end
  end

  defp verify_ordinary_ancestry(repo_root, manifest, head, git) do
    case run_git(git, repo_root, ["merge-base", "--is-ancestor", manifest.commit, "HEAD"]) do
      {:ok, _output, 0} ->
        :ok

      {:ok, _output, 1} ->
        [%Finding{code: :baseline_not_ancestor, field: "commit", expected: manifest.commit, actual: head}]

      {:ok, _output, status} ->
        git_command_failed("checking baseline ancestry", status)

      {:error, detail} ->
        [%Finding{code: :git_unavailable, field: "git", detail: detail}]
    end
  end

  defp verify_first_parent(repo_root, manifest, head, git) do
    case run_git(git, repo_root, ["rev-list", "--first-parent", "HEAD"]) do
      {:ok, output, 0} ->
        first_parent_commits = String.split(output, ~r/\R/, trim: true)

        if manifest.commit in first_parent_commits do
          :ok
        else
          [
            %Finding{
              code: :baseline_not_on_first_parent,
              field: "commit",
              expected: manifest.commit,
              actual: head,
              detail: "pinned commit is not present in HEAD first-parent history"
            }
          ]
        end

      {:ok, _output, status} ->
        git_command_failed("enumerating first-parent history", status)

      {:error, detail} ->
        [%Finding{code: :git_unavailable, field: "git", detail: detail}]
    end
  end

  defp run_git(git, repo_root, args) do
    case git.("git", ["-C", repo_root | args], stderr_to_stdout: true, env: @git_env) do
      {output, status} when is_binary(output) and is_integer(status) -> {:ok, output, status}
    end
  rescue
    error in ErlangError ->
      if Map.get(error, :original) == :enoent do
        {:error, "git executable not found on PATH"}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp git_command_failed(operation, status) do
    [%Finding{code: :git_unavailable, field: "git", detail: "git command failed while #{operation} (status #{status})"}]
  end
end
