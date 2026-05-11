import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import agentic_project


class AgenticProjectCliTests(unittest.TestCase):
    def run_cli(self, argv: list[str]) -> str:
        output = StringIO()
        with redirect_stdout(output):
            code = agentic_project.main(argv)
        self.assertEqual(code, 0)
        return output.getvalue()

    def test_list_assets_includes_reusable_media_pack(self) -> None:
        output = self.run_cli(["list-assets"])

        self.assertIn("media-r2-s3", output)
        self.assertIn("third-party-evaluated", output)

    def test_evaluate_auth_records_tradeoffs(self) -> None:
        output = self.run_cli(["evaluate", "--domain", "auth", "--stack", "nextjs-fullstack"])

        self.assertIn("Auth.js", output)
        self.assertIn("Clerk", output)
        self.assertIn("auth-evaluated", output)

    def test_init_writes_orocsy_runtime_workflow_and_start_guard(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.run_cli(
                [
                    "init",
                    "--repo",
                    str(repo),
                    "--project-name",
                    "Runtime App",
                    "--linear-project-slug",
                    "runtime-app-project",
                ],
            )

            workflow = (repo / ".codex/symphony/WORKFLOW.concurrent-symphony.md").read_text(encoding="utf-8")
            self.assertIn("symphony prepare-workspace", workflow)
            self.assertIn("before_run", workflow)
            self.assertIn("Review hardening trigger", workflow)
            self.assertIn("OROCSY_CLI", workflow)
            self.assertIn("granular:", workflow)
            self.assertIn("rules: false", workflow)
            self.assertIn("mcp_elicitations: true", workflow)
            self.assertNotIn("approval_policy: never", workflow)
            self.assertNotIn("reject:", workflow)

            start_script = (repo / ".codex/symphony/start-symphony.sh").read_text(encoding="utf-8")
            self.assertIn("$HOME/src/orocsy-symphony", start_script)
            self.assertIn("orocsy/symphony", start_script)
            self.assertIn("Refusing to run legacy Symphony workflow", start_script)
            self.assertIn("granular.rules must be false", start_script)
            self.assertIn("mix escript.build", start_script)

    def test_init_upgrades_legacy_symphony_workflow_without_force(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            workflow = repo / ".codex/symphony/WORKFLOW.concurrent-symphony.md"
            workflow.parent.mkdir(parents=True)
            workflow.write_text(
                """---
tracker:
  kind: linear
codex:
  command: codex app-server
  approval_policy: never
---
Primitive workflow.
""",
                encoding="utf-8",
            )
            start_script = repo / ".codex/symphony/start-symphony.sh"
            start_script.write_text(
                'SYMPHONY_REPO="${SYMPHONY_REPO:-$HOME/src/openai-symphony}"\n',
                encoding="utf-8",
            )

            output = self.run_cli(
                [
                    "init",
                    "--repo",
                    str(repo),
                    "--project-name",
                    "Runtime App",
                    "--linear-project-slug",
                    "runtime-app-project",
                ],
            )

            upgraded_workflow = workflow.read_text(encoding="utf-8")
            upgraded_start = start_script.read_text(encoding="utf-8")
            self.assertIn("upgraded legacy workflow", output)
            self.assertIn("upgraded legacy start script", output)
            self.assertIn("symphony prepare-workspace", upgraded_workflow)
            self.assertIn("before_run", upgraded_workflow)
            self.assertIn("Review hardening trigger", upgraded_workflow)
            self.assertIn("granular:", upgraded_workflow)
            self.assertIn("rules: false", upgraded_workflow)
            self.assertNotIn("approval_policy: never", upgraded_workflow)
            self.assertNotIn("reject:", upgraded_workflow)
            self.assertIn("$HOME/src/orocsy-symphony", upgraded_start)
            self.assertIn("mix escript.build", upgraded_start)
            self.assertTrue((repo / ".codex/symphony/WORKFLOW.concurrent-symphony.md.legacy").exists())
            self.assertTrue((repo / ".codex/symphony/start-symphony.sh.legacy").exists())

    def test_scaffold_dry_run_does_not_write_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            output = self.run_cli(
                [
                    "scaffold",
                    "--repo",
                    str(repo),
                    "--project-name",
                    "Dry Run App",
                    "--asset-pack",
                    "media-r2-s3",
                    "--dry-run",
                ],
            )

            self.assertIn("would write", output)
            self.assertFalse((repo / "package.json").exists())

    def test_scaffold_writes_runnable_next_app_and_decisions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.run_cli(
                [
                    "scaffold",
                    "--repo",
                    str(repo),
                    "--project-name",
                    "Asset App",
                    "--asset-pack",
                    "media-r2-s3",
                    "--asset-pack",
                    "auth-evaluated",
                    "--asset-pack",
                    "stripe-billing-evaluated",
                    "--asset-pack",
                    "ci-browser-e2e",
                ],
            )

            self.assertTrue((repo / "package.json").exists())
            self.assertTrue((repo / "next-env.d.ts").exists())
            self.assertTrue((repo / "src/app/page.tsx").exists())
            self.assertTrue((repo / "src/lib/media/object-storage.ts").exists())
            self.assertTrue((repo / "src/app/api/auth/[...nextauth]/route.ts").exists())
            self.assertTrue((repo / "src/lib/billing/webhook.ts").exists())
            self.assertTrue((repo / "playwright.config.ts").exists())

            package = (repo / "package.json").read_text(encoding="utf-8")
            self.assertNotIn('"latest"', package)

            decisions = (repo / "SCAFFOLD_DECISIONS.md").read_text(encoding="utf-8")
            self.assertIn("Rejected alternatives", decisions)
            self.assertIn("Auth.js", decisions)
            self.assertIn("Cloudflare R2", decisions)

            asset_decisions = (repo / ".codex/agentic/ASSET_DECISIONS.yml").read_text(encoding="utf-8")
            self.assertIn("auth-evaluated", asset_decisions)
            self.assertIn("stripe-billing-evaluated", asset_decisions)

            gitignore = (repo / ".gitignore").read_text(encoding="utf-8")
            self.assertIn("*.tsbuildinfo", gitignore)
            self.assertIn(".DS_Store", gitignore)
            self.assertIn(".codex/symphony/*.legacy*", gitignore)

    def test_verify_scaffold_catches_structural_regressions(self) -> None:
        output = self.run_cli(
            [
                "verify-scaffold",
                "--asset-pack",
                "media-r2-s3",
                "--asset-pack",
                "auth-evaluated",
                "--asset-pack",
                "stripe-billing-evaluated",
                "--asset-pack",
                "ci-browser-e2e",
            ],
        )

        self.assertIn("Structural scaffold verification passed.", output)

    def test_unknown_asset_fails_fast(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit):
                agentic_project.main(
                    [
                        "scaffold",
                        "--repo",
                        tmp,
                        "--asset-pack",
                        "not-real",
                    ],
                )


if __name__ == "__main__":
    unittest.main()
