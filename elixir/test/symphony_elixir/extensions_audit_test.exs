defmodule SymphonyElixir.ExtensionsAuditTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExtensionsAudit

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
    repo_root = Path.expand("../../..", __DIR__)

    assert {:ok,
            %ExtensionsAudit.Report{
              check: :baseline,
              baseline_commit: "f8e8b8a670c799f6e0ade7a8c25c4bf4a4a56ec7",
              repository_tree: "37a4c6c184db05cd2d59bfc50943979919ec988a",
              elixir_tree: "77d9ba67775e6681eb1ad5cf03a019e678a8e941",
              first_parent_verified: true,
              findings: []
            }} = ExtensionsAudit.verify_baseline(repo_root)
  end

  test "accepts an OpenAI-first-parent merge with exact commit and trees" do
    %{root: root, baseline: baseline, head: head} = create_merge_fixture!(:openai)

    assert {:ok, %ExtensionsAudit.Report{baseline_commit: ^baseline, head: ^head, first_parent_verified: true}} =
             ExtensionsAudit.verify_baseline(root)
  end

  test "never invokes fetch checkout merge reset or config" do
    repo_root = Path.expand("../../..", __DIR__)

    git = fn executable, args, opts ->
      send(self(), {:git_invocation, args, opts})
      System.cmd(executable, args, opts)
    end

    assert {:ok, %ExtensionsAudit.Report{}} = ExtensionsAudit.verify_baseline(repo_root, git: git)

    invocations = collect_git_invocations([])
    forbidden = ~w(fetch checkout switch merge reset config pull push clone)

    refute Enum.any?(invocations, fn {args, _opts} -> Enum.any?(forbidden, &(&1 in args)) end)

    assert Enum.all?(invocations, fn {_args, opts} ->
             env = Keyword.fetch!(opts, :env)
             {"GIT_NO_LAZY_FETCH", "1"} in env and {"GIT_OPTIONAL_LOCKS", "0"} in env
           end)
  end

  test "reports missing, malformed, and non-mapping manifests before invoking git" do
    missing_root = create_root!(@manifest)
    File.rm!(Path.join(missing_root, "UPSTREAM_BASE.yml"))
    malformed_root = create_root!("schema_version: [\n")
    scalar_root = create_root!("baseline\n")

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
      repository_tree: :baseline_tree_mismatch,
      elixir_tree: :baseline_elixir_tree_missing,
      head: :head_unavailable,
      first_parent: :baseline_not_on_first_parent
    ]

    for {stage, code} <- stages_and_codes do
      root = create_root!(@manifest)

      assert {:error, [%ExtensionsAudit.Finding{code: ^code}]} =
               ExtensionsAudit.verify_baseline(root, git: git_returning_status_at(root, stage))
    end
  end

  defp create_root!(manifest) do
    root = Path.join(System.tmp_dir!(), "extensions-audit-test-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "UPSTREAM_BASE.yml"), manifest)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp create_git_repo! do
    root = Path.join(System.tmp_dir!(), "extensions-audit-git-test-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(root)
    git!(root, ["init", "-b", "openai"])
    git!(root, ["config", "user.name", "Extensions Audit Test"])
    git!(root, ["config", "user.email", "extensions-audit@example.invalid"])
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp create_merge_fixture!(first_parent) when first_parent in [:openai, :orocsy] do
    root = create_git_repo!()

    File.mkdir_p!(Path.join(root, "elixir"))
    File.write!(Path.join([root, "elixir", "README.md"]), "upstream\n")
    git!(root, ["add", "elixir/README.md"])
    git!(root, ["commit", "-m", "upstream baseline"])

    baseline = git!(root, ["rev-parse", "HEAD"])
    tree = git!(root, ["rev-parse", "#{baseline}^{tree}"])
    elixir_tree = git!(root, ["rev-parse", "#{baseline}:elixir"])

    git!(root, ["switch", "--orphan", "orocsy"])
    File.rm_rf!(Path.join(root, "elixir"))
    File.write!(Path.join(root, "OROCSY.md"), "runtime history\n")
    git!(root, ["add", "-A"])
    git!(root, ["commit", "-m", "orocsy history"])

    if first_parent == :openai do
      git!(root, ["switch", "openai"])
      git!(root, ["merge", "--no-ff", "--allow-unrelated-histories", "-m", "merge orocsy history", "orocsy"])
    else
      git!(root, ["merge", "--no-ff", "--allow-unrelated-histories", "-m", "merge OpenAI baseline", "openai"])
    end

    write_manifest!(root, baseline, tree, elixir_tree)
    %{root: root, baseline: baseline, head: git!(root, ["rev-parse", "HEAD"])}
  end

  defp write_manifest!(root, commit, tree, elixir_tree) do
    manifest =
      @manifest
      |> String.replace(~r/^commit: .*$/m, "commit: #{commit}")
      |> String.replace(~r/^tree: .*$/m, "tree: #{tree}")
      |> String.replace(~r/^elixir_tree: .*$/m, "elixir_tree: #{elixir_tree}")

    File.write!(Path.join(root, "UPSTREAM_BASE.yml"), manifest)
  end

  defp git!(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
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
end
