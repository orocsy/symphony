defmodule SymphonyElixir.ValidationControllerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{
    ControllerEvidence,
    DispatchPreflight,
    HandoffCertificate,
    HandoffController,
    Linear.Issue,
    RuntimeContract,
    ValidationController,
    Workspace
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

  test "parses Playwright success summary" do
    {workspace, issue} = workspace_and_issue("Running 1 test using 1 worker\n  1 passed (29.1s)")

    try do
      assert {:ok, certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      assert length(certificate["validation_event_ids"]) == 1
    after
      File.rm_rf(workspace)
    end
  end

  test "parses Playwright success summary with a minute duration" do
    {workspace, issue} = workspace_and_issue("77 passed (1.2m)")

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

  test "environment changes do not bypass a product failure at the same code identity" do
    env_key = "SYMPHONY_VALIDATION_TEST_API_KEY"
    previous_value = System.get_env(env_key)
    System.delete_env(env_key)
    {workspace, issue} = workspace_and_issue("0 tests, 0 failures")

    try do
      assert {:error, {:validation_failed, first}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      System.put_env(env_key, "new-environment-value")

      assert {:blocked, {:unchanged_failed_validation, fingerprint}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert fingerprint == first["validation_fingerprint"]
    after
      restore_env(env_key, previous_value)
      File.rm_rf(workspace)
    end
  end

  test "redacts inherited secret values from validation evidence" do
    env_key = "SYMPHONY_VALIDATION_TEST_API_KEY"
    secret_value = "tests"
    previous_value = System.get_env(env_key)
    System.put_env(env_key, secret_value)

    {workspace, issue} =
      workspace_and_issue("3 tests, 0 failures",
        script_body: "#!/bin/sh\necho \"$#{env_key}\"\necho '3 tests, 0 failures'\n"
      )

    try do
      assert {:ok, certificate} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      [event_id] = certificate["validation_event_ids"]

      event =
        workspace
        |> Path.join(".orocsy/delivery/events/events.jsonl")
        |> File.stream!()
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["event_id"] == event_id))

      evidence = File.read!(Path.join(workspace, event["bounded_log_path"]))
      refute evidence =~ secret_value
      assert evidence =~ "[REDACTED:#{env_key}]"
    after
      restore_env(env_key, previous_value)
      File.rm_rf(workspace)
    end
  end

  test "redacts short inherited secret values at token boundaries" do
    env_key = "SYMPHONY_VALIDATION_TEST_TOKEN"
    secret_value = "abc"
    previous_value = System.get_env(env_key)
    System.put_env(env_key, secret_value)

    {workspace, issue} =
      workspace_and_issue("3 tests, 0 failures",
        script_body: "#!/bin/sh\necho \"token=$#{env_key}\"\necho '3 tests, 0 failures'\n"
      )

    try do
      assert {:ok, certificate} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      [event_id] = certificate["validation_event_ids"]

      event =
        workspace
        |> Path.join(".orocsy/delivery/events/events.jsonl")
        |> File.stream!()
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["event_id"] == event_id))

      evidence = File.read!(Path.join(workspace, event["bounded_log_path"]))
      refute evidence =~ "token=#{secret_value}"
      assert evidence =~ "token=[REDACTED:#{env_key}]"
    after
      restore_env(env_key, previous_value)
      File.rm_rf(workspace)
    end
  end

  test "redacts overlapping auth and token values longest-first" do
    short_key = "SYMPHONY_VALIDATION_TEST_TOKEN"
    long_key = "NPM_CONFIG__AUTH"
    previous_short = System.get_env(short_key)
    previous_long = System.get_env(long_key)
    System.put_env(short_key, "abcd")
    System.put_env(long_key, "abcdef")

    {workspace, issue} =
      workspace_and_issue("3 tests, 0 failures",
        script_body: "#!/bin/sh\necho \"auth=$#{long_key}\"\necho '3 tests, 0 failures'\n"
      )

    try do
      assert {:ok, certificate} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      [event_id] = certificate["validation_event_ids"]

      event =
        workspace
        |> Path.join(".orocsy/delivery/events/events.jsonl")
        |> File.stream!()
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["event_id"] == event_id))

      evidence = File.read!(Path.join(workspace, event["bounded_log_path"]))
      refute evidence =~ "abcdef"
      refute evidence =~ "[REDACTED:#{short_key}]ef"
      assert evidence =~ "auth=[REDACTED:#{long_key}]"
    after
      restore_env(short_key, previous_short)
      restore_env(long_key, previous_long)
      File.rm_rf(workspace)
    end
  end

  test "redacts database URLs and access-key identifiers" do
    database_key = "DATABASE_URL"
    access_key = "MEDIA_ACCESS_KEY_ID"
    previous_database = System.get_env(database_key)
    previous_access = System.get_env(access_key)
    System.put_env(database_key, "postgres://user:password@example.test/db")
    System.put_env(access_key, "media-access-123")

    {workspace, issue} =
      workspace_and_issue("3 tests, 0 failures",
        script_body: "#!/bin/sh\necho \"database=$#{database_key}\"\necho \"access=$#{access_key}\"\necho '3 tests, 0 failures'\n"
      )

    try do
      assert {:ok, certificate} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      [event_id] = certificate["validation_event_ids"]

      event =
        workspace
        |> Path.join(".orocsy/delivery/events/events.jsonl")
        |> File.stream!()
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["event_id"] == event_id))

      evidence = File.read!(Path.join(workspace, event["bounded_log_path"]))
      refute evidence =~ "postgres://"
      refute evidence =~ "media-access-123"
      assert evidence =~ "database=[REDACTED:#{database_key}]"
      assert evidence =~ "access=[REDACTED:#{access_key}]"
    after
      restore_env(database_key, previous_database)
      restore_env(access_key, previous_access)
      File.rm_rf(workspace)
    end
  end

  test "redacts repeated secrets across the retained capture boundary" do
    env_key = "SYMPHONY_VALIDATION_TEST_TOKEN"
    secret_value = "capture-boundary-secret-value"
    previous_value = System.get_env(env_key)
    System.put_env(env_key, secret_value)
    capture_marker = "...[earlier output truncated]...\n"
    summary = "\n3 tests, 0 failures\n"
    retained_bytes = 1_000_000 - byte_size(capture_marker)

    suffix_bytes =
      retained_bytes - div(byte_size(secret_value), 2) - byte_size(secret_value) - byte_size(summary)

    {workspace, issue} =
      workspace_and_issue("3 tests, 0 failures",
        script_body: "#!/bin/sh\nprintf 'prefix'\nprintf '%s' \"$#{env_key}\"\nhead -c #{suffix_bytes} /dev/zero | tr '\\000' x\nprintf '%s' \"$#{env_key}\"\nprintf '#{summary}'\n"
      )

    try do
      assert {:ok, certificate} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      [event_id] = certificate["validation_event_ids"]

      event =
        workspace
        |> Path.join(".orocsy/delivery/events/events.jsonl")
        |> File.stream!()
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["event_id"] == event_id))

      evidence = File.read!(Path.join(workspace, event["bounded_log_path"]))
      refute evidence =~ String.slice(secret_value, div(byte_size(secret_value), 2)..-1//1)
      assert evidence =~ "[REDACTED:#{env_key}]"
    after
      restore_env(env_key, previous_value)
      File.rm_rf(workspace)
    end
  end

  test "redacts a secret split across port output chunks" do
    env_key = "SYMPHONY_VALIDATION_TEST_TOKEN"
    secret_value = "cross-chunk-secret"
    previous_value = System.get_env(env_key)
    System.put_env(env_key, secret_value)

    {workspace, issue} =
      workspace_and_issue("3 tests, 0 failures",
        script_body: "#!/bin/sh\nprintf 'cross-chunk-'\nsleep 0.05\nprintf 'secret'\necho\necho '3 tests, 0 failures'\n"
      )

    try do
      assert {:ok, certificate} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      [event_id] = certificate["validation_event_ids"]

      event =
        workspace
        |> Path.join(".orocsy/delivery/events/events.jsonl")
        |> File.stream!()
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["event_id"] == event_id))

      evidence = File.read!(Path.join(workspace, event["bounded_log_path"]))
      refute evidence =~ secret_value
      assert evidence =~ "[REDACTED:#{env_key}]"
    after
      restore_env(env_key, previous_value)
      File.rm_rf(workspace)
    end
  end

  test "bounds and sanitizes invalid UTF-8 validation output" do
    {workspace, issue} =
      workspace_and_issue("3 tests, 0 failures",
        script_body: "#!/bin/sh\nprintf '\\377'\necho '3 tests, 0 failures'\n"
      )

    try do
      assert {:ok, certificate} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      [event_id] = certificate["validation_event_ids"]

      event =
        workspace
        |> Path.join(".orocsy/delivery/events/events.jsonl")
        |> File.stream!()
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["event_id"] == event_id))

      evidence = File.read!(Path.join(workspace, event["bounded_log_path"]))
      assert String.valid?(evidence)
      assert evidence =~ "3 tests, 0 failures"
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

  test "a pending handoff request is reconciled after a certificate already exists" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      assert {:ok, _certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      push_to_local_origin!(workspace)
      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})
      assert {:ok, handoff} = HandoffController.process_requests(issue, workspace)

      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})
      assert {:ok, ^handoff} = HandoffController.process_requests(issue, workspace)

      assert 2 ==
               Enum.count(events(workspace), fn event ->
                 event["event"] == "runtime.request.processed" and
                   event["request_event"] == "handoff.requested"
               end)
    after
      File.rm_rf(workspace)
    end
  end

  test "failed controller validation creates an actionable MIU correction" do
    {workspace, issue} = workspace_and_issue("1 test, 1 failure")

    try do
      allow_workspace_corrections!(workspace)

      append_event!(workspace, issue, %{
        "event" => "miu.completion_requested",
        "status" => "requested",
        "miu_id" => "COD-700-MIU-1"
      })

      assert {:error, {:validation_failed, event}} =
               ValidationController.process_requests(issue, workspace)

      assert event["reason_class"] == "tests_failed"
      assert [correction] = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert correction["source"] == "symphony.runtime.validation-controller"
      assert correction["summary"] == "COD-700-MIU-1 authoritative validation failed"
      assert get_in(correction, ["guard", "miu_id"]) == "COD-700-MIU-1"
      assert Enum.any?(correction["findings"], &String.contains?(&1, "1 test, 1 failure"))
      assert Enum.any?(correction["findings"], &String.contains?(&1, "Declared write scope: README.md"))
      assert Enum.any?(correction["required_corrections"], &String.contains?(&1, "smallest in-scope fix"))

      assert {:ok, %{"mode" => "handoff_recovery"} = preflight} =
               DispatchPreflight.prepare(workspace, issue)

      assert Enum.any?(preflight["open_corrections"], &(&1["correction_id"] == correction["correction_id"]))
    after
      File.rm_rf(workspace)
    end
  end

  test "pre-validation certification errors create durable controller corrections" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      allow_workspace_corrections!(workspace)

      assert :ok =
               ValidationController.reconcile_runtime_corrections(
                 issue,
                 workspace,
                 "COD-700-MIU-1",
                 {:error, {:undeclared_miu_write, ["SECRET.md"]}}
               )

      assert [correction] = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert correction["source"] == "symphony.runtime.validation-controller"
      assert correction["next_action"] == "retry"
      assert correction["summary"] == "COD-700-MIU-1 runtime certification did not complete"
      assert Enum.any?(correction["findings"], &String.contains?(&1, "undeclared_miu_write"))
    after
      File.rm_rf(workspace)
    end
  end

  test "pre-validation final certification errors block post-certificate commits" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      allow_workspace_corrections!(workspace)

      assert :ok =
               ValidationController.reconcile_runtime_corrections(
                 issue,
                 workspace,
                 "__final__",
                 {:error, :uncertified_commit_after_last_miu}
               )

      assert [correction] = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert correction["next_action"] == "block"
      assert correction["summary"] == "Final runtime certification did not complete"
      assert Enum.any?(correction["required_corrections"], &String.contains?(&1, "Do not create a post-certification commit"))
    after
      File.rm_rf(workspace)
    end
  end

  test "does not consume a MIU request when correction reconciliation fails" do
    {workspace, issue} = workspace_and_issue("1 test, 1 failure")

    try do
      append_event!(workspace, issue, %{
        "event" => "miu.completion_requested",
        "status" => "requested",
        "miu_id" => "COD-700-MIU-1"
      })

      assert {:error, {:runtime_correction_reconciliation_failed, _reason, {:error, {:validation_failed, _event}}}} =
               ValidationController.process_requests(issue, workspace)

      refute Enum.any?(events(workspace), fn event ->
               event["event"] == "runtime.request.processed"
             end)
    after
      File.rm_rf(workspace)
    end
  end

  test "exhausted validation budget replaces retry guidance with a durable block" do
    {workspace, issue} = workspace_and_issue("0 tests, 0 failures")

    try do
      allow_workspace_corrections!(workspace)

      for repair <- 0..2 do
        if repair > 0, do: commit_readme!(workspace, "Repair #{repair}")

        append_event!(workspace, issue, %{
          "event" => "miu.completion_requested",
          "status" => "requested",
          "miu_id" => "COD-700-MIU-1"
        })

        if repair < 2 do
          assert {:error, {:validation_failed, _event}} =
                   ValidationController.process_requests(issue, workspace)
        else
          assert {:blocked, {:product_fix_budget_exhausted, "COD-700-MIU-1"}} =
                   ValidationController.process_requests(issue, workspace)
        end
      end

      assert [correction] = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert correction["source"] == "symphony.runtime.validation-controller"
      assert correction["source_status"] == "blocked"
      assert correction["next_action"] == "block"
      assert get_in(correction, ["guard", "reason_class"]) == "product_fix_budget_exhausted"
      assert Enum.any?(correction["findings"], &String.contains?(&1, "Declared write scope: README.md"))
    after
      File.rm_rf(workspace)
    end
  end

  test "reports a controller correction write failure instead of discarding it" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      assert {:error, {:validation_correction_write_failed, {:workspace_outside_root, _, _}}} =
               ValidationController.reconcile_runtime_corrections(
                 issue,
                 workspace,
                 "COD-700-MIU-1",
                 {:error,
                  {:validation_failed,
                   %{
                     "event_id" => "validation-test",
                     "command" => "./fake-test",
                     "reason_class" => "tests_failed",
                     "exit_code" => 1
                   }}}
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "successful controller certification resolves matching MIU validation corrections" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      allow_workspace_corrections!(workspace)

      assert {:ok, correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "worker-validation",
                 source_status: "blocked",
                 summary: "COD-700-MIU-1 Playwright validation cannot launch in the worker sandbox",
                 findings: ["Command: pnpm exec playwright test tests/e2e/example.spec.ts"],
                 required_corrections: ["Let the runtime controller validate COD-700-MIU-1"],
                 next_action: "retry"
               })

      assert {:ok, unrelated_correction} =
               Workspace.create_correction_in_workspace(workspace, issue, %{
                 source: "business-validation",
                 source_status: "failed",
                 summary: "COD-700-MIU-1 test coverage misses an unrelated product requirement",
                 findings: ["A current-head review thread remains actionable"],
                 required_corrections: ["Address the product review finding separately"],
                 next_action: "retry"
               })

      append_event!(workspace, issue, %{
        "event" => "miu.completion_requested",
        "status" => "requested",
        "miu_id" => "COD-700-MIU-1"
      })

      assert {:ok, certificate} = ValidationController.process_requests(issue, workspace)
      assert certificate["miu_id"] == "COD-700-MIU-1"

      assert [open_correction] = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert open_correction["correction_id"] == unrelated_correction["correction_id"]

      resolved =
        workspace
        |> Path.join(get_in(correction, ["artifacts", "json"]))
        |> File.read!()
        |> Jason.decode!()

      assert resolved["status"] == "resolved"
      assert resolved["resolution_summary"] =~ "Runtime controller validation passed"
    after
      File.rm_rf(workspace)
    end
  end

  test "failed final controller validation creates an actionable handoff correction" do
    script_body = """
    #!/bin/sh
    mkdir -p .orocsy
    if [ -f .orocsy/final-validation ]; then
      echo '1 test, 1 failure'
    else
      touch .orocsy/final-validation
      echo '3 tests, 0 failures'
    fi
    """

    {workspace, issue} = workspace_and_issue("unused", script_body: script_body)

    try do
      allow_workspace_corrections!(workspace)

      assert {:ok, _certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      push_to_local_origin!(workspace)
      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})

      assert {:error, {:validation_failed, event}} =
               HandoffController.process_requests(issue, workspace)

      assert event["miu_id"] == "__final__"
      assert [correction] = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert get_in(correction, ["guard", "miu_id"]) == "__final__"
      assert correction["source_status"] == "blocked"
      assert correction["next_action"] == "block"
      assert Enum.any?(correction["findings"], &String.contains?(&1, "1 test, 1 failure"))
      assert Enum.any?(correction["required_corrections"], &String.contains?(&1, "Do not create a post-certification commit"))
      refute Enum.any?(correction["required_corrections"], &String.contains?(&1, "new micro commit"))
    after
      File.rm_rf(workspace)
    end
  end

  test "does not consume a handoff request when correction reconciliation fails" do
    script_body = """
    #!/bin/sh
    mkdir -p .orocsy
    if [ -f .orocsy/final-validation ]; then
      echo '1 test, 1 failure'
    else
      touch .orocsy/final-validation
      echo '3 tests, 0 failures'
    fi
    """

    {workspace, issue} = workspace_and_issue("unused", script_body: script_body)

    try do
      assert {:ok, _certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      push_to_local_origin!(workspace)
      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})

      assert {:error, {:runtime_correction_reconciliation_failed, _reason, {:error, {:validation_failed, _event}}}} =
               HandoffController.process_requests(issue, workspace)

      refute Enum.any?(events(workspace), fn event ->
               event["event"] == "runtime.request.processed"
             end)
    after
      File.rm_rf(workspace)
    end
  end

  test "failed review-rework validation remains retryable through handoff recovery" do
    script_body = """
    #!/bin/sh
    if [ -f .orocsy/review-validation-fail ]; then
      echo '1 test, 1 failure'
    else
      echo '3 tests, 0 failures'
    fi
    """

    {workspace, issue} = workspace_and_issue("unused", script_body: script_body)

    try do
      allow_workspace_corrections!(workspace)
      assert {:ok, _certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      File.touch!(Path.join(workspace, ".orocsy/review-validation-fail"))
      write_review_rework_preflight!(workspace, issue)
      commit_readme!(workspace, "Address current-head review feedback")
      push_to_local_origin!(workspace)
      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})

      assert {:error, {:validation_failed, event}} = HandoffController.process_requests(issue, workspace)
      assert event["miu_id"] == "__review_rework__"

      assert [correction] = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert get_in(correction, ["guard", "miu_id"]) == "__review_rework__"
      assert correction["next_action"] == "retry"
      assert Enum.any?(correction["required_corrections"], &String.contains?(&1, "handoff.requested"))
      refute Enum.any?(correction["required_corrections"], &String.contains?(&1, "post-certification"))

      assert {:ok, %{"mode" => "review_rework"} = preflight} = DispatchPreflight.prepare(workspace, issue)

      assert Enum.any?(preflight["open_corrections"], fn open_correction ->
               open_correction["correction_id"] == correction["correction_id"]
             end)

      File.rm!(Path.join(workspace, ".orocsy/review-validation-fail"))
      commit_readme!(workspace, "Correct review validation failure")
      git!(workspace, ["push"])
      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})

      assert {:ok, handoff} = HandoffController.process_requests(issue, workspace)
      assert handoff["event"] == "handoff.ready"
      assert Workspace.open_blocking_corrections_in_workspace(workspace) == []
    after
      File.rm_rf(workspace)
    end
  end

  test "automatic review-delta validation failure creates a retryable controller correction" do
    script_body = """
    #!/bin/sh
    if [ -f .orocsy/review-validation-fail ]; then
      echo '1 test, 1 failure'
    else
      echo '3 tests, 0 failures'
    fi
    """

    {workspace, issue} = workspace_and_issue("unused", script_body: script_body)

    try do
      allow_workspace_corrections!(workspace)
      assert {:ok, _certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      push_to_local_origin!(workspace)
      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})
      assert {:ok, _handoff} = HandoffController.process_requests(issue, workspace)

      issue = %{issue | state: "Rework"}
      File.touch!(Path.join(workspace, ".orocsy/review-validation-fail"))
      commit_readme!(workspace, "Address automatic review feedback")
      review_head = git_output!(workspace, ["rev-parse", "HEAD"])
      git!(workspace, ["push"])

      assert {:error, {:validation_failed, event}} =
               HandoffController.reconcile_review_delta(issue, workspace, %{
                 head_sha: review_head,
                 head_ref: "orocsy/cod-700",
                 feedback: []
               })

      assert event["miu_id"] == "__review_rework__"
      assert [correction] = Workspace.open_blocking_corrections_in_workspace(workspace)
      assert correction["next_action"] == "retry"
      assert get_in(correction, ["guard", "miu_id"]) == "__review_rework__"
      assert Enum.any?(correction["findings"], &String.contains?(&1, "Declared write scope: README.md"))
    after
      File.rm_rf(workspace)
    end
  end

  test "writes UTF-8-safe correction output when truncation splits a multibyte character" do
    output = String.duplicate("a", 3_999) <> "é 1 test, 1 failure"
    {workspace, issue} = workspace_and_issue(output)

    try do
      allow_workspace_corrections!(workspace)

      append_event!(workspace, issue, %{
        "event" => "miu.completion_requested",
        "status" => "requested",
        "miu_id" => "COD-700-MIU-1"
      })

      assert {:error, {:validation_failed, _event}} =
               ValidationController.process_requests(issue, workspace)

      assert [correction] = Workspace.open_blocking_corrections_in_workspace(workspace)
      finding = Enum.find(correction["findings"], &String.starts_with?(&1, "Validation output:"))
      assert String.valid?(finding)
      assert finding =~ "...[truncated]"
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

  test "credential value changes allow an infrastructure retry at the same code identity" do
    env_key = "SYMPHONY_VALIDATION_TEST_API_KEY"
    previous_value = System.get_env(env_key)
    System.put_env(env_key, "expired-credential")
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

      System.put_env(env_key, "replacement-credential")

      assert {:error, {:validation_failed, second}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert first["reason_class"] == "command_launch_failed"
      assert second["reason_class"] == "command_launch_failed"
      refute second["environment_fingerprint"] == first["environment_fingerprint"]
      refute second["validation_fingerprint"] == first["validation_fingerprint"]
    after
      restore_env(env_key, previous_value)
      File.rm_rf(workspace)
    end
  end

  test "credential value changes allow an unparsed command failure retry at the same code identity" do
    env_key = "SYMPHONY_VALIDATION_TEST_API_KEY"
    previous_value = System.get_env(env_key)
    System.put_env(env_key, "expired-credential")

    {workspace, issue} =
      workspace_and_issue("3 tests, 0 failures",
        script_body: "#!/bin/sh\n[ \"$#{env_key}\" = replacement-credential ] || { echo 'credential rejected'; exit 9; }\necho '3 tests, 0 failures'\n"
      )

    try do
      assert {:error, {:validation_failed, first}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert first["reason_class"] == "command_failed"
      System.put_env(env_key, "replacement-credential")

      assert {:ok, certificate} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert certificate["miu_id"] == "COD-700-MIU-1"
    after
      restore_env(env_key, previous_value)
      File.rm_rf(workspace)
    end
  end

  test "auth-named credential changes allow an unparsed command failure retry" do
    env_key = "DOCKER_AUTH_CONFIG"
    previous_value = System.get_env(env_key)
    System.put_env(env_key, "expired-auth")

    {workspace, issue} =
      workspace_and_issue("3 tests, 0 failures",
        script_body: "#!/bin/sh\n[ \"$#{env_key}\" = replacement-auth ] || { echo 'auth rejected'; exit 9; }\necho '3 tests, 0 failures'\n"
      )

    try do
      assert {:error, {:validation_failed, first}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert first["reason_class"] == "command_failed"
      System.put_env(env_key, "replacement-auth")

      assert {:ok, certificate} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert certificate["miu_id"] == "COD-700-MIU-1"
    after
      restore_env(env_key, previous_value)
      File.rm_rf(workspace)
    end
  end

  test "provider configuration changes allow an unparsed command failure retry" do
    env_key = "OPENAI_BASE_URL"
    previous_value = System.get_env(env_key)
    System.put_env(env_key, "https://expired.example.test")

    {workspace, issue} =
      workspace_and_issue("3 tests, 0 failures",
        script_body: "#!/bin/sh\n[ \"$#{env_key}\" = https://valid.example.test ] || { echo 'provider rejected'; exit 9; }\necho '3 tests, 0 failures'\n"
      )

    try do
      assert {:error, {:validation_failed, first}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert first["reason_class"] == "command_failed"
      System.put_env(env_key, "https://valid.example.test")

      assert {:ok, certificate} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert certificate["miu_id"] == "COD-700-MIU-1"
    after
      restore_env(env_key, previous_value)
      File.rm_rf(workspace)
    end
  end

  test "proxy changes allow an unparsed command failure retry" do
    env_key = "HTTPS_PROXY"
    previous_value = System.get_env(env_key)
    System.put_env(env_key, "http://expired-proxy.example.test")

    {workspace, issue} =
      workspace_and_issue("3 tests, 0 failures",
        script_body: "#!/bin/sh\n[ \"$#{env_key}\" = http://valid-proxy.example.test ] || { echo 'proxy rejected'; exit 9; }\necho '3 tests, 0 failures'\n"
      )

    try do
      assert {:error, {:validation_failed, first}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert first["reason_class"] == "command_failed"
      System.put_env(env_key, "http://valid-proxy.example.test")

      assert {:ok, certificate} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert certificate["miu_id"] == "COD-700-MIU-1"
    after
      restore_env(env_key, previous_value)
      File.rm_rf(workspace)
    end
  end

  test "unrelated process metadata does not create a new infrastructure retry identity" do
    env_key = "SYMPHONY_VALIDATION_TEST_AUTHORITY"
    previous_value = System.get_env(env_key)
    System.put_env(env_key, "first-run")
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
      System.put_env(env_key, "second-run")

      assert {:blocked, {:unchanged_infrastructure_validation, fingerprint}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert fingerprint == first["validation_fingerprint"]
    after
      restore_env(env_key, previous_value)
      File.rm_rf(workspace)
    end
  end

  test "credential value changes do not bypass parsed test failures" do
    env_key = "SYMPHONY_VALIDATION_TEST_API_KEY"
    previous_value = System.get_env(env_key)
    System.put_env(env_key, "first-credential")

    {workspace, issue} =
      workspace_and_issue("1 failed | 2 passed",
        script_body: "#!/bin/sh\necho 'Tests 1 failed | 2 passed'\nexit 1\n"
      )

    try do
      assert {:error, {:validation_failed, first}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert first["reason_class"] == "tests_failed"
      System.put_env(env_key, "second-credential")

      assert {:blocked, {:unchanged_failed_validation, fingerprint}} =
               ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      assert fingerprint == first["validation_fingerprint"]
    after
      restore_env(env_key, previous_value)
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
      allow_workspace_corrections!(workspace)
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
      allow_workspace_corrections!(workspace)
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

  test "review rework preflight binds the latest signed handoff before current-head feedback" do
    {workspace, initial_issue} = workspace_and_issue("3 tests, 0 failures")
    issue = %{initial_issue | state: "Rework"}

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.dirname(workspace),
        review_monitor_enabled: true,
        review_monitor_repo: "test/symphony"
      )

      assert {:ok, miu_certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")
      push_to_local_origin!(workspace)

      assert {:ok, handoff} =
               HandoffCertificate.issue(issue, workspace,
                 completed_mius: ["COD-700-MIU-1"],
                 validation_event_ids: miu_certificate["validation_event_ids"]
               )

      signed_head = handoff["head_sha"]
      commit_readme!(workspace, "Address current-head review feedback")
      git!(workspace, ["push"])
      review_head = git_output!(workspace, ["rev-parse", "HEAD"])
      refute review_head == signed_head

      parent = self()

      Application.put_env(:symphony_elixir, :github_api_runner, fn endpoint ->
        decoded = URI.decode(endpoint)

        cond do
          String.starts_with?(decoded, "repos/test/symphony/pulls?") ->
            {:ok,
             [
               %{
                 "number" => 700,
                 "html_url" => "https://github.com/test/symphony/pull/700",
                 "head" => %{"sha" => review_head, "ref" => "orocsy/cod-700"}
               }
             ]}

          decoded == "repos/test/symphony/pulls/700/comments" ->
            send(parent, :review_feedback_inspected)

            {:ok,
             [
               %{
                 "body" => "Preserve the in-scope README contract.",
                 "commit_id" => review_head,
                 "path" => "README.md",
                 "line" => 3,
                 "html_url" => "https://github.com/test/symphony/pull/700#discussion"
               }
             ]}

          decoded == "repos/test/symphony/pulls/700/reviews" ->
            {:ok, []}

          true ->
            {:error, {:unexpected_endpoint, endpoint}}
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_api_runner) end)

      assert {:ok, %{"mode" => "review_rework"} = preflight} =
               DispatchPreflight.prepare(workspace, issue)

      assert_receive :review_feedback_inspected
      assert get_in(preflight, ["review", "head_sha"]) == review_head
      assert preflight["review_delta_base_head"] == signed_head

      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})
      assert {:ok, updated_handoff} = HandoffController.process_requests(issue, workspace)
      assert updated_handoff["head_sha"] == review_head
    after
      File.rm_rf(workspace)
    end
  end

  test "handoff rejects an out-of-scope review rework delta" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      allow_workspace_corrections!(workspace)
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
      allow_workspace_corrections!(workspace)
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

  test "handoff audits paths added and reverted within the review delta" do
    {workspace, issue} = workspace_and_issue("3 tests, 0 failures")

    try do
      allow_workspace_corrections!(workspace)
      assert {:ok, _certificate} = ValidationController.certify_miu(issue, workspace, "COD-700-MIU-1")

      write_review_rework_preflight!(workspace, issue)
      File.write!(Path.join(workspace, "SECRET.md"), "temporary out-of-scope write\n")
      git!(workspace, ["add", "SECRET.md"])
      git!(workspace, ["commit", "-m", "Add temporary secret file"])
      File.rm!(Path.join(workspace, "SECRET.md"))
      commit_readme!(workspace, "Revert temporary file and fix review")
      git!(workspace, ["add", "-u"])
      git!(workspace, ["commit", "--amend", "--no-edit"])
      push_to_local_origin!(workspace)
      append_event!(workspace, issue, %{"event" => "handoff.requested", "status" => "requested"})

      assert {:error, {:undeclared_review_rework_write, ["SECRET.md"]}} =
               HandoffController.process_requests(issue, workspace)
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

  defp allow_workspace_corrections!(workspace) do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(workspace))
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

    on_exit(fn -> restore_application_env(:handoff_remote_head_runner, previous_runner) end)
    on_exit(fn -> restore_application_env(:handoff_pull_request_runner, previous_pr_runner) end)
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

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

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
