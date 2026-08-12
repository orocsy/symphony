defmodule SymphonyElixir.ExtensionsAuditTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ExtensionsAudit
  import SymphonyElixir.TestSupport.ExtensionsAuditFixture

  @manifest """
  schema_version: 1
  repository: https://github.com/openai/symphony
  commit: f8e8b8a670c799f6e0ade7a8c25c4bf4a4a56ec7
  tree: 37a4c6c184db05cd2d59bfc50943979919ec988a
  elixir_tree: 77d9ba67775e6681eb1ad5cf03a019e678a8e941
  version: 0.0.2
  spec_status: draft-v1
  verified_at: 2026-07-29
  """

  test "rejects an unknown schema key before invoking git" do
    root = create_root!(@manifest <> "unexpected: true\n")

    git = fn _executable, _args, _opts ->
      send(self(), :git_called)
      {"", 0}
    end

    assert {:error, [%ExtensionsAudit.Finding{code: :manifest_unknown_key, field: "unexpected"}]} =
             ExtensionsAudit.verify_baseline(root, git: git)

    refute_received :git_called
  end

  test "renders non-string YAML keys as deterministic unknown fields" do
    root = create_root!(@manifest <> "1: unexpected\n")

    assert {:error, [%ExtensionsAudit.Finding{code: :manifest_unknown_key, field: "1"}]} =
             ExtensionsAudit.verify_baseline(root, git: fn _, _, _ -> flunk("unknown key reached Git") end)
  end

  test "rejects a short or revision-expression commit before invoking git" do
    for commit <- ["f8e8b8a", "HEAD~1"] do
      root = create_root!(String.replace(@manifest, ~r/^commit: .*$/m, "commit: #{commit}"))

      git = fn _executable, _args, _opts ->
        send(self(), {:git_called, commit})
        {"", 0}
      end

      assert {:error, [%ExtensionsAudit.Finding{code: :manifest_field_invalid, field: "commit", actual: ^commit}]} =
               ExtensionsAudit.verify_baseline(root, git: git)

      refute_received {:git_called, ^commit}
    end
  end

  test "reports a missing baseline object without cascading tree findings" do
    root = create_root!(@manifest)
    scripted_git = git_with_results(root, %{object: {"fatal: Not a valid object name\n", 128}})

    git = fn "git", args, opts ->
      send(self(), {:git_args, args})
      scripted_git.("git", args, opts)
    end

    assert {:error, [%ExtensionsAudit.Finding{code: :baseline_object_missing, field: "commit"}]} =
             ExtensionsAudit.verify_baseline(root, git: git)

    assert_received {:git_args, ["-C", ^root, "rev-parse", "--show-toplevel"]}
    assert_received {:git_args, ["-C", ^root, "cat-file", "-t", _commit]}
    refute_received {:git_args, ["-C", ^root, "rev-parse", _tree_expression]}
  end

  test "reports a repository tree mismatch" do
    root = create_root!(@manifest)
    wrong_tree = String.duplicate("a", 40)
    git = git_with_results(root, %{repository_tree: {wrong_tree <> "\n", 0}})

    assert {:error,
            [
              %ExtensionsAudit.Finding{
                code: :baseline_tree_mismatch,
                field: "tree",
                expected: "37a4c6c184db05cd2d59bfc50943979919ec988a",
                actual: ^wrong_tree
              }
            ]} = ExtensionsAudit.verify_baseline(root, git: git)
  end

  test "reports an elixir subtree mismatch" do
    root = create_root!(@manifest)
    wrong_tree = String.duplicate("b", 40)
    git = git_with_results(root, %{elixir_tree: {wrong_tree <> "\n", 0}})

    assert {:error,
            [
              %ExtensionsAudit.Finding{
                code: :baseline_elixir_tree_mismatch,
                field: "elixir_tree",
                expected: "77d9ba67775e6681eb1ad5cf03a019e678a8e941",
                actual: ^wrong_tree
              }
            ]} = ExtensionsAudit.verify_baseline(root, git: git)
  end

  test "rejects ordinary ancestry when the baseline is absent" do
    root = create_root!(@manifest)
    head = String.duplicate("c", 40)
    git = git_with_results(root, %{head: {head <> "\n", 0}, ancestry: {"", 1}})

    assert {:error, [%ExtensionsAudit.Finding{code: :baseline_not_ancestor, field: "commit", actual: ^head}]} =
             ExtensionsAudit.verify_baseline(root, git: git)
  end

  test "rejects ancestry when the baseline is not on the first-parent chain" do
    %{root: root, head: head} = create_merge_fixture!(:orocsy)

    assert {:error, [%ExtensionsAudit.Finding{code: :baseline_not_on_first_parent, field: "commit", actual: ^head}]} =
             ExtensionsAudit.verify_baseline(root)
  end

  test "accepts the pinned baseline from a linked git worktree" do
    %{root: repo_root, baseline: baseline} = create_linked_worktree_fixture!()

    assert File.regular?(Path.join(repo_root, ".git"))

    assert {:ok,
            %ExtensionsAudit.Report{
              check: :baseline,
              baseline_commit: ^baseline,
              first_parent_verified: true,
              findings: []
            }} = ExtensionsAudit.verify_baseline(repo_root)
  end

  test "accepts an OpenAI-first-parent merge with exact commit and trees" do
    %{root: root, baseline: baseline, head: head} = create_merge_fixture!(:openai)

    assert {:ok, %ExtensionsAudit.Report{baseline_commit: ^baseline, head: ^head, first_parent_verified: true}} =
             ExtensionsAudit.verify_baseline(root)
  end

  test "invokes only the approved read-only Git command allowlist" do
    %{root: repo_root} = create_baseline_fixture!()

    git = fn executable, args, opts ->
      send(self(), {:git_invocation, args, opts})
      System.cmd(executable, args, opts)
    end

    assert {:ok, %ExtensionsAudit.Report{}} = ExtensionsAudit.verify_baseline(repo_root, git: git)

    invocations = collect_git_invocations([])

    assert Enum.all?(invocations, fn {args, _opts} ->
             Enum.at(args, 2) in ~w(rev-parse cat-file merge-base rev-list)
           end)

    assert Enum.all?(invocations, fn {_args, opts} ->
             env = Keyword.fetch!(opts, :env)

             {"GIT_NO_LAZY_FETCH", "1"} in env and
               {"GIT_OPTIONAL_LOCKS", "0"} in env and
               {"GIT_CONFIG_GLOBAL", "/dev/null"} in env and
               {"GIT_CONFIG_SYSTEM", "/dev/null"} in env and
               {"GIT_CONFIG_COUNT", "0"} in env and
               {"GIT_NO_REPLACE_OBJECTS", "1"} in env and
               {"GIT_DIR", nil} in env and
               {"GIT_WORK_TREE", nil} in env and
               {"GIT_ALTERNATE_OBJECT_DIRECTORIES", nil} in env
           end)
  end

  test "ignores inherited Git repository redirect variables" do
    %{root: target_root, baseline: baseline} = create_baseline_fixture!()
    %{root: decoy_root} = create_baseline_fixture!()
    previous_git_dir = System.get_env("GIT_DIR")

    on_exit(fn -> restore_env("GIT_DIR", previous_git_dir) end)
    System.put_env("GIT_DIR", Path.join(decoy_root, ".git"))

    assert {:ok, %ExtensionsAudit.Report{baseline_commit: ^baseline}} =
             ExtensionsAudit.verify_baseline(target_root)
  end

  test "ignores repository replacement refs when verifying pinned objects" do
    %{root: root, baseline: baseline} = create_baseline_fixture!()
    manifest = File.read!(Path.join(root, "UPSTREAM_BASE.yml"))

    git!(root, ["switch", "--orphan", "replacement"])
    File.rm_rf!(Path.join(root, "elixir"))
    File.write!(Path.join(root, "REPLACEMENT.md"), "replacement object\n")
    git!(root, ["add", "-A"])
    git!(root, ["commit", "-m", "replacement object"])
    replacement = git!(root, ["rev-parse", "HEAD"])
    git!(root, ["switch", "--detach", baseline])
    File.write!(Path.join(root, "UPSTREAM_BASE.yml"), manifest)
    git!(root, ["replace", baseline, replacement])

    assert {:ok, %ExtensionsAudit.Report{baseline_commit: ^baseline}} =
             ExtensionsAudit.verify_baseline(root)
  end

  test "rejects duplicate keys and multiple YAML documents before invoking Git" do
    duplicate_root = create_root!(@manifest <> "commit: #{String.duplicate("a", 40)}\n")
    multi_document_root = create_root!(@manifest <> "---\n" <> @manifest)
    git = fn _, _, _ -> flunk("ambiguous manifest reached Git") end

    assert {:error, [%ExtensionsAudit.Finding{code: :manifest_invalid_yaml, detail: "duplicate top-level key: commit"}]} =
             ExtensionsAudit.verify_baseline(duplicate_root, git: git)

    assert {:error, [%ExtensionsAudit.Finding{code: :manifest_invalid_yaml, detail: "expected exactly one YAML document"}]} =
             ExtensionsAudit.verify_baseline(multi_document_root, git: git)
  end

  test "reports an unreadable manifest separately from invalid YAML" do
    root = create_root!(@manifest)
    manifest_path = Path.join(root, "UPSTREAM_BASE.yml")
    File.chmod!(manifest_path, 0o000)
    on_exit(fn -> File.chmod(manifest_path, 0o600) end)

    assert {:error, [%ExtensionsAudit.Finding{code: :manifest_unreadable, field: "UPSTREAM_BASE.yml"}]} =
             ExtensionsAudit.verify_baseline(root, git: fn _, _, _ -> flunk("unreadable manifest reached Git") end)
  end

  test "reports Git command failures without leaking raw command output" do
    root = create_root!(@manifest)
    secret = "/private/operator/repository"
    git = git_with_results(root, %{repository_tree: {"fatal: cannot read #{secret}\n", 128}})

    assert {:error, [%ExtensionsAudit.Finding{code: :git_unavailable, detail: detail}]} =
             ExtensionsAudit.verify_baseline(root, git: git)

    assert detail == "git command failed while resolving repository tree (status 128)"
    refute detail =~ secret
  end

  test "reraises unexpected Erlang errors from the Git adapter" do
    root = create_root!(@manifest)

    git = fn _, _, _ ->
      case :unexpected do
        :expected -> {"", 0}
      end
    end

    assert_raise CaseClauseError, fn -> ExtensionsAudit.verify_baseline(root, git: git) end
  end

  test "reports missing, malformed, and non-mapping manifests before invoking git" do
    missing_root = create_root!(@manifest)
    File.rm!(Path.join(missing_root, "UPSTREAM_BASE.yml"))
    malformed_root = create_root!("schema_version: [\n")
    scalar_root = create_root!("baseline\n")
    sequence_root = create_root!("- baseline\n- other\n")

    git = fn _executable, _args, _opts ->
      send(self(), :git_called_for_invalid_manifest)
      {"", 0}
    end

    assert {:error, [%ExtensionsAudit.Finding{code: :manifest_missing}]} =
             ExtensionsAudit.verify_baseline(missing_root, git: git)

    assert {:error, [%ExtensionsAudit.Finding{code: :manifest_invalid_yaml}]} =
             ExtensionsAudit.verify_baseline(malformed_root, git: git)

    assert {:error, [%ExtensionsAudit.Finding{code: :manifest_invalid_yaml, detail: "expected a mapping"}]} =
             ExtensionsAudit.verify_baseline(scalar_root, git: git)

    assert {:error, [%ExtensionsAudit.Finding{code: :manifest_invalid_yaml, detail: "expected a mapping"}]} =
             ExtensionsAudit.verify_baseline(sequence_root, git: git)

    refute_received :git_called_for_invalid_manifest
  end

  test "rejects unsupported, missing, and ill-typed manifest fields before invoking git" do
    unsupported_root = create_root!(String.replace(@manifest, "schema_version: 1", "schema_version: 2") <> "future_field: true\n")
    missing_root = create_root!(String.replace(@manifest, "schema_version: 1\n", ""))
    invalid_date_root = create_root!(String.replace(@manifest, "verified_at: 2026-07-29", "verified_at: true"))

    git = fn _executable, _args, _opts -> flunk("invalid manifest reached Git") end

    assert {:error, [%ExtensionsAudit.Finding{code: :manifest_schema_unsupported, actual: 2}]} =
             ExtensionsAudit.verify_baseline(unsupported_root, git: git)

    assert {:error, [%ExtensionsAudit.Finding{code: :manifest_field_invalid, field: "schema_version", actual: nil}]} =
             ExtensionsAudit.verify_baseline(missing_root, git: git)

    assert {:error, [%ExtensionsAudit.Finding{code: :manifest_field_invalid, field: "verified_at", actual: true}]} =
             ExtensionsAudit.verify_baseline(invalid_date_root, git: git)
  end

  test "reports Git unavailability at every evidence stage" do
    stages = [:worktree, :object, :repository_tree, :elixir_tree, :head, :ancestry, :first_parent]

    for stage <- stages do
      root = create_root!(@manifest)

      assert {:error, [%ExtensionsAudit.Finding{code: :git_unavailable, field: "git"}]} =
               ExtensionsAudit.verify_baseline(root, git: git_failing_at(root, stage))
    end
  end

  test "reports non-worktrees and non-commit baseline objects" do
    root = create_root!(@manifest)

    not_worktree = fn "git", _args, _opts -> {"fatal: not a git repository\n", 128} end

    assert {:error, [%ExtensionsAudit.Finding{code: :not_a_git_worktree}]} =
             ExtensionsAudit.verify_baseline(root, git: not_worktree)

    wrong_root = fn "git", args, _opts ->
      case Enum.drop(args, 2) do
        ["rev-parse", "--show-toplevel"] -> {System.tmp_dir!() <> "\n", 0}
      end
    end

    assert {:error, [%ExtensionsAudit.Finding{code: :not_a_git_worktree}]} =
             ExtensionsAudit.verify_baseline(root, git: wrong_root)

    not_commit = fn "git", args, _opts ->
      case Enum.drop(args, 2) do
        ["rev-parse", "--show-toplevel"] -> {root <> "\n", 0}
        ["cat-file", "-t", _commit] -> {"tree\n", 0}
      end
    end

    assert {:error, [%ExtensionsAudit.Finding{code: :baseline_object_not_commit, actual: "tree"}]} =
             ExtensionsAudit.verify_baseline(root, git: not_commit)
  end

  test "reports command failures for trees, HEAD, and first-parent enumeration" do
    stages_and_codes = [
      repository_tree: :git_unavailable,
      elixir_tree: :baseline_elixir_tree_missing,
      head: :head_unavailable,
      ancestry: :git_unavailable,
      first_parent: :git_unavailable
    ]

    for {stage, code} <- stages_and_codes do
      root = create_root!(@manifest)

      assert {:error, [%ExtensionsAudit.Finding{code: ^code}]} =
               ExtensionsAudit.verify_baseline(root, git: git_returning_status_at(root, stage))
    end
  end

  defp collect_git_invocations(acc) do
    receive do
      {:git_invocation, args, opts} -> collect_git_invocations([{args, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp git_failing_at(root, failing_stage) do
    fn "git", args, _opts ->
      stage = command_stage(args)

      if stage == failing_stage do
        raise ErlangError, original: :enoent
      else
        successful_git_result(root, stage)
      end
    end
  end

  defp git_with_results(root, overrides) do
    fn "git", args, _opts ->
      stage = command_stage(args)
      Map.get(overrides, stage, successful_git_result(root, stage))
    end
  end

  defp git_returning_status_at(root, failing_stage) do
    fn "git", args, _opts ->
      stage = command_stage(args)

      if stage == failing_stage do
        {"command failed\n", 128}
      else
        successful_git_result(root, stage)
      end
    end
  end

  defp command_stage(args) do
    case Enum.drop(args, 2) do
      ["rev-parse", "--show-toplevel"] -> :worktree
      ["cat-file", "-t", _commit] -> :object
      ["rev-parse", "HEAD"] -> :head
      ["rev-parse", expression] -> if(String.ends_with?(expression, ":elixir"), do: :elixir_tree, else: :repository_tree)
      ["merge-base", "--is-ancestor", _commit, "HEAD"] -> :ancestry
      ["rev-list", "--first-parent", "HEAD"] -> :first_parent
    end
  end

  defp successful_git_result(root, :worktree), do: {root <> "\n", 0}
  defp successful_git_result(_root, :object), do: {"commit\n", 0}
  defp successful_git_result(_root, :repository_tree), do: {"37a4c6c184db05cd2d59bfc50943979919ec988a\n", 0}
  defp successful_git_result(_root, :elixir_tree), do: {"77d9ba67775e6681eb1ad5cf03a019e678a8e941\n", 0}
  defp successful_git_result(_root, :head), do: {String.duplicate("e", 40) <> "\n", 0}
  defp successful_git_result(_root, :ancestry), do: {"", 0}

  defp successful_git_result(_root, :first_parent) do
    {String.duplicate("e", 40) <> "\nf8e8b8a670c799f6e0ade7a8c25c4bf4a4a56ec7\n", 0}
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
