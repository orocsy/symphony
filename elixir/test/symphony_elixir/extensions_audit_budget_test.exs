defmodule SymphonyElixir.ExtensionsAuditBudgetTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ExtensionsAudit
  alias SymphonyElixir.ExtensionsAudit.Finding
  import SymphonyElixir.TestSupport.ExtensionsAuditFixture

  @orchestrator "elixir/lib/symphony_elixir/orchestrator.ex"
  @unregistered "elixir/lib/symphony_elixir/unregistered.ex"

  test "accepts zero divergence and ignores new extension-owned files" do
    %{root: root, baseline: baseline} = create_budget_fixture!()
    extension = Path.join(root, "elixir/lib/symphony_elixir/extensions/example.ex")
    File.mkdir_p!(Path.dirname(extension))
    File.write!(extension, "defmodule Fixture.Extension do\nend\n")

    assert {:ok, report} = ExtensionsAudit.verify_budget(root)
    assert report.check == :budget
    assert report.baseline_commit == baseline
    assert report.changed_kernel_files == []
    assert report.changed_lines == 0
    assert report.maximum_changed_lines == 40
  end

  test "rejects malformed nested manifests before invoking Git" do
    %{root: root, baseline: baseline} = create_budget_fixture!()
    valid = File.read!(Path.join(root, "UPSTREAM_PATCH_BUDGET.yml"))

    invalid_sources = [
      String.replace(valid, "schema_version: 1", "schema_version: 1\nschema_version: 1"),
      String.replace(valid, "max_changed_lines: 7", "max_changed_lines: 7\n          max_changed_lines: 7", global: false),
      String.replace(
        valid,
        "hooks:\n",
        "hooks:\n            - id: duplicate\n              id: duplicate\n              max_changed_lines: 1\n              prototype_patch_sha256: #{String.duplicate("a", 64)}\n",
        global: false
      ),
      String.replace(valid, "kernel_root: elixir/lib/symphony_elixir", "kernel_root: ../outside"),
      String.replace(valid, "path: #{@orchestrator}", "path: /tmp/orchestrator.ex"),
      String.replace(valid, "prototype_checkpoint: #{String.duplicate("b", 40)}", "prototype_checkpoint: HEAD"),
      String.replace(valid, "required: false", "required: maybe", global: false),
      String.replace(valid, "baseline_commit: #{baseline}", "baseline_commit: #{String.duplicate("a", 40)}\nunknown: true")
    ]

    Enum.each(invalid_sources, fn source ->
      File.write!(Path.join(root, "UPSTREAM_PATCH_BUDGET.yml"), source)
      git = fn _, _, _ -> flunk("invalid budget manifest reached Git") end

      assert {:error, [%Finding{code: code} | _]} =
               ExtensionsAudit.verify_budget(root, git: git)

      assert code in [
               :budget_manifest_invalid_yaml,
               :budget_manifest_unknown_key,
               :budget_manifest_field_invalid
             ]
    end)
  end

  test "returns typed findings for manifest boundary shapes and unreadable files" do
    %{root: root} = create_budget_fixture!()
    path = Path.join(root, "UPSTREAM_PATCH_BUDGET.yml")
    valid = File.read!(path)
    header = valid |> String.split("files:\n", parts: 2) |> hd()

    hook_block =
      ~r/    hooks:\n      - id: dispatch\.admission_before_worker_selection\n        max_changed_lines: 7\n        prototype_patch_sha256: [0-9a-f]{64}/

    invalid_sources = [
      {:top_sequence, "- baseline\n", :budget_manifest_invalid_yaml},
      {:multiple_documents, "---\n{}\n---\n{}\n", :budget_manifest_invalid_yaml},
      {:empty_sequence, "[]\n", :budget_manifest_invalid_yaml},
      {:missing_schema, String.replace(valid, "schema_version: 1\n", ""), :budget_manifest_field_invalid},
      {:unsupported_schema, String.replace(valid, "schema_version: 1", "schema_version: 2"), :budget_manifest_schema_unsupported},
      {:files_not_list, header <> "files: invalid\n", :budget_manifest_field_invalid},
      {:file_not_mapping, header <> "files:\n  - invalid\n", :budget_manifest_field_invalid},
      {:file_path_not_string, String.replace(valid, "path: #{@orchestrator}", "path: 1", global: false), :budget_manifest_field_invalid},
      {:hooks_not_list, Regex.replace(hook_block, valid, "    hooks: invalid", global: false), :budget_manifest_field_invalid},
      {:hook_not_mapping, Regex.replace(hook_block, valid, "    hooks:\n      - invalid", global: false), :budget_manifest_field_invalid},
      {:invalid_hook_field, String.replace(valid, "      - id: dispatch.admission_before_worker_selection", "      - id: ''"), :budget_manifest_field_invalid},
      {:non_string_duplicate_key,
       String.replace(
         valid,
         "files:\n  - path: #{@orchestrator}",
         "files:\n  - 1: value\n    1: duplicate\n  - path: #{@orchestrator}"
       ), :budget_manifest_invalid_yaml}
    ]

    Enum.each(invalid_sources, fn {label, source, expected_code} ->
      File.write!(path, source)

      assert {:error, [%Finding{code: ^expected_code} | _]} = ExtensionsAudit.verify_budget(root),
             "unexpected result for #{label}"
    end)

    File.rm!(path)
    assert {:error, [%Finding{code: :budget_manifest_missing}]} = ExtensionsAudit.verify_budget(root)

    File.mkdir!(path)

    assert {:error, [%Finding{code: :budget_manifest_unreadable, detail: detail}]} =
             ExtensionsAudit.verify_budget(root)

    assert is_binary(detail)
  end

  test "rejects a budget baseline that differs from UPSTREAM_BASE" do
    %{root: root} = create_budget_fixture!()

    write_budget_manifest!(root, String.duplicate("a", 40))

    assert {:error,
            [
              %Finding{
                code: :budget_baseline_mismatch,
                field: "baseline_commit"
              }
            ]} = ExtensionsAudit.verify_budget(root)
  end

  test "rejects dirty registered and unregistered pinned-kernel changes" do
    %{root: root} = create_budget_fixture!()

    File.write!(Path.join(root, @unregistered), "defmodule Fixture.Unregistered do\n  def changed, do: true\nend\n")

    assert {:error, findings} = ExtensionsAudit.verify_budget(root)
    assert Enum.any?(findings, &match?(%Finding{code: :kernel_path_unregistered, field: @unregistered}, &1))

    File.write!(Path.join(root, @unregistered), "defmodule Fixture.Unregistered do\nend\n")
    File.write!(Path.join(root, @orchestrator), "defmodule Fixture.Orchestrator do\n  def changed, do: true\nend\n")

    assert {:error, findings} = ExtensionsAudit.verify_budget(root)
    assert Enum.any?(findings, &match?(%Finding{code: :kernel_patch_fingerprint_mismatch, field: @orchestrator}, &1))
  end

  test "rejects a staged kernel patch hidden by baseline worktree content" do
    %{root: root, baseline: baseline, files: files} = create_budget_fixture!()
    target = Path.join(root, @orchestrator)

    File.write!(target, "defmodule Fixture.Orchestrator do\n  def hidden, do: :unsafe\nend\n")
    git!(root, ["add", @orchestrator])
    File.write!(target, files[@orchestrator])

    assert {:error, findings} = ExtensionsAudit.verify_budget(root)
    assert Enum.any?(findings, &match?(%Finding{code: :kernel_patch_fingerprint_mismatch, field: @orchestrator}, &1))

    File.write!(target, "defmodule Fixture.Orchestrator do\n  def hook, do: :continue\nend\n")
    fingerprint = patch_sha256!(root, @orchestrator)
    write_budget_manifest!(root, baseline, %{String.duplicate("d", 64) => fingerprint})
    git!(root, ["add", @orchestrator])

    assert {:ok, report} = ExtensionsAudit.verify_budget(root)
    assert report.changed_kernel_files == [@orchestrator]
    assert report.changed_lines == 1

    File.write!(target, files[@orchestrator])

    assert {:ok, report} = ExtensionsAudit.verify_budget(root)
    assert report.changed_kernel_files == [@orchestrator]
    assert report.changed_lines == 1
  end

  test "accepts an exact registered patch and rejects a different patch below the ceiling" do
    %{root: root, baseline: baseline} = create_budget_fixture!()
    target = Path.join(root, @orchestrator)
    File.write!(target, "defmodule Fixture.Orchestrator do\n  def hook, do: :continue\nend\n")
    fingerprint = patch_sha256!(root, @orchestrator)

    write_budget_manifest!(root, baseline, %{String.duplicate("d", 64) => fingerprint})

    assert {:ok, report} = ExtensionsAudit.verify_budget(root)
    assert report.changed_kernel_files == [@orchestrator]
    assert report.changed_lines == 1

    File.write!(target, "defmodule Fixture.Orchestrator do\n  def hook, do: :stop\nend\n")

    assert {:error, findings} = ExtensionsAudit.verify_budget(root)
    assert Enum.any?(findings, &match?(%Finding{code: :kernel_patch_fingerprint_mismatch}, &1))
    refute Enum.any?(findings, &match?(%Finding{code: :kernel_file_budget_exceeded}, &1))
  end

  test "rejects file and total line-budget overflow even with matching fingerprints" do
    %{root: root, baseline: baseline} = create_budget_fixture!()
    target = Path.join(root, @orchestrator)
    File.write!(target, "defmodule Fixture.Orchestrator do\n  def one, do: 1\n  def two, do: 2\nend\n")
    fingerprint = patch_sha256!(root, @orchestrator)

    write_budget_manifest!(root, baseline, %{
      String.duplicate("d", 64) => fingerprint,
      "max_changed_lines: 7" => "max_changed_lines: 1",
      "total_max_changed_lines: 40" => "total_max_changed_lines: 1"
    })

    assert {:error, findings} = ExtensionsAudit.verify_budget(root)
    assert Enum.any?(findings, &match?(%Finding{code: :kernel_file_budget_exceeded}, &1))
    assert Enum.any?(findings, &match?(%Finding{code: :kernel_total_budget_exceeded}, &1))
  end

  test "rejects deletion, direct Orocsy dependency, and absent required patches" do
    %{root: root, baseline: baseline} = create_budget_fixture!()
    target = Path.join(root, @orchestrator)

    File.rm!(target)
    assert {:error, findings} = ExtensionsAudit.verify_budget(root)
    assert Enum.any?(findings, &match?(%Finding{code: :kernel_file_deleted}, &1))

    File.write!(target, "defmodule Fixture.Orchestrator do\nend\n")

    write_budget_manifest!(root, baseline, %{"required: false" => "required: true"})
    assert {:error, findings} = ExtensionsAudit.verify_budget(root)
    assert Enum.any?(findings, &match?(%Finding{code: :kernel_required_hook_missing}, &1))

    File.write!(target, "defmodule Fixture.Orchestrator do\n  alias SymphonyElixir.Orocsy.Policy\nend\n")
    fingerprint = patch_sha256!(root, @orchestrator)

    write_budget_manifest!(root, baseline, %{String.duplicate("d", 64) => fingerprint})
    assert {:error, findings} = ExtensionsAudit.verify_budget(root)
    assert Enum.any?(findings, &match?(%Finding{code: :kernel_direct_orocsy_dependency}, &1))
  end

  test "uses only the budget Git allowlist and sanitizes command failures" do
    %{root: root} = create_budget_fixture!()

    git = fn executable, args, opts ->
      send(self(), {:git_invocation, args})
      System.cmd(executable, args, opts)
    end

    assert {:ok, _report} = ExtensionsAudit.verify_budget(root, git: git)
    invocations = collect_invocations([])
    assert Enum.all?(invocations, &(Enum.at(&1, 2) in ~w(rev-parse cat-file ls-tree diff)))

    failing_git = fn _executable, _args, _opts -> {"fatal: /private/operator/repo", 128} end

    assert {:error, [%Finding{code: :budget_git_unavailable, detail: detail}]} =
             ExtensionsAudit.verify_budget(root, git: failing_git)

    refute detail =~ "/private/operator/repo"
  end

  test "fails closed on mismatched, unavailable, and malformed Git evidence" do
    %{root: root} = create_budget_fixture!()

    wrong_root_git = fn executable, args, opts ->
      if Enum.take(args, -2) == ["rev-parse", "--show-toplevel"] do
        {"/different/repository\n", 0}
      else
        System.cmd(executable, args, opts)
      end
    end

    assert {:error, [%Finding{code: :budget_git_unavailable}]} =
             ExtensionsAudit.verify_budget(root, git: wrong_root_git)

    missing_git = fn _executable, _args, _opts -> :erlang.error(:enoent) end

    assert {:error, [%Finding{code: :budget_git_unavailable, detail: "git executable not found on PATH"}]} =
             ExtensionsAudit.verify_budget(root, git: missing_git)

    for output <- [
          "R100\told.ex\tnew.ex\n",
          "M\t#{@orchestrator}\nM\t#{@orchestrator}\n"
        ] do
      malformed_git = fn executable, args, opts ->
        if "--name-status" in args do
          {output, 0}
        else
          System.cmd(executable, args, opts)
        end
      end

      assert {:error, [%Finding{code: :budget_git_unavailable}]} =
               ExtensionsAudit.verify_budget(root, git: malformed_git)
    end
  end

  test "rejects registered paths absent from the pinned kernel tree" do
    %{root: root, baseline: baseline} = create_budget_fixture!()
    missing = "elixir/lib/symphony_elixir/missing.ex"
    write_budget_manifest!(root, baseline, %{@orchestrator => missing})

    assert {:error, findings} = ExtensionsAudit.verify_budget(root)
    assert Enum.any?(findings, &match?(%Finding{code: :budget_manifest_field_invalid, field: ^missing}, &1))
  end

  test "rejects binary and malformed numstat evidence without reading a patch" do
    %{root: root} = create_budget_fixture!()
    target = Path.join(root, @orchestrator)
    File.write!(target, <<0, 1, 2, 3>>)

    for numstat <- [
          "-\t-\t#{@orchestrator}\n",
          "1\tbogus\t#{@orchestrator}\n",
          "1\t0\twrong.ex\n",
          "",
          "1\t0\t#{@orchestrator}\n1\t0\t#{@orchestrator}\n"
        ] do
      git = fn executable, args, opts ->
        if "--numstat" in args do
          {numstat, 0}
        else
          System.cmd(executable, args, opts)
        end
      end

      assert {:error, findings} = ExtensionsAudit.verify_budget(root, git: git)

      if String.starts_with?(numstat, "-\t-") do
        assert [%Finding{code: :kernel_patch_binary, field: @orchestrator}] = findings
      else
        assert [%Finding{code: :budget_git_unavailable, field: "git"}] = findings
      end
    end
  end

  test "rejects duplicate file paths and hook IDs before invoking Git" do
    %{root: root} = create_budget_fixture!()
    source = File.read!(Path.join(root, "UPSTREAM_PATCH_BUDGET.yml"))
    duplicate_path = String.replace(source, "path: elixir/lib/symphony_elixir/agent_runner.ex", "path: #{@orchestrator}")

    duplicate_hook =
      String.replace(
        source,
        "id: delivery.workspace_ready_before_model",
        "id: dispatch.admission_before_worker_selection"
      )

    Enum.each([duplicate_path, duplicate_hook], fn invalid ->
      File.write!(Path.join(root, "UPSTREAM_PATCH_BUDGET.yml"), invalid)

      assert {:error, [%Finding{code: :budget_manifest_field_invalid} | _]} =
               ExtensionsAudit.verify_budget(root, git: fn _, _, _ -> flunk("duplicates reached Git") end)
    end)
  end

  defp collect_invocations(acc) do
    receive do
      {:git_invocation, args} -> collect_invocations([args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
