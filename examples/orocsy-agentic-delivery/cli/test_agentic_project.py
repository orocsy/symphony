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

        self.assertIn("media-r2-s3-luxebook", output)
        self.assertIn("third-party-evaluated", output)

    def test_evaluate_auth_records_tradeoffs(self) -> None:
        output = self.run_cli(["evaluate", "--domain", "auth", "--stack", "nextjs-fullstack"])

        self.assertIn("Auth.js", output)
        self.assertIn("Clerk", output)
        self.assertIn("auth-evaluated", output)

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
                    "media-r2-s3-luxebook",
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
                    "media-r2-s3-luxebook",
                    "--asset-pack",
                    "auth-evaluated",
                    "--asset-pack",
                    "stripe-billing-evaluated",
                    "--asset-pack",
                    "ci-browser-e2e-luxebook",
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

    def test_verify_scaffold_catches_structural_regressions(self) -> None:
        output = self.run_cli(
            [
                "verify-scaffold",
                "--asset-pack",
                "media-r2-s3-luxebook",
                "--asset-pack",
                "auth-evaluated",
                "--asset-pack",
                "stripe-billing-evaluated",
                "--asset-pack",
                "ci-browser-e2e-luxebook",
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
