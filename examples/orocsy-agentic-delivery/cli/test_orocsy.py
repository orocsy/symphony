import json
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import orocsy


class OrocsyRuntimeCliTests(unittest.TestCase):
    def run_cli(self, argv: list[str]) -> tuple[int, str]:
        output = StringIO()
        with redirect_stdout(output):
            code = orocsy.main(argv)
        return code, output.getvalue()

    def init_git_repo(self, repo: Path) -> None:
        subprocess.run(["git", "init"], cwd=repo, check=True, stdout=subprocess.PIPE)
        subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)

    def commit_all(self, repo: Path, message: str = "initial") -> None:
        subprocess.run(["git", "add", "-A"], cwd=repo, check=True)
        subprocess.run(["git", "commit", "-m", message], cwd=repo, check=True, stdout=subprocess.PIPE)

    def test_init_creates_ledger_and_initial_event(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            code, output = self.run_cli(["--repo", str(repo), "init", "--intent", "Test runtime"])

            self.assertEqual(code, 0)
            self.assertIn("initialized Orocsy ledger", output)
            state_path = repo / ".orocsy/delivery/state/current.json"
            events_path = repo / ".orocsy/delivery/events/events.jsonl"
            self.assertTrue(state_path.exists())
            self.assertTrue(events_path.exists())
            self.assertTrue((repo / ".orocsy/delivery/evals/miu-quality.rubric.md").exists())

            state = json.loads(state_path.read_text(encoding="utf-8"))
            self.assertEqual(state["schema_version"], 1)
            self.assertEqual(state["intent"], "Test runtime")

            events = events_path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(events), 1)
            self.assertEqual(json.loads(events[0])["event"], "run.initialized")

    def test_event_append_updates_state(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.run_cli(["--repo", str(repo), "init"])

            code, _output = self.run_cli(
                [
                    "--repo",
                    str(repo),
                    "event",
                    "append",
                    "--type",
                    "tool.finished",
                    "--status",
                    "passed",
                    "--tool",
                    "pnpm test",
                ],
            )

            self.assertEqual(code, 0)
            events = (repo / ".orocsy/delivery/events/events.jsonl").read_text(encoding="utf-8").splitlines()
            self.assertEqual(json.loads(events[-1])["event"], "tool.finished")
            state = json.loads((repo / ".orocsy/delivery/state/current.json").read_text(encoding="utf-8"))
            self.assertEqual(state["last_event_id"], json.loads(events[-1])["event_id"])

    def test_legacy_codex_delivery_root_migrates_to_writable_runtime_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            legacy_root = repo / ".codex/delivery"
            (legacy_root / "state").mkdir(parents=True)
            (legacy_root / "events").mkdir(parents=True)
            (legacy_root / "bin").mkdir(parents=True)
            (legacy_root / "state/current.json").write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "run_id": "run_legacy",
                        "goal_id": "goal_legacy",
                        "status": "running",
                        "phase": "legacy",
                        "intent": "Legacy run",
                        "issue": "COD-1",
                        "created_at": "2026-05-11T00:00:00Z",
                        "updated_at": "2026-05-11T00:00:00Z",
                        "last_event_id": "evt_legacy",
                        "gates": {},
                    },
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            (legacy_root / "events/events.jsonl").write_text(
                json.dumps({"event": "legacy", "event_id": "evt_legacy"}) + "\n",
                encoding="utf-8",
            )
            (legacy_root / "bin/orocsy.py").write_text("legacy binary copy\n", encoding="utf-8")

            code, _output = self.run_cli(
                [
                    "--repo",
                    str(repo),
                    "event",
                    "append",
                    "--type",
                    "tool.finished",
                    "--status",
                    "passed",
                ],
            )

            self.assertEqual(code, 0)
            self.assertTrue((repo / ".orocsy/delivery/state/current.json").exists())
            self.assertFalse((repo / ".orocsy/delivery/bin/orocsy.py").exists())
            events = (repo / ".orocsy/delivery/events/events.jsonl").read_text(encoding="utf-8").splitlines()
            self.assertEqual(json.loads(events[0])["event"], "legacy")
            self.assertEqual(json.loads(events[-1])["event"], "tool.finished")

    def test_gate_leaks_fails_for_configured_project_origin_terms(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.init_git_repo(repo)
            (repo / "README.md").write_text("Copied from OldProject\n", encoding="utf-8")

            code, output = self.run_cli(["--repo", str(repo), "gate", "leaks", "--forbid", "OldProject"])

            self.assertEqual(code, 1)
            self.assertIn("forbidden term found", output)

    def test_gate_artifacts_fails_for_unignored_build_output(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.init_git_repo(repo)
            (repo / ".DS_Store").write_text("local", encoding="utf-8")

            code, output = self.run_cli(["--repo", str(repo), "gate", "artifacts"])

            self.assertEqual(code, 1)
            self.assertIn("generated or local artifact", output)

    def test_gate_declared_scope_blocks_out_of_scope_change(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.init_git_repo(repo)
            (repo / "src").mkdir()
            (repo / "src/app.ts").write_text("export {}\n", encoding="utf-8")
            self.commit_all(repo)
            self.run_cli(["--repo", str(repo), "init"])
            (repo / ".orocsy/delivery/policy.yml").write_text("declared_scope:\n  - src/**\n", encoding="utf-8")
            (repo / "docs.md").write_text("out of scope\n", encoding="utf-8")

            code, output = self.run_cli(["--repo", str(repo), "gate", "declared-scope"])

            self.assertEqual(code, 1)
            self.assertIn("outside declared scope", output)

    def test_gate_declared_scope_allows_next_dynamic_route_segments(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.init_git_repo(repo)
            self.run_cli(["--repo", str(repo), "init"])
            route = repo / "src/app/api/recipe-chats/[chatId]/messages/route.ts"
            route.parent.mkdir(parents=True)
            route.write_text("export {}\n", encoding="utf-8")
            (repo / ".orocsy/delivery/policy.yml").write_text(
                "declared_scope:\n  - src/app/api/recipe-chats/[chatId]/messages/route.ts\n",
                encoding="utf-8",
            )

            code, output = self.run_cli(["--repo", str(repo), "gate", "declared-scope"])

            self.assertEqual(code, 0)
            self.assertIn("declared-scope: passed", output)

    def test_gate_required_evidence_checks_files_and_events(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.run_cli(["--repo", str(repo), "init"])
            self.run_cli(["--repo", str(repo), "event", "append", "--type", "tool.finished"])

            code, output = self.run_cli(
                [
                    "--repo",
                    str(repo),
                    "gate",
                    "required-evidence",
                    "--evidence-file",
                    ".orocsy/delivery/handoff.md",
                    "--evidence-event",
                    "tool.finished",
                ],
            )

            self.assertEqual(code, 0)
            self.assertIn("required-evidence: passed", output)

    def test_gate_required_evidence_normalizes_legacy_delivery_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.run_cli(["--repo", str(repo), "init"])
            evidence = repo / ".orocsy/delivery/evidence/proof.txt"
            evidence.parent.mkdir(parents=True, exist_ok=True)
            evidence.write_text("browser proof\n", encoding="utf-8")
            (repo / ".orocsy/delivery/policy.yml").write_text(
                "required_evidence_files:\n  - .codex/delivery/evidence/proof.txt\n",
                encoding="utf-8",
            )

            code, output = self.run_cli(["--repo", str(repo), "gate", "required-evidence"])

            self.assertEqual(code, 0)
            self.assertIn("required-evidence: passed", output)

    def test_gate_all_can_emit_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.init_git_repo(repo)
            (repo / ".gitignore").write_text(".DS_Store\n", encoding="utf-8")
            (repo / "README.md").write_text("Clean project\n", encoding="utf-8")
            self.commit_all(repo)

            code, output = self.run_cli(["--repo", str(repo), "gate", "all", "--json"])

            self.assertEqual(code, 0)
            payload = json.loads(output)
            self.assertIn(payload["status"], {"passed", "warn"})
            self.assertTrue(any(gate["gate"] == "leaks" for gate in payload["gates"]))

    def test_eval_rubric_emits_json_contract(self) -> None:
        code, output = self.run_cli(["eval", "rubric", "miu-quality", "--json"])

        self.assertEqual(code, 0)
        payload = json.loads(output)
        self.assertEqual(payload["name"], "miu-quality")
        self.assertIn("criteria", payload)
        self.assertIn("output_schema", payload)

    def test_eval_record_appends_structured_event(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.run_cli(["--repo", str(repo), "init"])

            code, output = self.run_cli(
                [
                    "--repo",
                    str(repo),
                    "eval",
                    "record",
                    "business-correction",
                    "--status",
                    "failed",
                    "--summary",
                    "Boundary check missing.",
                    "--finding",
                    "provider quota not checked",
                    "--required-correction",
                    "Add rate-limit evidence.",
                    "--json",
                ],
            )

            self.assertEqual(code, 1)
            payload = json.loads(output)
            self.assertEqual(payload["event"], "eval.business-correction")
            self.assertEqual(payload["status"], "failed")
            self.assertEqual(payload["rubric"], "business-correction")
            self.assertIn("provider quota not checked", payload["findings"])

            events = (repo / ".orocsy/delivery/events/events.jsonl").read_text(encoding="utf-8").splitlines()
            self.assertEqual(json.loads(events[-1])["event"], "eval.business-correction")

    def test_default_runtime_files_do_not_fail_their_own_leak_gate(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.init_git_repo(repo)
            self.run_cli(["--repo", str(repo), "init"])

            code, output = self.run_cli(["--repo", str(repo), "gate", "leaks"])

            self.assertEqual(code, 0)
            self.assertIn("leaks: passed", output)

    def test_symphony_prepare_workspace_writes_policy_and_prelude_event(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.init_git_repo(repo)

            code, output = self.run_cli(
                [
                    "--repo",
                    str(repo),
                    "symphony",
                    "prepare-workspace",
                    "--issue",
                    "COD-123",
                    "--scope",
                    "src/**",
                    "--orocsy-cli",
                    "/tmp/orocsy.py",
                    "--evidence-event",
                    "tool.finished",
                    "--forbid",
                    "OldProject",
                    "--json",
                ],
            )

            self.assertEqual(code, 0)
            payload = json.loads(output)
            self.assertEqual(payload["state"]["issue"], "COD-123")
            self.assertEqual(payload["state"]["orocsy_cli"], "/tmp/orocsy.py")
            self.assertIn(
                "Confirm pre-change gates with `python3 .codex/delivery/bin/orocsy.py --repo . gate all --json`; "
                "the ledger is .orocsy/delivery/events/events.jsonl.",
                payload["prelude"],
            )

            policy = (repo / ".orocsy/delivery/policy.yml").read_text(encoding="utf-8")
            gates = (repo / ".orocsy/delivery/gates.yml").read_text(encoding="utf-8")
            self.assertIn("src/**", policy)
            self.assertIn("tool.finished", policy)
            self.assertIn("OldProject", gates)
            git_exclude = (repo / ".git/info/exclude").read_text(encoding="utf-8")
            self.assertIn(".orocsy/delivery/", git_exclude)
            self.assertIn(".codex/delivery/", git_exclude)

            events = (repo / ".orocsy/delivery/events/events.jsonl").read_text(encoding="utf-8").splitlines()
            self.assertEqual(json.loads(events[-1])["event"], "symphony.workspace.prepared")

    def test_symphony_prepare_workspace_installs_workspace_local_cli(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.init_git_repo(repo)

            code, output = self.run_cli(
                [
                    "--repo",
                    str(repo),
                    "symphony",
                    "prepare-workspace",
                    "--issue",
                    "COD-124",
                    "--orocsy-cli",
                    str(Path(__file__).resolve().parent / "orocsy.py"),
                    "--forbid",
                    "OldProject",
                    "--json",
                ],
            )

            self.assertEqual(code, 0)
            payload = json.loads(output)
            self.assertEqual(payload["state"]["workspace_orocsy_cli"], ".codex/delivery/bin/orocsy.py")
            self.assertTrue((repo / ".codex/delivery/bin/orocsy.py").exists())

            (repo / "README.md").write_text("OldProject leak\n", encoding="utf-8")
            leak_code, _leak_output = self.run_cli(["--repo", str(repo), "gate", "leaks"])
            self.assertEqual(leak_code, 1)

    def test_symphony_clean_generated_removes_ignored_artifact_and_records_event(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.init_git_repo(repo)
            (repo / ".gitignore").write_text(".next/\n", encoding="utf-8")
            artifact = repo / ".next/dev/types/routes.d.ts"
            artifact.parent.mkdir(parents=True)
            artifact.write_text("type AppRoutes = never\n", encoding="utf-8")
            self.run_cli(["--repo", str(repo), "init"])

            code, output = self.run_cli(
                [
                    "--repo",
                    str(repo),
                    "symphony",
                    "clean-generated",
                    "--path",
                    ".next/dev",
                    "--record",
                    "--json",
                ],
            )

            self.assertEqual(code, 0)
            payload = json.loads(output)
            self.assertEqual(payload["cleanup"]["status"], "passed")
            self.assertIn(".next/dev", payload["cleanup"]["removed"])
            self.assertFalse((repo / ".next/dev").exists())
            events = (repo / ".orocsy/delivery/events/events.jsonl").read_text(encoding="utf-8").splitlines()
            self.assertEqual(json.loads(events[-1])["event"], "symphony.generated.cleanup")

    def test_symphony_clean_generated_removes_ignored_runtime_cache_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.init_git_repo(repo)
            runtime_artifact = repo / ".orocsy/runtime/ms-playwright/browser.js"
            runtime_artifact.parent.mkdir(parents=True)
            runtime_artifact.write_text("generated browser cache\n", encoding="utf-8")
            self.run_cli(["--repo", str(repo), "init"])

            code, output = self.run_cli(
                [
                    "--repo",
                    str(repo),
                    "symphony",
                    "clean-generated",
                    "--record",
                    "--json",
                ],
            )

            self.assertEqual(code, 0)
            payload = json.loads(output)
            self.assertEqual(payload["cleanup"]["status"], "passed")
            self.assertIn(".orocsy/runtime", payload["cleanup"]["removed"])
            self.assertFalse((repo / ".orocsy/runtime").exists())

    def test_symphony_clean_generated_removes_legacy_pnpm_store_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.init_git_repo(repo)
            store_artifact = repo / ".pnpm-store/v3/files/cache-index.json"
            store_artifact.parent.mkdir(parents=True)
            store_artifact.write_text("{}\n", encoding="utf-8")
            self.run_cli(["--repo", str(repo), "init"])

            code, output = self.run_cli(
                [
                    "--repo",
                    str(repo),
                    "symphony",
                    "clean-generated",
                    "--record",
                    "--json",
                ],
            )

            self.assertEqual(code, 0)
            payload = json.loads(output)
            self.assertEqual(payload["cleanup"]["status"], "passed")
            self.assertIn(".pnpm-store", payload["cleanup"]["removed"])
            self.assertFalse((repo / ".pnpm-store").exists())

    def test_symphony_clean_generated_restores_next_env_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.init_git_repo(repo)
            next_env = repo / "next-env.d.ts"
            next_env.write_text('import "./.next/types/routes.d.ts";\n', encoding="utf-8")
            self.commit_all(repo)
            next_env.write_text('import "./.next/dev/types/routes.d.ts";\n', encoding="utf-8")

            code, output = self.run_cli(
                [
                    "--repo",
                    str(repo),
                    "symphony",
                    "clean-generated",
                    "--record",
                    "--json",
                ],
            )

            self.assertEqual(code, 0)
            payload = json.loads(output)
            self.assertEqual(payload["cleanup"]["status"], "passed")
            self.assertIn("next-env.d.ts", payload["cleanup"]["restored"])
            self.assertEqual(next_env.read_text(encoding="utf-8"), 'import "./.next/types/routes.d.ts";\n')

    def test_symphony_clean_generated_refuses_unignored_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.init_git_repo(repo)
            source = repo / "src/app.ts"
            source.parent.mkdir()
            source.write_text("export {}\n", encoding="utf-8")

            code, output = self.run_cli(
                [
                    "--repo",
                    str(repo),
                    "symphony",
                    "clean-generated",
                    "--path",
                    "src",
                    "--json",
                ],
            )

            self.assertEqual(code, 1)
            payload = json.loads(output)
            self.assertEqual(payload["cleanup"]["status"], "failed")
            self.assertTrue(source.exists())
            self.assertEqual(payload["cleanup"]["blocked"][0]["reason"], "path is not in the generated-clean allowlist")

    def test_symphony_clean_generated_allows_missing_default_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.init_git_repo(repo)

            code, output = self.run_cli(["--repo", str(repo), "symphony", "clean-generated", "--json"])

            self.assertEqual(code, 0)
            payload = json.loads(output)
            self.assertEqual(payload["cleanup"]["status"], "warn")
            self.assertEqual(payload["cleanup"]["skipped"][0]["reason"], "missing")

    def test_prepare_workspace_reads_issue_file_and_gates_requirements(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "workspace"
            repo.mkdir()
            issue_file = root / "COD-201.json"
            issue_file.write_text(
                json.dumps(
                    {
                        "identifier": "COD-201",
                        "title": "Add sample provider setup",
                        "state": "In Progress",
                        "branch": "orocsy/cod-201-provider-setup",
                        "project_slug": "dummy-agentic-runtime",
                        "write_scope": ["src/**", ".codex/delivery/**"],
                        "shared_files": ["package.json"],
                        "dependencies": [],
                        "mius": [{"id": "MIU-1", "summary": "Add provider config"}],
                        "validation": {
                            "files": [".codex/delivery/evidence/provider.md"],
                            "events": ["tool.finished"],
                            "commands": ["unit test"],
                        },
                        "out_of_scope": ["production provider mutation"],
                    },
                ),
                encoding="utf-8",
            )

            code, output = self.run_cli(
                ["--repo", str(repo), "symphony", "prepare-workspace", "--issue-file", str(issue_file), "--json"],
            )

            self.assertEqual(code, 0)
            payload = json.loads(output)
            self.assertEqual(payload["state"]["issue"], "COD-201")
            self.assertEqual(payload["state"]["issue_requirements"]["branch"], "orocsy/cod-201-provider-setup")
            self.assertEqual(payload["state"]["issue_requirements"]["project"], "dummy-agentic-runtime")
            self.assertIn(".orocsy/delivery/**", payload["state"]["issue_requirements"]["write_scope"])
            self.assertIn(
                ".orocsy/delivery/evidence/provider.md",
                payload["state"]["issue_requirements"]["validation"]["files"],
            )

            policy = (repo / ".orocsy/delivery/policy.yml").read_text(encoding="utf-8")
            self.assertIn("src/**", policy)
            self.assertIn(".orocsy/delivery/**", policy)
            self.assertIn(".orocsy/delivery/evidence/provider.md", policy)
            self.assertNotIn(".codex/delivery/evidence/provider.md", policy)
            self.assertIn("tool.finished", policy)
            self.assertIn("unit test", policy)

            gate_code, gate_output = self.run_cli(["--repo", str(repo), "gate", "issue-requirements", "--strict"])
            self.assertEqual(gate_code, 0)
            self.assertIn("issue-requirements: passed", gate_output)

    def test_gate_failure_can_create_and_resolve_correction_inbox_item(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.run_cli(["--repo", str(repo), "init"])

            gate_code, _gate_output = self.run_cli(
                [
                    "--repo",
                    str(repo),
                    "gate",
                    "required-evidence",
                    "--evidence-file",
                    "evidence/missing.md",
                    "--strict",
                    "--inbox",
                    "--json",
                ],
            )

            self.assertEqual(gate_code, 1)
            list_code, list_output = self.run_cli(["--repo", str(repo), "inbox", "list", "--open-only", "--json"])
            self.assertEqual(list_code, 0)
            corrections = json.loads(list_output)["corrections"]
            self.assertEqual(len(corrections), 1)
            self.assertEqual(corrections[0]["source"], "gate.required-evidence")

            guidance_code, guidance_output = self.run_cli(["symphony", "guidance", "--workspace", str(repo), "--json"])
            self.assertEqual(guidance_code, 1)
            self.assertEqual(json.loads(guidance_output)["action"], "block")

            resolve_code, _resolve_output = self.run_cli(
                [
                    "--repo",
                    str(repo),
                    "inbox",
                    "resolve",
                    corrections[0]["correction_id"],
                    "--summary",
                    "Added missing evidence.",
                ],
            )
            self.assertEqual(resolve_code, 0)
            guidance_code_after, guidance_output_after = self.run_cli(
                ["symphony", "guidance", "--workspace", str(repo), "--json"],
            )
            self.assertEqual(guidance_code_after, 0)
            self.assertEqual(json.loads(guidance_output_after)["action"], "continue")

    def test_warn_eval_inbox_produces_retry_guidance(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.run_cli(["--repo", str(repo), "init"])

            eval_code, _eval_output = self.run_cli(
                [
                    "--repo",
                    str(repo),
                    "eval",
                    "record",
                    "browser-evidence",
                    "--status",
                    "warn",
                    "--summary",
                    "Mobile evidence is missing.",
                    "--required-correction",
                    "Run mobile browser verification.",
                    "--inbox",
                ],
            )

            self.assertEqual(eval_code, 0)
            guidance_code, guidance_output = self.run_cli(["symphony", "guidance", "--workspace", str(repo), "--json"])
            self.assertEqual(guidance_code, 0)
            self.assertEqual(json.loads(guidance_output)["action"], "retry")

    def test_symphony_monitor_reports_workspace_state(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            project_root = root / "my-app"
            workspace = project_root / "COD-123"
            workspace.mkdir(parents=True)
            self.init_git_repo(workspace)
            (workspace / "README.md").write_text("workspace\n", encoding="utf-8")
            self.commit_all(workspace)
            self.run_cli(["--repo", str(workspace), "symphony", "prepare-workspace", "--issue", "COD-123"])

            code, output = self.run_cli(["symphony", "monitor", "--root", str(root), "--json"])

            self.assertEqual(code, 0)
            payload = json.loads(output)
            self.assertEqual(payload["status"], "passed")
            self.assertEqual(payload["summary"]["count"], 1)
            self.assertEqual(payload["summary"]["stale"], 0)
            self.assertEqual(payload["workspaces"][0]["name"], "COD-123")
            self.assertEqual(payload["workspaces"][0]["issue"], "COD-123")
            self.assertTrue(payload["workspaces"][0]["git"]["is_git_repo"])
            self.assertGreater(payload["workspaces"][0]["events"]["count"], 0)

    def test_symphony_monitor_marks_stale_runs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "COD-456"
            workspace.mkdir()
            self.init_git_repo(workspace)
            (workspace / "README.md").write_text("workspace\n", encoding="utf-8")
            self.commit_all(workspace)
            self.run_cli(["--repo", str(workspace), "symphony", "prepare-workspace", "--issue", "COD-456"])
            state_path = workspace / ".orocsy/delivery/state/current.json"
            state = json.loads(state_path.read_text(encoding="utf-8"))
            state["updated_at"] = "2000-01-01T00:00:00Z"
            state_path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")

            code, output = self.run_cli(["symphony", "monitor", "--root", str(root), "--stale-minutes", "1", "--strict", "--json"])

            self.assertEqual(code, 1)
            payload = json.loads(output)
            self.assertEqual(payload["status"], "failed")
            self.assertEqual(payload["summary"]["stale"], 1)
            self.assertTrue(payload["workspaces"][0]["stale"])
            self.assertTrue(any(warning.startswith("stale:") for warning in payload["workspaces"][0]["warnings"]))


if __name__ == "__main__":
    unittest.main()
