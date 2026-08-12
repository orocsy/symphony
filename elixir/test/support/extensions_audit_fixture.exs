defmodule SymphonyElixir.TestSupport.ExtensionsAuditFixture do
  import ExUnit.Assertions

  @git_env [
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

  @git_config [
    "-c",
    "commit.gpgsign=false",
    "-c",
    "core.hooksPath=",
    "-c",
    "user.name=Extensions Audit Test",
    "-c",
    "user.email=extensions-audit@example.invalid"
  ]

  def create_baseline_fixture! do
    root = create_git_repo!()
    baseline = commit_baseline!(root)
    write_manifest!(root, baseline)

    %{root: root, baseline: baseline, head: baseline}
  end

  def create_merge_fixture!(first_parent) when first_parent in [:openai, :orocsy] do
    root = create_git_repo!()
    baseline = commit_baseline!(root)

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

    write_manifest!(root, baseline)
    %{root: root, baseline: baseline, head: git!(root, ["rev-parse", "HEAD"])}
  end

  def create_linked_worktree_fixture! do
    fixture = create_baseline_fixture!()
    linked_root = fixture.root <> "-linked"
    File.rm!(Path.join(fixture.root, "UPSTREAM_BASE.yml"))
    git!(fixture.root, ["worktree", "add", "--detach", linked_root, fixture.baseline])
    write_manifest!(linked_root, fixture.baseline)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(linked_root) end)

    %{fixture | root: linked_root}
  end

  def git!(root, args) do
    command = @git_config ++ ["-C", root | args]

    case System.cmd("git", command, stderr_to_stdout: true, env: @git_env) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  defp create_git_repo! do
    root = unique_root("extensions-audit-git-test")
    File.mkdir_p!(root)
    git!(root, ["init", "-b", "openai"])
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp commit_baseline!(root) do
    File.mkdir_p!(Path.join(root, "elixir"))
    File.write!(Path.join([root, "elixir", "README.md"]), "upstream #{Path.basename(root)}\n")
    git!(root, ["add", "elixir/README.md"])
    git!(root, ["commit", "-m", "upstream baseline"])
    git!(root, ["rev-parse", "HEAD"])
  end

  defp write_manifest!(root, baseline) do
    tree = git!(root, ["rev-parse", "#{baseline}^{tree}"])
    elixir_tree = git!(root, ["rev-parse", "#{baseline}:elixir"])

    File.write!(
      Path.join(root, "UPSTREAM_BASE.yml"),
      """
      schema_version: 1
      repository: https://github.com/openai/symphony
      commit: #{baseline}
      tree: #{tree}
      elixir_tree: #{elixir_tree}
      version: 0.0.2
      spec_status: draft-v1
      verified_at: 2026-07-29
      """
    )
  end

  defp unique_root(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive, :monotonic])}")
  end
end
