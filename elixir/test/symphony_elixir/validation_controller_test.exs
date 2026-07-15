defmodule SymphonyElixir.ValidationControllerTest do
  use ExUnit.Case

  alias SymphonyElixir.{
    ControllerEvidence,
    HandoffCertificate,
    HandoffController,
    Linear.Issue,
    RuntimeContract,
    ValidationController
  }

  test "certifies a clean micro commit after runtime-controlled validation" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      assert {:ok, certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      assert certificate["event"] == "miu.completed"
      assert certificate["authority"] == "symphony.runtime.validation-controller"
      assert is_binary(certificate["base_head_sha"])
      assert certificate["changed_paths"] == ["README.md"]
      assert length(certificate["validation_event_ids"]) == 1

      assert File.regular?(Path.join(workspace, ".orocsy/delivery/state/miu-certificates/COD-700-MIU-1.json"))
    after
      File.rm_rf(workspace)
    end
  end

  test "certifies pushed review rework from the preserved dispatch baseline" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      base_sha = git_output!(workspace, ["rev-parse", "main"])
      git!(workspace, ["remote", "add", "origin", "https://example.test/orocsy/symphony.git"])
      git!(workspace, ["update-ref", "refs/remotes/origin/orocsy/cod-700", "HEAD"])

      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)
      {:ok, compiled} = RuntimeContract.compile(issue.description)

      File.write!(
        Path.join(state_dir, "dispatch-preflight.json"),
        Jason.encode!(
          ControllerEvidence.sign(%{
            "mode" => "review_rework",
            "issue_id" => issue.id,
            "issue" => issue.identifier,
            "branch" => "orocsy/cod-700",
            "contract_hash" => compiled.contract_hash,
            "issue_revision" => RuntimeContract.issue_revision(issue.description, issue.updated_at),
            "certification_base_sha" => base_sha
          })
        )
      )

      assert {:ok, certificate} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert certificate["base_head_sha"] == base_sha
      assert certificate["changed_paths"] == ["README.md"]
    after
      File.rm_rf(workspace)
    end
  end

  test "rejects a tampered dispatch certification baseline" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      base_sha = git_output!(workspace, ["rev-parse", "main"])
      File.write!(Path.join(workspace, "SECRET.md"), "out of scope\n")
      git!(workspace, ["add", "SECRET.md"])
      git!(workspace, ["commit", "-m", "Out of scope checkpoint"])
      hidden_sha = git_output!(workspace, ["rev-parse", "HEAD"])
      commit_readme!(workspace, "Allowed suffix")
      {:ok, compiled} = RuntimeContract.compile(issue.description)

      preflight =
        ControllerEvidence.sign(%{
          "mode" => "review_rework",
          "issue_id" => issue.id,
          "issue" => issue.identifier,
          "branch" => "orocsy/cod-700",
          "contract_hash" => compiled.contract_hash,
          "issue_revision" => RuntimeContract.issue_revision(issue.description, issue.updated_at),
          "certification_base_sha" => base_sha
        })
        |> Map.put("certification_base_sha", hidden_sha)

      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)
      File.write!(Path.join(state_dir, "dispatch-preflight.json"), Jason.encode!(preflight))

      assert {:error, {:invalid_dispatch_preflight, :invalid_controller_signature}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
    after
      File.rm_rf(workspace)
    end
  end

  test "fails closed when a signed certification baseline is not an ancestor" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      {:ok, compiled} = RuntimeContract.compile(issue.description)
      missing_base_sha = String.duplicate("a", 40)
      head_sha = git_output!(workspace, ["rev-parse", "HEAD"])

      preflight =
        ControllerEvidence.sign(%{
          "mode" => "review_rework",
          "issue_id" => issue.id,
          "issue" => issue.identifier,
          "branch" => "orocsy/cod-700",
          "contract_hash" => compiled.contract_hash,
          "issue_revision" => RuntimeContract.issue_revision(issue.description, issue.updated_at),
          "certification_base_sha" => missing_base_sha
        })

      state_dir = Path.join(workspace, ".orocsy/delivery/state")
      File.mkdir_p!(state_dir)
      File.write!(Path.join(state_dir, "dispatch-preflight.json"), Jason.encode!(preflight))

      assert {:error, {:dispatch_certification_base_not_ancestor, ^missing_base_sha, ^head_sha}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
    after
      File.rm_rf(workspace)
    end
  end

  test "ignores untracked runtime ledger files during cleanliness checks" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures", exclude_orocsy?: false)

    try do
      File.mkdir_p!(Path.join(workspace, ".orocsy/delivery"))
      File.write!(Path.join(workspace, ".orocsy/delivery/runtime.json"), "{}\n")

      assert {:ok, certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      assert certificate["changed_paths"] == ["README.md"]
    after
      File.rm_rf(workspace)
    end
  end

  test "matches wildcard write scope against deleted paths" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures", implementation: :delete_doc)

    issue = %{
      issue
      | description: String.replace(issue.description, "- README.md", "- docs/**")
    }

    try do
      assert {:ok, certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      assert certificate["changed_paths"] == ["docs/old.md"]
    after
      File.rm_rf(workspace)
    end
  end

  test "parses pytest normal success summary" do
    {workspace, issue} = workspace_and_issue("3 passed in 0.12s")

    try do
      assert {:ok, certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      assert length(certificate["validation_event_ids"]) == 1
    after
      File.rm_rf(workspace)
    end
  end

  test "treats zero-test Python unittest output as a failed test validation" do
    {workspace, issue} = workspace_and_issue("Ran 0 tests in 0.001s")

    try do
      issue = %{
        issue
        | description:
            issue.description
            |> String.replace("- ./fake-test", "- ./fake-test -m unittest test_empty.py")
      }

      assert {:error, {:validation_failed, result}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert result["reason_class"] == "zero_tests_collected"
      assert result["tests"]["collected"] == 0
    after
      File.rm_rf(workspace)
    end
  end

  test "parses Jest success summaries" do
    {workspace, issue} = workspace_and_issue("Tests: \e[32m3 passed\e[0m, 3 total")

    try do
      assert {:ok, certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      assert length(certificate["validation_event_ids"]) == 1
    after
      File.rm_rf(workspace)
    end
  end

  test "treats colon-suffixed test scripts as test commands" do
    {workspace, issue} = workspace_and_issue("setup complete")

    issue = %{
      issue
      | description:
          issue.description
          |> String.replace("- ./fake-test", "- TEST_LABEL=test:unit ./fake-test")
    }

    try do
      assert {:error, {:validation_failed, result}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert result["reason_class"] == "test_count_unavailable"
    after
      File.rm_rf(workspace)
    end
  end

  test "rejects writes covered by denied scope even when broad write scope allows them" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    issue = %{
      issue
      | description:
          issue.description
          |> String.replace("- README.md", "- \"**\"")
          |> String.replace("dependencies: []", "dependencies: []\ndenied_scope:\n  - README.md")
    }

    try do
      assert {:error, {:denied_scope_write, ["README.md"]}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
    after
      File.rm_rf(workspace)
    end
  end

  test "rejects a denied path when the audited range also contains allowed paths" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    issue = %{
      issue
      | description:
          issue.description
          |> String.replace("- README.md", "- \"**\"")
          |> String.replace("dependencies: []", "dependencies: []\ndenied_scope:\n  - README.md")
    }

    try do
      File.write!(Path.join(workspace, "ALLOWED.md"), "# Allowed\n")
      git!(workspace, ["add", "ALLOWED.md"])
      git!(workspace, ["commit", "-m", "Add allowed companion file"])

      assert {:error, {:denied_scope_write, changed_paths}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert Enum.sort(changed_paths) == ["ALLOWED.md", "README.md"]
    after
      File.rm_rf(workspace)
    end
  end

  test "audits all uncertified commits instead of only the current head commit" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      File.write!(Path.join(workspace, "OUTSIDE.md"), "# Outside\n")
      git!(workspace, ["add", "OUTSIDE.md"])
      git!(workspace, ["commit", "-m", "Add out-of-scope checkpoint"])
      commit_readme!(workspace, "Final allowed checkpoint")

      assert {:error, {:undeclared_write, changed_paths}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert Enum.sort(changed_paths) == ["OUTSIDE.md", "README.md"]
    after
      File.rm_rf(workspace)
    end
  end

  test "certifies each MIU against the prior signed checkpoint" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")
    issue = add_second_miu(issue)

    try do
      assert {:ok, first_certificate} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      File.write!(Path.join(workspace, "SECOND.md"), "# Second MIU\n")
      git!(workspace, ["add", "SECOND.md"])
      git!(workspace, ["commit", "-m", "Implement second MIU"])

      assert {:ok, second_certificate} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-2")

      assert second_certificate["base_head_sha"] == first_certificate["head_sha"]
      assert second_certificate["changed_paths"] == ["SECOND.md"]
    after
      File.rm_rf(workspace)
    end
  end

  test "runs validation commands with leading environment assignments" do
    {workspace, issue} =
      workspace_and_issue("3 tests, 0 failures",
        script_body: "#!/bin/sh\n[ \"$NB_SENTINEL\" = ok ] || exit 9\necho '3 tests, 0 failures'\n"
      )

    issue = %{
      issue
      | description: String.replace(issue.description, "- ./fake-test", "- NB_SENTINEL=ok ./fake-test")
    }

    try do
      assert {:ok, certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      assert certificate["miu_id"] == "COD-700-MIU-1"
    after
      File.rm_rf(workspace)
    end
  end

  test "does not sign a MIU when validation leaves the worktree dirty" do
    {workspace, issue} =
      workspace_and_issue("3 tests, 0 failures",
        script_body: "#!/bin/sh\necho dirty > DIRTY.md\necho '3 tests, 0 failures'\n"
      )

    try do
      assert {:error, :validation_left_dirty_worktree} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      refute File.regular?(Path.join(workspace, ".orocsy/delivery/state/miu-certificates/COD-700-MIU-1.json"))
    after
      File.rm_rf(workspace)
    end
  end

  test "zero-test output fails once and unchanged fingerprint does not rerun" do
    {workspace, issue} = workspace_and_issue("0 tests, 0 failures")

    try do
      assert {:error, {:validation_failed, first}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert first["reason_class"] == "zero_tests_collected"

      assert {:blocked, {:unchanged_failed_validation, fingerprint}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert fingerprint == first["validation_fingerprint"]
    after
      File.rm_rf(workspace)
    end
  end

  test "processes worker requests through MIU certification and final handoff" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      append_event!(workspace, issue, %{
        "event" => "miu.completion_requested",
        "status" => "requested",
        "miu_id" => "COD-700-MIU-1"
      })

      assert {:ok, miu_certificate} = ValidationController.process_requests(issue, workspace)
      assert miu_certificate["miu_id"] == "COD-700-MIU-1"

      push_to_local_origin!(workspace)

      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})

      assert {:ok, handoff} = HandoffController.process_requests(issue, workspace)
      assert handoff["event"] == "handoff.ready"
      assert handoff["completed_mius"] == ["COD-700-MIU-1"]
      assert length(handoff["validation_event_ids"]) == 2
    after
      File.rm_rf(workspace)
    end
  end

  test "does not certify a request made for an older runtime contract" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      append_event!(workspace, issue, %{
        "event" => "miu.completion_requested",
        "status" => "requested",
        "step" => "COD-700-MIU-1"
      })

      changed_issue = %{
        issue
        | description: String.replace(issue.description, "validation_timeout_ms: 900000", "validation_timeout_ms: 800000")
      }

      assert :none = ValidationController.process_requests(changed_issue, workspace)

      assert Enum.any?(events(workspace), fn event ->
               event["event"] == "runtime.request.processed" and
                 event["status"] == "stale" and
                 event["reason"] =~ "request_contract_hash_mismatch"
             end)
    after
      File.rm_rf(workspace)
    end
  end

  test "does not certify handoff requested for an older runtime contract" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      assert {:ok, _certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      push_to_local_origin!(workspace)
      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})

      changed_issue = %{
        issue
        | description: String.replace(issue.description, "validation_timeout_ms: 900000", "validation_timeout_ms: 800000")
      }

      assert :none = HandoffController.process_requests(changed_issue, workspace)

      assert Enum.any?(events(workspace), fn event ->
               event["event"] == "runtime.request.processed" and
                 event["status"] == "stale" and
                 event["reason"] =~ "request_contract_hash_mismatch"
             end)
    after
      File.rm_rf(workspace)
    end
  end

  test "does not sign a MIU when validation changes HEAD but leaves the worktree clean" do
    {workspace, issue} =
      workspace_and_issue("3 tests, 0 failures",
        script_body: "#!/bin/sh\ngit commit --allow-empty -m validation-mutated-head >/dev/null\necho '3 tests, 0 failures'\n"
      )

    try do
      original_head = git_output!(workspace, ["rev-parse", "HEAD"])

      assert {:error, {:validation_changed_head, ^original_head, changed_head}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      refute changed_head == original_head
      refute File.regular?(Path.join(workspace, ".orocsy/delivery/state/miu-certificates/COD-700-MIU-1.json"))
    after
      File.rm_rf(workspace)
    end
  end

  test "detects worktree mutation even when validation exits non-zero" do
    {workspace, issue} =
      workspace_and_issue("unused",
        script_body: "#!/bin/sh\necho dirty > DIRTY.md\necho '3 tests, 0 failures'\nexit 1\n"
      )

    try do
      assert {:error, :validation_left_dirty_worktree} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      refute File.regular?(Path.join(workspace, ".orocsy/delivery/state/miu-certificates/COD-700-MIU-1.json"))
    after
      File.rm_rf(workspace)
    end
  end

  test "stops a validation sequence immediately after a command changes HEAD" do
    {workspace, issue} =
      workspace_and_issue("3 tests, 0 failures",
        script_body: "#!/bin/sh\ngit commit --allow-empty -m validation-mutated-head >/dev/null\necho '3 tests, 0 failures'\n"
      )

    try do
      File.write!(Path.join(workspace, "must-not-run"), "#!/bin/sh\ntouch SECOND_VALIDATION_RAN\necho '3 tests, 0 failures'\n")
      File.chmod!(Path.join(workspace, "must-not-run"), 0o755)
      git!(workspace, ["add", "must-not-run"])
      git!(workspace, ["commit", "-m", "Add second validation command"])

      issue = %{
        issue
        | description:
            issue.description
            |> String.replace("- README.md", "- \"**\"")
            |> String.replace(
              "validations:\n      - ./fake-test",
              "validations:\n      - ./fake-test\n      - ./must-not-run"
            )
      }

      assert {:error, {:validation_changed_head, _original_head, _changed_head}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      refute File.exists?(Path.join(workspace, "SECOND_VALIDATION_RAN"))
    after
      File.rm_rf(workspace)
    end
  end

  test "does not accept final validation that changes HEAD" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      assert {:ok, _certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      final_script = Path.join(workspace, "final-test")
      File.write!(final_script, "#!/bin/sh\ngit commit --allow-empty -m final-validation-mutated-head >/dev/null\necho '3 tests, 0 failures'\n")
      File.chmod!(final_script, 0o755)
      git!(workspace, ["add", "final-test"])
      git!(workspace, ["commit", "-m", "Add final validation command"])

      issue = %{
        issue
        | description:
            String.replace(
              issue.description,
              "final_validations:\n  - ./fake-test",
              "final_validations:\n  - ./final-test"
            )
      }

      original_head = git_output!(workspace, ["rev-parse", "HEAD"])

      assert {:error, {:validation_changed_head, ^original_head, changed_head}} =
               ValidationController.validate_final(issue, workspace)

      refute changed_head == original_head
    after
      File.rm_rf(workspace)
    end
  end

  test "ignores unsigned validation attempts when applying replay and retry guards" do
    {workspace, issue} = workspace_and_issue("0 tests, 0 failures")

    try do
      assert {:error, {:validation_failed, first}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      attempts_path = Path.join(workspace, ".orocsy/delivery/state/validation-attempts.jsonl")
      unsigned = Map.delete(first, "controller_signature")
      File.write!(attempts_path, Jason.encode!(unsigned) <> "\n")

      assert {:error, {:validation_failed, second}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert second["validation_fingerprint"] == first["validation_fingerprint"]
      assert second["controller_signature"]
    after
      File.rm_rf(workspace)
    end
  end

  test "changed-code validation failures exhaust the two-fix-cycle budget" do
    {workspace, issue} = workspace_and_issue("0 tests, 0 failures")

    try do
      assert {:error, {:validation_failed, _first}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      commit_readme!(workspace, "First repair")

      assert {:error, {:validation_failed, _second}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      commit_readme!(workspace, "Second repair")

      assert {:blocked, {:product_fix_budget_exhausted, "COD-700-MIU-1"}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
    after
      File.rm_rf(workspace)
    end
  end

  test "infrastructure failures do not consume or trigger the product fix budget" do
    {workspace, issue} = workspace_and_issue("0 tests, 0 failures")
    issue = %{issue | description: String.replace(issue.description, "- README.md", "- \"**\"")}

    try do
      assert {:error, {:validation_failed, _first}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      commit_readme!(workspace, "First repair")

      assert {:error, {:validation_failed, _second}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      File.rm!(Path.join(workspace, "fake-test"))
      git!(workspace, ["add", "fake-test"])
      git!(workspace, ["commit", "-m", "Simulate missing validation executable"])

      assert {:error, {:validation_failed, timeout}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert timeout["reason_class"] == "command_launch_failed"

      File.write!(Path.join(workspace, "fake-test"), "#!/bin/sh\necho '0 tests, 0 failures'\n")
      File.chmod!(Path.join(workspace, "fake-test"), 0o755)
      File.write!(Path.join(workspace, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n")
      git!(workspace, ["add", "fake-test", "pnpm-lock.yaml"])
      git!(workspace, ["commit", "-m", "Restore product validation failure"])

      assert {:blocked, {:product_fix_budget_exhausted, "COD-700-MIU-1"}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
    after
      File.rm_rf(workspace)
    end
  end

  test "classifies an unavailable validation executable as infrastructure" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    issue = %{
      issue
      | description:
          issue.description
          |> String.replace("- README.md", "- \"**\"")
          |> String.replace("- ./fake-test", "- ./missing-validation-executable")
    }

    try do
      assert {:error, {:validation_failed, first}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert first["reason_class"] == "command_launch_failed"

      commit_readme!(workspace, "Product change cannot retry unchanged infrastructure")

      assert {:blocked, {:unchanged_infrastructure_environment, "COD-700-MIU-1"}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      File.write!(Path.join(workspace, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n")
      git!(workspace, ["add", "pnpm-lock.yaml"])
      git!(workspace, ["commit", "-m", "Refresh validation environment"])

      assert {:error, {:validation_failed, second}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert second["reason_class"] == "command_launch_failed"
      refute second["environment_fingerprint"] == first["environment_fingerprint"]

      File.write!(Path.join(workspace, "pnpm-lock.yaml"), "lockfileVersion: '9.1'\n")
      git!(workspace, ["add", "pnpm-lock.yaml"])
      git!(workspace, ["commit", "-m", "Refresh validation environment again"])

      assert {:blocked, {:infrastructure_retry_budget_exhausted, "COD-700-MIU-1"}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
    after
      File.rm_rf(workspace)
    end
  end

  test "does not reuse a processed completion request after the head changes" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      append_event!(workspace, issue, %{
        "event" => "miu.completion_requested",
        "status" => "requested",
        "step" => "COD-700-MIU-1"
      })

      assert {:ok, _certificate} = ValidationController.process_requests(issue, workspace)
      commit_readme!(workspace, "Later unrelated checkpoint")
      assert :none = ValidationController.process_requests(issue, workspace)
    after
      File.rm_rf(workspace)
    end
  end

  test "does not trust a worker-forged processed marker" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      request_id = "worker-request-forgery-test"

      append_event!(workspace, issue, %{
        "event" => "miu.completion_requested",
        "event_id" => request_id,
        "status" => "requested",
        "step" => "COD-700-MIU-1"
      })

      append_event!(workspace, %{
        "event" => "runtime.request.processed",
        "authority" => "symphony.runtime.transition-controller",
        "request_event_id" => request_id,
        "status" => "completed"
      })

      assert {:ok, certificate} = ValidationController.process_requests(issue, workspace)
      assert certificate["miu_id"] == "COD-700-MIU-1"
    after
      File.rm_rf(workspace)
    end
  end

  test "marks an unprocessed request stale when it targets an older head" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      append_event!(workspace, issue, %{
        "event" => "miu.completion_requested",
        "status" => "requested",
        "step" => "COD-700-MIU-1"
      })

      Process.sleep(1_100)
      commit_readme!(workspace, "Checkpoint after request")

      assert :none = ValidationController.process_requests(issue, workspace)

      assert Enum.any?(events(workspace), fn event ->
               event["event"] == "runtime.request.processed" and event["status"] == "stale"
             end)
    after
      File.rm_rf(workspace)
    end
  end

  test "does not trust future request timestamps after the head changes" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      append_event!(workspace, issue, %{
        "event" => "miu.completion_requested",
        "status" => "requested",
        "step" => "COD-700-MIU-1",
        "ts" => DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })

      commit_readme!(workspace, "Later checkpoint")

      assert :none = ValidationController.process_requests(issue, workspace)

      assert Enum.any?(events(workspace), fn event ->
               event["event"] == "runtime.request.processed" and
                 event["status"] == "stale" and
                 event["reason"] =~ "request_head_mismatch"
             end)
    after
      File.rm_rf(workspace)
    end
  end

  test "times out a validation at the contract boundary" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures", delay_seconds: 2, timeout_ms: 1_000)

    try do
      assert {:error, {:validation_failed, result}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert result["reason_class"] == "command_timed_out"
      assert result["timed_out"] == true
      assert result["timeout_ms"] == 1_000
    after
      File.rm_rf(workspace)
    end
  end

  test "ignores a worker-tampered MIU certificate" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      assert {:ok, certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      path = Path.join(workspace, ".orocsy/delivery/state/miu-certificates/COD-700-MIU-1.json")
      File.write!(path, Jason.encode!(Map.put(certificate, "head_sha", "forged-head")))

      assert ValidationController.certificates(workspace) == []
    after
      File.rm_rf(workspace)
    end
  end

  test "does not reuse a signed MIU certificate from another issue as current cache" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      assert {:ok, certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      forged = %{certificate | "issue_id" => "other-issue", "issue" => "COD-701"}
      path = Path.join(workspace, ".orocsy/delivery/state/miu-certificates/COD-700-MIU-1.json")
      File.write!(path, Jason.encode!(SymphonyElixir.ControllerEvidence.sign(forged)))

      assert {:ok, certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      assert certificate["issue_id"] == issue.id
      assert certificate["issue"] == issue.identifier
    after
      File.rm_rf(workspace)
    end
  end

  test "rejects a later MIU until the preceding MIU is certified" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    second_miu = """
      - id: COD-700-MIU-2
        write_scope:
          - README.md
        validations:
          - ./fake-test
    """

    issue = %{
      issue
      | description: String.replace(issue.description, "final_validations:\n", second_miu <> "final_validations:\n")
    }

    try do
      assert {:error, {:miu_out_of_order, "COD-700-MIU-2", "COD-700-MIU-1"}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-2")
    after
      File.rm_rf(workspace)
    end
  end

  test "handoff rejects a signed MIU certificate copied from another issue" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      assert {:ok, _certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      git!(workspace, ["remote", "add", "origin", "https://example.test/orocsy/symphony.git"])
      git!(workspace, ["update-ref", "refs/remotes/origin/orocsy/cod-700", "HEAD"])
      git!(workspace, ["branch", "--set-upstream-to", "origin/orocsy/cod-700"])
      other_issue = %{issue | id: "other-issue-id", identifier: "COD-701"}
      append_event!(workspace, other_issue, %{"event" => "handoff.requested", "status" => "requested"})

      assert ValidationController.certified_miu_ids(issue, workspace) == ["COD-700-MIU-1"]
      assert ValidationController.certified_miu_ids(other_issue, workspace) == []

      assert {:error, {:miu_certificate_issue_mismatch, "COD-700-MIU-1"}} =
               HandoffController.process_requests(other_issue, workspace)
    after
      File.rm_rf(workspace)
    end
  end

  test "handoff rejects commits after the last certified MIU" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      assert {:ok, _certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      File.write!(Path.join(workspace, "README.md"), "# Test\n\nImplemented.\n\nUncertified.\n")
      git!(workspace, ["add", "README.md"])
      git!(workspace, ["commit", "-m", "Uncertified follow-up"])
      git!(workspace, ["remote", "add", "origin", "https://example.test/orocsy/symphony.git"])
      git!(workspace, ["update-ref", "refs/remotes/origin/orocsy/cod-700", "HEAD"])
      git!(workspace, ["branch", "--set-upstream-to", "origin/orocsy/cod-700"])
      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})

      assert {:error, {:uncertified_commits_after_last_miu, _certified_head, _head_sha}} =
               HandoffController.process_requests(issue, workspace)
    after
      File.rm_rf(workspace)
    end
  end

  test "handoff certifies an in-scope review rework delta at the current head" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      assert {:ok, certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      certified_head = certificate["head_sha"]

      write_review_rework_preflight!(workspace, issue)
      commit_readme!(workspace, "Address current-head review feedback")
      review_head = git_output!(workspace, ["rev-parse", "HEAD"])
      push_to_local_origin!(workspace)
      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})

      assert {:ok, handoff} = HandoffController.process_requests(issue, workspace)
      assert handoff["head_sha"] == review_head
      assert handoff["head_sha"] != certified_head
      assert length(handoff["validation_event_ids"]) == 2
    after
      File.rm_rf(workspace)
    end
  end

  test "handoff rejects an out-of-scope review rework delta" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      assert {:ok, _certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      write_review_rework_preflight!(workspace, issue)
      File.write!(Path.join(workspace, "SECRET.md"), "out of scope\n")
      git!(workspace, ["add", "SECRET.md"])
      git!(workspace, ["commit", "-m", "Out-of-scope review change"])
      push_to_local_origin!(workspace)
      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})

      assert {:error, {:undeclared_review_rework_write, ["SECRET.md"]}} =
               HandoffController.process_requests(issue, workspace)
    after
      File.rm_rf(workspace)
    end
  end

  test "handoff rejects a stale review preflight after a newer signed handoff" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      assert {:ok, _certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      write_review_rework_preflight!(workspace, issue)
      commit_readme!(workspace, "First review fix")
      push_to_local_origin!(workspace)
      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})
      assert {:ok, first_handoff} = HandoffController.process_requests(issue, workspace)

      commit_readme!(workspace, "Unrelated later commit")
      git!(workspace, ["push"])
      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})

      assert {:error, :review_rework_dispatch_base_mismatch} =
               HandoffController.process_requests(issue, workspace)

      assert {:ok, signed_head} = HandoffCertificate.latest_signed_head(issue, workspace)
      assert signed_head == first_handoff["head_sha"]
    after
      File.rm_rf(workspace)
    end
  end

  defp workspace_and_issue(test_output, opts \\ []) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-validation-controller-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    git!(workspace, ["init", "-b", "main"])
    git!(workspace, ["config", "user.email", "symphony@example.test"])
    git!(workspace, ["config", "user.name", "Symphony Test"])
    File.write!(Path.join(workspace, "README.md"), "# Test\n")
    implementation = Keyword.get(opts, :implementation, :readme)

    if implementation == :delete_doc do
      File.mkdir_p!(Path.join(workspace, "docs"))
      File.write!(Path.join(workspace, "docs/old.md"), "# Old\n")
    end

    delay_seconds = Keyword.get(opts, :delay_seconds, 0)
    timeout_ms = Keyword.get(opts, :timeout_ms, 900_000)

    script_body =
      Keyword.get(opts, :script_body, "#!/bin/sh\nsleep #{delay_seconds}\necho '#{test_output}'\n")

    File.write!(Path.join(workspace, "fake-test"), script_body)

    File.chmod!(Path.join(workspace, "fake-test"), 0o755)
    git!(workspace, ["add", "."])
    git!(workspace, ["commit", "-m", "Initial"])
    git!(workspace, ["switch", "-c", "orocsy/cod-700"])

    case implementation do
      :delete_doc ->
        File.rm!(Path.join(workspace, "docs/old.md"))
        git!(workspace, ["rm", "docs/old.md"])

      _ ->
        File.write!(Path.join(workspace, "README.md"), "# Test\n\nImplemented.\n")
        git!(workspace, ["add", "README.md"])
    end

    git!(workspace, ["commit", "-m", "Implement micro MIU"])

    if Keyword.get(opts, :exclude_orocsy?, true) do
      File.write!(Path.join(workspace, ".git/info/exclude"), ".orocsy/\n", [:append])
    end

    issue = %Issue{
      id: "issue-cod-700",
      identifier: "COD-700",
      title: "Runtime validation",
      state: "In Progress",
      description: """
      ## Runtime Contract

      ```yaml
      schema_version: 1
      ticket_type: implementation
      base_branch: main
      integration_branch: orocsy/cod-700
      dependencies: []
      mius:
        - id: COD-700-MIU-1
          write_scope:
            - README.md
          validations:
            - ./fake-test
      final_validations:
        - ./fake-test
      validation_timeout_ms: #{timeout_ms}
      review:
        authority: github_codex
        require_current_head: true
      ```
      """
    }

    {workspace, issue}
  end

  defp git!(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp commit_readme!(workspace, label) do
    File.write!(Path.join(workspace, "README.md"), "# Test\n\n#{label}.\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", label])
  end

  defp push_to_local_origin!(workspace) do
    remote = Path.join(workspace, ".git/test-origin.git")
    git!(workspace, ["init", "--bare", remote])
    git!(workspace, ["remote", "add", "origin", remote])
    git!(workspace, ["push", "--set-upstream", "origin", "HEAD"])
    previous_runner = Application.get_env(:symphony_elixir, :handoff_remote_head_runner)

    Application.put_env(:symphony_elixir, :handoff_remote_head_runner, fn branch ->
      case System.cmd("git", ["--git-dir", remote, "rev-parse", "refs/heads/#{branch}"], stderr_to_stdout: true) do
        {head_sha, 0} -> {:ok, %{"repo" => "test/symphony", "head_sha" => String.trim(head_sha)}}
        {output, status} -> {:error, {:remote_ref_failed, status, String.trim(output)}}
      end
    end)

    previous_pr_runner = Application.get_env(:symphony_elixir, :handoff_pull_request_runner)

    Application.put_env(:symphony_elixir, :handoff_pull_request_runner, fn _repo, branch ->
      {:ok,
       %{
         "number" => 700,
         "html_url" => "https://github.com/test/symphony/pull/700",
         "state" => "open",
         "head" => %{"ref" => branch, "sha" => git_output!(workspace, ["rev-parse", "HEAD"])},
         "base" => %{"ref" => "main"}
       }}
    end)

    on_exit(fn -> restore_env(:handoff_remote_head_runner, previous_runner) end)
    on_exit(fn -> restore_env(:handoff_pull_request_runner, previous_pr_runner) end)
  end

  defp write_review_rework_preflight!(workspace, issue) do
    {:ok, compiled} = RuntimeContract.compile(issue.description)
    state_dir = Path.join(workspace, ".orocsy/delivery/state")
    File.mkdir_p!(state_dir)

    preflight =
      ControllerEvidence.sign(%{
        "mode" => "review_rework",
        "issue_id" => issue.id,
        "issue" => issue.identifier,
        "branch" => compiled.contract["integration_branch"],
        "contract_hash" => compiled.contract_hash,
        "issue_revision" => RuntimeContract.issue_revision(issue.description, issue.updated_at),
        "review" => %{"head_sha" => git_output!(workspace, ["rev-parse", "HEAD"])}
      })

    File.write!(Path.join(state_dir, "dispatch-preflight.json"), Jason.encode!(preflight))
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp add_second_miu(%Issue{} = issue) do
    second_miu = """
      - id: COD-700-MIU-2
        write_scope:
          - SECOND.md
        validations:
          - ./fake-test
    final_validations:
    """

    %{issue | description: String.replace(issue.description, "final_validations:\n", second_miu)}
  end

  defp append_event!(workspace, event), do: append_event!(workspace, nil, event)

  defp append_event!(workspace, issue, event) do
    path = Path.join(workspace, ".orocsy/delivery/events/events.jsonl")
    File.mkdir_p!(Path.dirname(path))

    event =
      event
      |> Map.put_new("event_id", "test-event-#{System.unique_integer([:positive])}")
      |> Map.put_new("ts", DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())
      |> maybe_put_head_sha(workspace)
      |> maybe_put_contract_identity(issue)

    File.write!(path, Jason.encode!(event) <> "\n", [:append])
  end

  defp maybe_put_head_sha(%{"event" => event_type} = event, workspace)
       when event_type in ["miu.completion_requested", "handoff.requested"] do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {head_sha, 0} -> Map.put_new(event, "head_sha", String.trim(head_sha))
      _ -> event
    end
  end

  defp maybe_put_head_sha(event, _workspace), do: event

  defp maybe_put_contract_identity(%{"event" => event_type} = event, %Issue{} = issue)
       when event_type in ["miu.completion_requested", "handoff.requested"] do
    {:ok, compiled} = SymphonyElixir.RuntimeContract.compile(issue.description)

    event
    |> Map.put("contract_hash", compiled.contract_hash)
    |> Map.put("issue_revision", SymphonyElixir.RuntimeContract.issue_revision(issue.description, issue.updated_at))
  end

  defp maybe_put_contract_identity(event, _issue), do: event

  defp git_output!(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp events(workspace) do
    workspace
    |> Path.join(".orocsy/delivery/events/events.jsonl")
    |> File.stream!()
    |> Enum.map(&(String.trim(&1) |> Jason.decode!()))
  end
end
