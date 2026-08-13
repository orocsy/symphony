defmodule Mix.Tasks.Extensions.AuditTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import SymphonyElixir.TestSupport.ExtensionsAuditFixture

  alias Mix.Tasks.Extensions.Audit
  alias SymphonyElixir.TestSupport.Snapshot

  defmodule FixtureMixProject do
    def project, do: [app: :extensions_audit_fixture, version: "0.0.0"]
  end

  setup do
    Mix.Task.reenable("extensions.audit")
    :ok
  end

  test "runs baseline then budget by default and prints stable success output" do
    %{root: root, baseline: baseline} = create_budget_fixture!()
    tree = git!(root, ["rev-parse", "#{baseline}^{tree}"])
    elixir_tree = git!(root, ["rev-parse", "#{baseline}:elixir"])
    head = git!(root, ["rev-parse", "HEAD"])

    output =
      capture_io(fn ->
        assert :ok = Audit.run(["--repo-root", root])
      end)

    assert output ==
             "extensions.audit baseline: ok commit=#{baseline} tree=#{tree} elixir_tree=#{elixir_tree} first_parent=true\n" <>
               "extensions.audit budget: ok baseline=#{baseline} head=#{head} changed_kernel_files=0 changed_lines=0 max_changed_lines=40\n"
  end

  test "accepts baseline or budget for --only" do
    %{root: root} = create_budget_fixture!()

    output =
      capture_io(fn ->
        assert :ok = Audit.run(["--only", "baseline", "--repo-root", root])
      end)

    assert output =~ "extensions.audit baseline: ok"

    Mix.Task.reenable("extensions.audit")

    output = capture_io(fn -> assert :ok = Audit.run(["--only", "budget", "--repo-root", root]) end)
    assert output =~ "extensions.audit budget: ok"
  end

  test "resolves the default root from the Mix project file" do
    %{root: root} = create_budget_fixture!()
    project_file = Path.join([root, "elixir", "mix.exs"])
    File.mkdir_p!(Path.dirname(project_file))

    Mix.Project.push(FixtureMixProject, project_file)
    Mix.ProjectStack.printable_app_name()

    on_exit(fn ->
      Mix.Project.pop()
      Mix.ProjectStack.printable_app_name()
    end)

    output = capture_io(fn -> assert :ok = Audit.run([]) end)

    assert output =~ "extensions.audit baseline: ok"
    assert output =~ "extensions.audit budget: ok"
  end

  test "does not run budget when the default baseline check fails" do
    %{root: root} = create_budget_fixture!()
    File.write!(Path.join(root, "UPSTREAM_BASE.yml"), "schema_version: 1\n")

    error_output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, "extensions.audit baseline failed", fn ->
          Audit.run(["--repo-root", root])
        end
      end)

    assert error_output =~ "extensions.audit baseline: error"
    refute error_output =~ "extensions.audit budget:"
  end

  test "raises once with deterministic sanitized budget findings" do
    %{root: root} = create_budget_fixture!()
    path = Path.join(root, "elixir/lib/symphony_elixir/unregistered.ex")
    File.write!(path, "defmodule Fixture.Unregistered do\n  def changed, do: true\nend\n")

    error_output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, "extensions.audit budget failed", fn ->
          Audit.run(["--only", "budget", "--repo-root", root])
        end
      end)

    assert Snapshot.strip_ansi(error_output) ==
             "extensions.audit budget: error code=kernel_path_unregistered field=\"elixir/lib/symphony_elixir/unregistered.ex\"\n"
  end

  test "raises once with deterministic typed findings" do
    root =
      create_root!("""
      schema_version: 1
      repository: https://github.com/openai/symphony
      commit: f8e8b8a670c799f6e0ade7a8c25c4bf4a4a56ec7
      tree: 37a4c6c184db05cd2d59bfc50943979919ec988a
      elixir_tree: 77d9ba67775e6681eb1ad5cf03a019e678a8e941
      version: 0.0.2
      spec_status: draft-v1
      verified_at: 2026-07-29
      z_typo: true
      a_typo: true
      """)

    error_output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, "extensions.audit baseline failed", fn ->
          Audit.run(["--repo-root", root])
        end
      end)

    assert Snapshot.strip_ansi(error_output) ==
             "extensions.audit baseline: error code=manifest_unknown_key field=\"a_typo\"\n" <>
               "extensions.audit baseline: error code=manifest_unknown_key field=\"z_typo\"\n"
  end

  test "rejects positional and unknown arguments" do
    assert_raise Mix.Error, ~r/invalid extensions.audit arguments/, fn ->
      Audit.run(["baseline"])
    end

    Mix.Task.reenable("extensions.audit")

    assert_raise Mix.Error, ~r/invalid extensions.audit arguments/, fn ->
      Audit.run(["--unknown"])
    end

    Mix.Task.reenable("extensions.audit")

    assert_raise Mix.Error, ~r/extensions.audit --only accepts baseline or budget/, fn ->
      Audit.run(["--only", "unknown"])
    end
  end
end
