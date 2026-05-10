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


if __name__ == "__main__":
    unittest.main()
