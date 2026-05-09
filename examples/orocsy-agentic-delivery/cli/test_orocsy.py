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
            state_path = repo / ".codex/delivery/state/current.json"
            events_path = repo / ".codex/delivery/events/events.jsonl"
            self.assertTrue(state_path.exists())
            self.assertTrue(events_path.exists())

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
            events = (repo / ".codex/delivery/events/events.jsonl").read_text(encoding="utf-8").splitlines()
            self.assertEqual(json.loads(events[-1])["event"], "tool.finished")
            state = json.loads((repo / ".codex/delivery/state/current.json").read_text(encoding="utf-8"))
            self.assertEqual(state["last_event_id"], json.loads(events[-1])["event_id"])

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
            (repo / ".codex/delivery/policy.yml").write_text("declared_scope:\n  - src/**\n", encoding="utf-8")
            (repo / "docs.md").write_text("out of scope\n", encoding="utf-8")

            code, output = self.run_cli(["--repo", str(repo), "gate", "declared-scope"])

            self.assertEqual(code, 1)
            self.assertIn("outside declared scope", output)

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
                    ".codex/delivery/handoff.md",
                    "--evidence-event",
                    "tool.finished",
                ],
            )

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

    def test_default_runtime_files_do_not_fail_their_own_leak_gate(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.init_git_repo(repo)
            self.run_cli(["--repo", str(repo), "init"])

            code, output = self.run_cli(["--repo", str(repo), "gate", "leaks"])

            self.assertEqual(code, 0)
            self.assertIn("leaks: passed", output)


if __name__ == "__main__":
    unittest.main()
