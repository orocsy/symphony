defmodule Mix.Tasks.Extensions.AuditTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Extensions.Audit

  setup do
    Mix.Task.reenable("extensions.audit")
    :ok
  end

  test "runs the baseline check by default and prints stable success output" do
    output =
      capture_io(fn ->
        assert :ok = Audit.run(["--repo-root", repo_root()])
      end)

    assert output ==
             "extensions.audit baseline: ok commit=f8e8b8a670c799f6e0ade7a8c25c4bf4a4a56ec7 tree=37a4c6c184db05cd2d59bfc50943979919ec988a elixir_tree=77d9ba67775e6681eb1ad5cf03a019e678a8e941 first_parent=true\n"
  end

  test "accepts only baseline for --only in OXE-0.1" do
    output =
      capture_io(fn ->
        assert :ok = Audit.run(["--only", "baseline", "--repo-root", repo_root()])
      end)

    assert output =~ "extensions.audit baseline: ok"

    Mix.Task.reenable("extensions.audit")

    assert_raise Mix.Error, ~r/--only accepts only baseline/, fn ->
      Audit.run(["--only", "budget", "--repo-root", repo_root()])
    end
  end

  test "resolves the default root from the Mix project file" do
    output = capture_io(fn -> assert :ok = Audit.run([]) end)

    assert output =~ "extensions.audit baseline: ok"
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

    assert error_output ==
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
  end

  defp repo_root, do: Path.expand("../../../..", __DIR__)

  defp create_root!(manifest) do
    root = Path.join(System.tmp_dir!(), "extensions-audit-task-test-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "UPSTREAM_BASE.yml"), manifest)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
