import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CLI = Path(__file__).resolve().with_name("orocsy.py")


class OrocsyRuntimeE2ETests(unittest.TestCase):
    def run_cli(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        result = subprocess.run(
            [sys.executable, "-B", str(CLI), *args],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if check and result.returncode != 0:
            self.fail(f"CLI failed with {result.returncode}\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}")
        return result

    def init_git_repo(self, repo: Path) -> None:
        subprocess.run(["git", "init"], cwd=repo, check=True, stdout=subprocess.PIPE)
        subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)

    def commit_all(self, repo: Path, message: str) -> None:
        subprocess.run(["git", "add", "-A"], cwd=repo, check=True, stdout=subprocess.PIPE)
        subprocess.run(["git", "commit", "-m", message], cwd=repo, check=True, stdout=subprocess.PIPE)

    def create_workspace(self, root: Path, name: str) -> Path:
        workspace = root / "sample-project" / name
        workspace.mkdir(parents=True)
        self.init_git_repo(workspace)
        (workspace / "README.md").write_text(f"# {name}\n", encoding="utf-8")
        self.commit_all(workspace, "initial")
        return workspace

    def test_runtime_ledger_gates_and_symphony_monitor_compose(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            symphony_root = Path(tmp)

            clean_workspace = self.create_workspace(symphony_root, "COD-101")
            self.run_cli(
                "--repo",
                str(clean_workspace),
                "symphony",
                "prepare-workspace",
                "--issue",
                "COD-101",
                "--scope",
                "src/**",
                "--evidence-event",
                "tool.finished",
            )
            self.run_cli("--repo", str(clean_workspace), "run", "start", "--issue", "COD-101")
            self.run_cli(
                "--repo",
                str(clean_workspace),
                "event",
                "append",
                "--type",
                "tool.finished",
                "--status",
                "passed",
                "--tool",
                "unit test",
            )
            self.run_cli(
                "--repo",
                str(clean_workspace),
                "eval",
                "record",
                "miu-quality",
                "--status",
                "passed",
                "--summary",
                "MIU contains runtime scenario, data shape, tradeoffs, and validation.",
            )
            self.commit_all(clean_workspace, "runtime-ledger")

            stale_workspace = self.create_workspace(symphony_root, "COD-102")
            self.run_cli("--repo", str(stale_workspace), "symphony", "prepare-workspace", "--issue", "COD-102")
            state_path = stale_workspace / ".codex/delivery/state/current.json"
            state = json.loads(state_path.read_text(encoding="utf-8"))
            state["updated_at"] = "2000-01-01T00:00:00Z"
            state_path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            self.commit_all(stale_workspace, "stale-ledger")

            missing_ledger_workspace = self.create_workspace(symphony_root, "COD-103")

            monitor = self.run_cli(
                "symphony",
                "monitor",
                "--root",
                str(symphony_root),
                "--stale-minutes",
                "1",
                "--strict",
                "--json",
                check=False,
            )

            self.assertEqual(monitor.returncode, 1, monitor.stdout)
            payload = json.loads(monitor.stdout)
            self.assertEqual(payload["status"], "failed")
            self.assertEqual(payload["summary"]["count"], 3)
            self.assertEqual(payload["summary"]["stale"], 1)
            self.assertEqual(payload["summary"]["missing_delivery_state"], 1)

            by_issue = {workspace["issue"] or workspace["name"]: workspace for workspace in payload["workspaces"]}
            self.assertEqual(by_issue["COD-101"]["status"], "running")
            self.assertEqual(by_issue["COD-101"]["events"]["last"]["event"], "eval.miu-quality")
            self.assertTrue(by_issue["COD-102"]["stale"])
            self.assertIn("delivery_state_missing", by_issue["COD-103"]["warnings"])

    def test_dummy_linear_project_requirements_correction_and_guidance_flow(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = self.create_workspace(root, "COD-201")
            issue_file = root / "linear-project" / "COD-201.json"
            issue_file.parent.mkdir()
            issue_file.write_text(
                json.dumps(
                    {
                        "identifier": "COD-201",
                        "title": "Dummy provider setup requirements",
                        "state": "In Progress",
                        "project_slug": "orocsy-runtime-e2e",
                        "write_scope": ["src/**", "evidence/**"],
                        "shared_files": ["package.json"],
                        "dependencies": [],
                        "mius": [
                            {
                                "id": "MIU-1",
                                "summary": "Record provider setup checklist without mutating providers.",
                            },
                        ],
                        "validation": {
                            "files": ["evidence/provider-setup.md"],
                            "events": ["tool.finished", "eval.miu-quality"],
                            "commands": ["unit test"],
                        },
                        "out_of_scope": ["live provider provisioning", "production secrets"],
                    },
                ),
                encoding="utf-8",
            )

            prepared = self.run_cli(
                "--repo",
                str(workspace),
                "symphony",
                "prepare-workspace",
                "--issue-file",
                str(issue_file),
                "--orocsy-cli",
                str(CLI),
                "--json",
            )
            prepared_payload = json.loads(prepared.stdout)
            self.assertEqual(prepared_payload["state"]["issue"], "COD-201")
            self.assertEqual(prepared_payload["state"]["issue_requirements"]["project"], "orocsy-runtime-e2e")

            requirements_gate = self.run_cli(
                "--repo",
                str(workspace),
                "gate",
                "issue-requirements",
                "--strict",
                "--json",
            )
            self.assertEqual(json.loads(requirements_gate.stdout)["status"], "passed")

            evidence_gate = self.run_cli(
                "--repo",
                str(workspace),
                "gate",
                "required-evidence",
                "--strict",
                "--record",
                "--inbox",
                "--json",
                check=False,
            )
            self.assertEqual(evidence_gate.returncode, 1)
            self.assertEqual(json.loads(evidence_gate.stdout)["status"], "failed")

            inbox = self.run_cli("--repo", str(workspace), "inbox", "list", "--open-only", "--json")
            corrections = json.loads(inbox.stdout)["corrections"]
            self.assertEqual(len(corrections), 1)
            self.assertEqual(corrections[0]["next_action"], "block")

            blocked = self.run_cli(
                "symphony",
                "guidance",
                "--workspace",
                str(workspace),
                "--record",
                "--json",
                check=False,
            )
            self.assertEqual(blocked.returncode, 1)
            self.assertEqual(json.loads(blocked.stdout)["action"], "block")

            (workspace / "evidence").mkdir()
            (workspace / "evidence/provider-setup.md").write_text(
                "# Provider Setup Evidence\n\nNo live provider mutation was performed.\n",
                encoding="utf-8",
            )
            self.run_cli(
                "--repo",
                str(workspace),
                "event",
                "append",
                "--type",
                "tool.finished",
                "--status",
                "passed",
                "--tool",
                "unit test",
            )
            self.run_cli(
                "--repo",
                str(workspace),
                "eval",
                "record",
                "miu-quality",
                "--status",
                "passed",
                "--summary",
                "Dummy MIU names requirements, evidence, and provider non-mutation tradeoff.",
            )
            self.run_cli(
                "--repo",
                str(workspace),
                "inbox",
                "resolve",
                corrections[0]["correction_id"],
                "--summary",
                "Evidence file, command event, and MIU eval were recorded.",
            )

            evidence_gate_after = self.run_cli(
                "--repo",
                str(workspace),
                "gate",
                "required-evidence",
                "--strict",
                "--json",
            )
            self.assertEqual(json.loads(evidence_gate_after.stdout)["status"], "passed")

            continued = self.run_cli("symphony", "guidance", "--workspace", str(workspace), "--record", "--json")
            self.assertEqual(json.loads(continued.stdout)["action"], "continue")

            monitor = self.run_cli("symphony", "monitor", "--root", str(root), "--json")
            monitor_payload = json.loads(monitor.stdout)
            self.assertEqual(monitor_payload["summary"]["count"], 1)
            self.assertEqual(monitor_payload["workspaces"][0]["issue"], "COD-201")

            control = self.run_cli("control", "status", "--json")
            self.assertEqual(json.loads(control.stdout)["status"], "deferred")


if __name__ == "__main__":
    unittest.main()
