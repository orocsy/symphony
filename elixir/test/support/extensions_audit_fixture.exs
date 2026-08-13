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
    {"GIT_TRACE", nil},
    {"GIT_TRACE_CURL", nil},
    {"GIT_CURL_VERBOSE", nil},
    {"GIT_TRACE_FSMONITOR", nil},
    {"GIT_TRACE_PACK_ACCESS", nil},
    {"GIT_TRACE_PACKET", nil},
    {"GIT_TRACE_PERFORMANCE", nil},
    {"GIT_TRACE_REFS", nil},
    {"GIT_TRACE_SETUP", nil},
    {"GIT_TRACE_SHALLOW", nil},
    {"GIT_TRACE2", nil},
    {"GIT_TRACE2_EVENT", nil},
    {"GIT_TRACE2_PERF", nil},
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

  # Keep fixture setup independent from ExtensionsAudit's environment. Sharing
  # the production constant here would let a regression weaken both the code
  # and the repositories used to test it in the same edit.

  def create_root!(manifest) do
    root = unique_root("extensions-audit-test")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "UPSTREAM_BASE.yml"), manifest)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  def create_baseline_fixture! do
    root = create_git_repo!()
    baseline = commit_baseline!(root)
    write_manifest!(root, baseline)

    %{root: root, baseline: baseline, head: baseline}
  end

  def create_budget_fixture! do
    root = create_git_repo!()

    files = %{
      "elixir/lib/symphony_elixir/orchestrator.ex" => "defmodule Fixture.Orchestrator do\nend\n",
      "elixir/lib/symphony_elixir/agent_runner.ex" => "defmodule Fixture.AgentRunner do\nend\n",
      "elixir/lib/symphony_elixir/codex/app_server.ex" => "defmodule Fixture.AppServer do\nend\n",
      "elixir/lib/symphony_elixir/unregistered.ex" => "defmodule Fixture.Unregistered do\nend\n"
    }

    Enum.each(files, fn {path, body} ->
      target = Path.join(root, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, body)
    end)

    git!(root, ["add", "elixir/lib/symphony_elixir"])
    git!(root, ["commit", "-m", "upstream kernel baseline"])
    baseline = git!(root, ["rev-parse", "HEAD"])
    write_manifest!(root, baseline)
    write_budget_manifest!(root, baseline)

    %{root: root, baseline: baseline, head: baseline, files: files}
  end

  def write_budget_manifest!(root, baseline, replacements \\ %{}) do
    manifest =
      """
      schema_version: 1
      baseline_commit: #{baseline}
      kernel_root: elixir/lib/symphony_elixir
      prototype_checkpoint: #{String.duplicate("b", 40)}
      prototype_total_patch_sha256: #{String.duplicate("c", 64)}
      total_max_changed_lines: 40
      files:
        - path: elixir/lib/symphony_elixir/orchestrator.ex
          max_changed_lines: 7
          required: false
          expected_patch_sha256: #{String.duplicate("d", 64)}
          hooks:
            - id: dispatch.admission_before_worker_selection
              max_changed_lines: 7
              prototype_patch_sha256: #{String.duplicate("e", 64)}
        - path: elixir/lib/symphony_elixir/agent_runner.ex
          max_changed_lines: 8
          required: false
          expected_patch_sha256: #{String.duplicate("f", 64)}
          hooks:
            - id: delivery.workspace_ready_before_model
              max_changed_lines: 8
              prototype_patch_sha256: #{String.duplicate("a", 64)}
        - path: elixir/lib/symphony_elixir/codex/app_server.ex
          max_changed_lines: 25
          required: false
          expected_patch_sha256: #{String.duplicate("b", 64)}
          hooks:
            - id: authorization.immutable_turn_context
              max_changed_lines: 24
              prototype_patch_sha256: #{String.duplicate("c", 64)}
            - id: observer.after_event_assembly
              max_changed_lines: 1
              prototype_patch_sha256: #{String.duplicate("a", 64)}
      """

    manifest =
      Enum.reduce(replacements, manifest, fn {needle, replacement}, source ->
        String.replace(source, needle, replacement)
      end)

    File.write!(Path.join(root, "UPSTREAM_PATCH_BUDGET.yml"), manifest)
    manifest
  end

  def patch_sha256!(root, path) do
    baseline = git!(root, ["rev-list", "--max-parents=0", "HEAD"])

    command =
      @git_config ++
        [
          "-C",
          root,
          "diff",
          "--no-ext-diff",
          "--no-textconv",
          "--no-renames",
          "--no-color",
          "--full-index",
          "--unified=3",
          baseline,
          "--",
          path
        ]

    patch =
      case System.cmd("git", command, stderr_to_stdout: true, env: @git_env) do
        {output, 0} -> output
        {output, status} -> flunk("git diff failed with #{status}: #{output}")
      end

    :crypto.hash(:sha256, patch)
    |> Base.encode16(case: :lower)
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
