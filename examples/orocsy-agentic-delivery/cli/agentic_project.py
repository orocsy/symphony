#!/usr/bin/env python3
"""Bootstrap reusable agentic delivery assets into a project repo.

This CLI is intentionally dependency-free so any future agent can run it from a
fresh checkout. It installs workflow assets, records stack choices, and can
compose a runnable starter from evaluated code asset packs. The asset path is
deliberately not a blank framework starter: it records which reusable patterns,
third-party integrations, and project overlays were selected.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


STACK_DEFAULT = "next-nest-prisma-postgres-redis"
DEPLOY_DEFAULT = "vercel-plus-managed-backend"


@dataclass(frozen=True)
class PackagePaths:
    root: Path
    skill: Path
    template_root: Path
    stack_root: Path
    deploy_root: Path
    feature_pack_root: Path
    code_asset_root: Path


@dataclass(frozen=True)
class AssetPack:
    name: str
    category: str
    path: Path
    description: str
    source: str
    provides: tuple[str, ...]
    depends_on: tuple[str, ...]
    reject_when: tuple[str, ...]
    default_decision: str
    official_sources: tuple[str, ...]


def package_paths() -> PackagePaths:
    root = Path(__file__).resolve().parents[1]
    skill = root / "skills" / "agentic-delivery-loop"
    top_level_templates = root / "templates"
    nested_templates = skill / "assets" / "templates"
    template_root = top_level_templates if top_level_templates.exists() else nested_templates

    return PackagePaths(
        root=root,
        skill=skill,
        template_root=template_root,
        stack_root=root / "project-templates" / "stacks",
        deploy_root=root / "project-templates" / "deploy",
        feature_pack_root=root / "project-templates" / "feature-packs",
        code_asset_root=root / "project-templates" / "code-assets",
    )


DEFAULT_PROFILE_ASSETS: dict[str, tuple[str, ...]] = {
    "nextjs-fullstack": (
        "nextjs-app-router",
        "env-validation",
        "ui-foundation",
    ),
    "next-nest-prisma-postgres-redis": (
        "nextjs-app-router",
        "env-validation",
        "ui-foundation",
        "ownership-boundary",
    ),
    "api-service": (
        "env-validation",
    ),
}


ASSET_DEPENDENCIES: dict[str, dict[str, str]] = {
    "nextjs-app-router": {
        "next": "^16.2.5",
        "react": "^19.2.6",
        "react-dom": "^19.2.6",
        "zod": "^4.4.3",
    },
    "env-validation": {
        "zod": "^4.4.3",
    },
    "media-r2-s3": {
        "@aws-sdk/client-s3": "^3.600.0",
    },
    "auth-evaluated": {
        "next-auth": "^5.0.0-beta.30",
    },
    "stripe-billing-evaluated": {
        "stripe": "^17.5.0",
    },
}


ASSET_DEV_DEPENDENCIES: dict[str, dict[str, str]] = {
    "nextjs-app-router": {
        "@testing-library/jest-dom": "^6.9.1",
        "@testing-library/react": "^16.3.2",
        "@types/node": "^22.19.3",
        "@types/react": "^19.2.14",
        "@types/react-dom": "^19.2.3",
        "@vitejs/plugin-react": "^6.0.1",
        "eslint": "^9.39.1",
        "eslint-config-next": "^16.2.5",
        "jsdom": "^29.1.1",
        "typescript": "^5.9.3",
        "vitest": "^4.1.5",
    },
    "ci-browser-e2e": {
        "@playwright/test": "^1.57.0",
    },
}


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9_-]+", "-", value.strip()).strip("-").lower()
    return slug or "new-project"


def yaml_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, content: str, *, overwrite: bool, dry_run: bool) -> str:
    if path.exists() and not overwrite:
        return f"skip existing {path}"
    if dry_run:
        return f"would write {path}"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return f"wrote {path}"


def next_backup_path(path: Path, suffix: str) -> Path:
    candidate = path.with_name(f"{path.name}.{suffix}")
    if not candidate.exists():
        return candidate
    index = 1
    while True:
        indexed = path.with_name(f"{path.name}.{suffix}.{index}")
        if not indexed.exists():
            return indexed
        index += 1


def workflow_uses_orocsy_runtime(content: str) -> bool:
    required_markers = [
        "symphony prepare-workspace",
        "before_run",
        "OROCSY_CLI",
        "gate required-evidence",
        "symphony guidance",
        "granular:",
        "rules: false",
    ]
    return (
        all(marker in content for marker in required_markers)
        and "approval_policy: never" not in content
        and "\n    reject:" not in content
    )


def write_workflow_text(path: Path, content: str, *, overwrite: bool, dry_run: bool) -> str:
    if path.exists() and not overwrite:
        existing = read_text(path)
        if workflow_uses_orocsy_runtime(existing):
            return f"skip existing {path}"
        backup = next_backup_path(path, "legacy")
        if dry_run:
            return f"would upgrade legacy workflow {path} and back up to {backup}"
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, backup)
        path.write_text(content, encoding="utf-8")
        return f"upgraded legacy workflow {path} (backup {backup})"
    return write_text(path, content, overwrite=overwrite, dry_run=dry_run)


def start_script_uses_orocsy_runtime(content: str) -> bool:
    required_markers = [
        "$HOME/src/orocsy-symphony",
        "orocsy/symphony",
        "OROCSY_CLI",
        "symphony prepare-workspace",
        "approval_policy: never",
    ]
    return all(marker in content for marker in required_markers)


def write_start_script_text(path: Path, content: str, *, overwrite: bool, dry_run: bool) -> str:
    if path.exists() and not overwrite:
        existing = read_text(path)
        if start_script_uses_orocsy_runtime(existing):
            return f"skip existing {path}"
        backup = next_backup_path(path, "legacy")
        if dry_run:
            return f"would upgrade legacy start script {path} and back up to {backup}"
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, backup)
        path.write_text(content, encoding="utf-8")
        make_executable(path, dry_run=False)
        return f"upgraded legacy start script {path} (backup {backup})"
    result = write_text(path, content, overwrite=overwrite, dry_run=dry_run)
    make_executable(path, dry_run=dry_run)
    return result


def copy_tree(src: Path, dst: Path, *, overwrite: bool, dry_run: bool) -> str:
    if dst.exists() and not overwrite:
        return f"skip existing {dst}"
    if dry_run:
        return f"would copy {src} -> {dst}"
    if dst.exists():
        shutil.rmtree(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(src, dst)
    return f"copied {src} -> {dst}"


def copy_file(src: Path, dst: Path, *, overwrite: bool, dry_run: bool) -> str:
    if dst.exists() and not overwrite:
        return f"skip existing {dst}"
    if dry_run:
        return f"would copy {src} -> {dst}"
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    return f"copied {src} -> {dst}"


def make_executable(path: Path, *, dry_run: bool) -> None:
    if dry_run or not path.exists():
        return
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def profile_exists(root: Path, name: str) -> bool:
    return (root / f"{name}.yml").exists()


def profile_summary(root: Path) -> list[tuple[str, str]]:
    profiles: list[tuple[str, str]] = []
    if not root.exists():
        return profiles
    for path in sorted(root.glob("*.yml")):
        description = ""
        for line in read_text(path).splitlines():
            if line.startswith("description:"):
                description = line.split(":", 1)[1].strip().strip('"')
                break
        profiles.append((path.stem, description))
    return profiles


def parse_simple_manifest(path: Path) -> dict[str, Any]:
    """Parse the small YAML subset used by kit manifests.

    The CLI stays dependency-free on purpose. Manifests may contain top-level
    scalars and top-level string lists. Nested sections remain documentation for
    humans and are preserved in the source file rather than interpreted here.
    """

    result: dict[str, Any] = {}
    current_list_key = ""
    for raw_line in read_text(path).splitlines():
        line = raw_line.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" ") and ":" in line:
            key, value = line.split(":", 1)
            key = key.strip()
            value = value.strip()
            if value:
                result[key] = value.strip('"')
                current_list_key = ""
            else:
                result[key] = []
                current_list_key = key
            continue
        if current_list_key and line.startswith("  - "):
            result[current_list_key].append(line[4:].strip().strip('"'))
    return result


def tuple_field(data: dict[str, Any], key: str) -> tuple[str, ...]:
    value = data.get(key, ())
    if isinstance(value, list):
        return tuple(str(item) for item in value)
    if isinstance(value, str) and value:
        return (value,)
    return ()


def read_asset_pack(path: Path) -> AssetPack:
    data = parse_simple_manifest(path)
    return AssetPack(
        name=str(data.get("name") or path.stem),
        category=path.parent.name,
        path=path,
        description=str(data.get("description") or ""),
        source=str(data.get("source") or path.parent.name),
        provides=tuple_field(data, "provides"),
        depends_on=tuple_field(data, "depends_on"),
        reject_when=tuple_field(data, "reject_when"),
        default_decision=str(data.get("default_decision") or ""),
        official_sources=tuple_field(data, "official_sources"),
    )


def all_asset_packs(paths: PackagePaths) -> list[AssetPack]:
    if not paths.code_asset_root.exists():
        return []
    return [
        read_asset_pack(path)
        for path in sorted(paths.code_asset_root.glob("*/*.yml"))
    ]


def asset_packs_by_name(paths: PackagePaths) -> dict[str, AssetPack]:
    packs = all_asset_packs(paths)
    by_name = {pack.name: pack for pack in packs}
    if len(by_name) != len(packs):
        seen: set[str] = set()
        duplicates: set[str] = set()
        for pack in packs:
            if pack.name in seen:
                duplicates.add(pack.name)
            seen.add(pack.name)
        raise SystemExit(f"Duplicate asset pack names: {', '.join(sorted(duplicates))}")
    return by_name


def asset_exists(paths: PackagePaths, name: str) -> bool:
    return name in asset_packs_by_name(paths)


def resolve_asset_selection(
    paths: PackagePaths,
    profile: str,
    requested_assets: list[str],
    *,
    include_defaults: bool,
) -> list[AssetPack]:
    by_name = asset_packs_by_name(paths)
    requested = list(requested_assets)
    if include_defaults:
        requested = list(DEFAULT_PROFILE_ASSETS.get(profile, ())) + requested

    resolved: list[str] = []
    visiting: set[str] = set()

    def add_asset(name: str) -> None:
        if name not in by_name:
            raise SystemExit(f"Unknown code asset pack: {name}")
        if name in resolved:
            return
        if name in visiting:
            raise SystemExit(f"Cycle in asset dependencies at {name}")
        visiting.add(name)
        for dependency in by_name[name].depends_on:
            add_asset(dependency)
        visiting.remove(name)
        resolved.append(name)

    for asset_name in requested:
        add_asset(asset_name)
    return [by_name[name] for name in resolved]


def merge_dependency_maps(asset_names: set[str], source: dict[str, dict[str, str]]) -> dict[str, str]:
    merged: dict[str, str] = {}
    for asset_name in sorted(asset_names):
        merged.update(source.get(asset_name, {}))
    return dict(sorted(merged.items()))


def format_yaml_list(values: list[str] | tuple[str, ...], indent: str = "  ") -> str:
    if not values:
        return f"{indent}[]"
    return "\n".join(f"{indent}- {yaml_quote(value)}" for value in values)


def render_workflow(template: str, project_slug: str, linear_project_slug: str) -> str:
    workflow = template.replace("<project>", project_slug)
    workflow = workflow.replace("<linear-project-slug>", linear_project_slug or "replace-me")
    return workflow


def render_manifest(args: argparse.Namespace, project_slug: str) -> str:
    feature_packs = args.feature_pack or []
    feature_pack_lines = "\n".join(f"  - {yaml_quote(pack)}" for pack in feature_packs) or "  []"
    return f"""# Generated by agentic_project.py. Edit this file as the project evolves.
project:
  name: {yaml_quote(args.project_name)}
  slug: {yaml_quote(project_slug)}

agentic_delivery:
  skill_mode: {yaml_quote(args.skill_mode)}
  miu_execution_doc: ".codex/agentic/miu-execution.md"
  linear_workstream_template: ".codex/agentic/linear-workstream.md"
  symphony_workflow: ".codex/symphony/WORKFLOW.concurrent-symphony.md"

stack:
  profile: {yaml_quote(args.stack)}
  notes: "Profile records defaults only; verify against real product constraints before implementation."

deployment:
  profile: {yaml_quote(args.deploy)}
  notes: "Deployment profile is selectable and replaceable per project."

workflow:
  mode: {yaml_quote(args.workflow_mode)}
  linear_project_slug: {yaml_quote(args.linear_project_slug or "")}
  symphony_workspace_root: {yaml_quote(args.workspace_root or f"~/.codex/symphony-workspaces/{project_slug}-concurrent")}
  branch_policy: {yaml_quote(args.branch_policy)}

feature_packs:
{feature_pack_lines}

business_boundaries:
  ownership: "TBD"
  actor: "TBD"
  durable_data: "TBD"
  ephemeral_data: "TBD"
  money_value: "TBD"
  time_concurrency: "TBD"
  storage_media: "TBD"
  external_provider: "TBD"
  user_visible_truth: "TBD"
"""


def render_stack_doc(args: argparse.Namespace, project_slug: str, paths: PackagePaths) -> str:
    stack_profile = paths.stack_root / f"{args.stack}.yml"
    deploy_profile = paths.deploy_root / f"{args.deploy}.yml"
    feature_packs = args.feature_pack or []
    feature_pack_docs = []
    for pack in feature_packs:
        path = paths.feature_pack_root / f"{pack}.yml"
        if path.exists():
            feature_pack_docs.append(f"## Feature Pack: {pack}\n\n```yaml\n{read_text(path).strip()}\n```\n")

    return f"""# Project Stack

Project: `{args.project_name}` (`{project_slug}`)

This document records the starting template choices. It is not a frozen
architecture contract. Update it when the real project chooses a different
stack, provider, deployment shape, or business boundary.

## Selected Stack

```yaml
{read_text(stack_profile).strip()}
```

## Selected Deployment

```yaml
{read_text(deploy_profile).strip()}
```

{''.join(feature_pack_docs) if feature_pack_docs else '## Feature Packs\n\nNo feature packs selected yet.\n'}
## Agent Workflow

- Skill: `agentic-delivery-loop`
- MIU trace: `.codex/agentic/miu-execution.md`
- Symphony workflow: `.codex/symphony/WORKFLOW.concurrent-symphony.md`
- Business boundary inventory: fill before implementation.
"""


def render_start_script() -> str:
    return """#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYMPHONY_REPO="${SYMPHONY_REPO:-$HOME/src/orocsy-symphony}"
WORKFLOW_FILE="$ROOT/.codex/symphony/WORKFLOW.concurrent-symphony.md"

for env_file in "$ROOT/.env.local" "$ROOT/.env"; do
  if [[ -f "$env_file" ]]; then
    set -a
    source "$env_file"
    set +a
  fi
done

if [[ ! -d "$SYMPHONY_REPO/elixir" ]]; then
  echo "Missing Symphony Elixir checkout at $SYMPHONY_REPO/elixir" >&2
  exit 1
fi

origin_url="$(git -C "$SYMPHONY_REPO" remote get-url origin 2>/dev/null || true)"
if [[ "$origin_url" != *"orocsy/symphony"* ]]; then
  echo "Refusing to run: SYMPHONY_REPO must point at the orocsy/symphony fork, got origin '$origin_url'." >&2
  exit 1
fi

if git -C "$SYMPHONY_REPO" remote get-url upstream >/dev/null 2>&1; then
  echo "Refusing to run: remove the upstream OpenAI Symphony remote from SYMPHONY_REPO to avoid primitive runner drift." >&2
  exit 1
fi

OROCSY_CLI="${OROCSY_CLI:-$SYMPHONY_REPO/examples/orocsy-agentic-delivery/cli/orocsy.py}"
if [[ ! -f "$OROCSY_CLI" ]]; then
  echo "Missing Orocsy runtime CLI at $OROCSY_CLI" >&2
  exit 1
fi

if ! grep -q "symphony prepare-workspace" "$WORKFLOW_FILE"; then
  echo "Refusing to run legacy Symphony workflow: missing Orocsy prepare-workspace hook." >&2
  echo "Regenerate with: python3 $SYMPHONY_REPO/examples/orocsy-agentic-delivery/cli/agentic_project.py init --repo $ROOT --force" >&2
  exit 1
fi

if ! grep -q "OROCSY_CLI" "$WORKFLOW_FILE"; then
  echo "Refusing to run legacy Symphony workflow: missing OROCSY_CLI worker contract." >&2
  exit 1
fi

if grep -q "\\.codex/delivery/events/events\\.jsonl" "$WORKFLOW_FILE" || grep -q "\\.codex/delivery/state/current\\.json" "$WORKFLOW_FILE"; then
  echo "Refusing to run stale Symphony workflow: mutable Orocsy ledger must live under .orocsy/delivery, not read-only .codex/delivery." >&2
  exit 1
fi

if grep -q "approval_policy: never" "$WORKFLOW_FILE"; then
  echo "Refusing to run unsafe Symphony workflow: approval_policy must request MCP elicitation approval, not use never." >&2
  exit 1
fi

if grep -Eq "^[[:space:]]+reject:" "$WORKFLOW_FILE" || ! grep -q "granular:" "$WORKFLOW_FILE"; then
  echo "Refusing to run stale Symphony workflow: approval_policy must use Codex app-server granular shape." >&2
  exit 1
fi

if grep -Eq "^[[:space:]]+rules:[[:space:]]+true[[:space:]]*$" "$WORKFLOW_FILE"; then
  echo "Refusing to run stale Symphony workflow: codex.approval_policy.granular.rules must be false so workspace file changes do not require human approval." >&2
  exit 1
fi

if ! grep -q "symphony clean-generated" "$WORKFLOW_FILE"; then
  echo "Refusing to run stale Symphony workflow: missing bounded generated-artifact cleanup hook." >&2
  echo "Regenerate with: python3 $SYMPHONY_REPO/examples/orocsy-agentic-delivery/cli/agentic_project.py init --repo $ROOT --force" >&2
  exit 1
fi

if ! grep -q "Symphony browser verification guard" "$WORKFLOW_FILE"; then
  echo "Refusing to run stale Symphony workflow: missing bounded browser verification guard." >&2
  echo "Regenerate with: python3 $SYMPHONY_REPO/examples/orocsy-agentic-delivery/cli/agentic_project.py init --repo $ROOT --force" >&2
  exit 1
fi

if ! grep -q "Symphony handoff recovery guard" "$WORKFLOW_FILE"; then
  echo "Refusing to run stale Symphony workflow: missing handoff recovery guard for push/GitHub/Linear failures." >&2
  echo "Regenerate with: python3 $SYMPHONY_REPO/examples/orocsy-agentic-delivery/cli/agentic_project.py init --repo $ROOT --force" >&2
  exit 1
fi

if ! grep -q "max_turn_total_tokens" "$WORKFLOW_FILE"; then
  echo "Refusing to run stale Symphony workflow: missing live Codex turn token budget guard." >&2
  echo "Regenerate with: python3 $SYMPHONY_REPO/examples/orocsy-agentic-delivery/cli/agentic_project.py init --repo $ROOT --force" >&2
  exit 1
fi

if ! grep -q "forbidden_command_patterns" "$WORKFLOW_FILE" || ! grep -Eq "pnpm.*dev|playwright.*install" "$WORKFLOW_FILE"; then
  echo "Refusing to run stale Symphony workflow: missing non-interactive command guard for raw dev-server/browser-install commands." >&2
  echo "Regenerate with: python3 $SYMPHONY_REPO/examples/orocsy-agentic-delivery/cli/agentic_project.py init --repo $ROOT --force" >&2
  exit 1
fi

linear_token_var="LINEAR""_API""_KEY"
if [[ -z "${!linear_token_var:-}" ]]; then
  printf 'Missing %s. Add it to .env.local or export it before starting Symphony.\\n' "$linear_token_var" >&2
  exit 1
fi

if [[ -z "${PROJECT_REPO:-}" ]]; then
  PROJECT_REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
fi

if [[ -z "${PROJECT_REPO:-}" ]]; then
  echo "PROJECT_REPO is not set and no git origin remote was found." >&2
  exit 1
fi

export PROJECT_REPO
export PROJECT_BASE_BRANCH="${PROJECT_BASE_BRANCH:-main}"
export OROCSY_CLI
export SYMPHONY_REPO
export NPM_CONFIG_CACHE="${NPM_CONFIG_CACHE:-.orocsy/runtime/npm-cache}"
export npm_config_cache="${npm_config_cache:-$NPM_CONFIG_CACHE}"
export NPM_CONFIG_STORE_DIR="${NPM_CONFIG_STORE_DIR:-.orocsy/runtime/pnpm-store}"
export npm_config_store_dir="${npm_config_store_dir:-$NPM_CONFIG_STORE_DIR}"
export PLAYWRIGHT_BROWSERS_PATH=0

cd "$SYMPHONY_REPO/elixir"
mise exec -- mix escript.build
exec mise exec -- ./bin/symphony "$WORKFLOW_FILE" --i-understand-that-this-will-be-running-without-the-usual-guardrails
"""


def render_package_json(project_slug: str, asset_names: set[str]) -> str:
    dependencies = merge_dependency_maps(asset_names, ASSET_DEPENDENCIES)
    dev_dependencies = merge_dependency_maps(asset_names, ASSET_DEV_DEPENDENCIES)
    package = {
        "name": project_slug,
        "private": True,
        "version": "0.1.0",
        "type": "module",
        "scripts": {
            "dev": "next dev",
            "build": "next build",
            "start": "next start",
            "lint": "eslint .",
            "typecheck": "tsc --noEmit",
            "test": "vitest run",
            "test:watch": "vitest",
        },
        "dependencies": dependencies,
        "devDependencies": dev_dependencies,
    }
    if "ci-browser-e2e" in asset_names:
        package["scripts"]["e2e"] = "playwright test"
    return json.dumps(package, indent=2) + "\n"


def render_env(project_name: str, asset_names: set[str]) -> str:
    fields = [
        "  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),",
        f"  NEXT_PUBLIC_APP_NAME: z.string().min(1).default({project_name!r}),",
    ]
    if "media-r2-s3" in asset_names:
        fields.extend(
            [
                "  MEDIA_BUCKET: z.string().optional(),",
                "  MEDIA_REGION: z.string().default('auto'),",
                "  MEDIA_ENDPOINT: z.string().url().optional(),",
                "  MEDIA_PUBLIC_BASE_URL: z.string().url().optional(),",
                "  MEDIA_ACCESS_KEY_ID: z.string().optional(),",
                "  MEDIA_SECRET_ACCESS_KEY: z.string().optional(),",
            ]
        )
    if "auth-evaluated" in asset_names:
        fields.extend(
            [
                "  AUTH_SECRET: z.string().optional(),",
                "  AUTH_TRUST_HOST: z.string().optional(),",
            ]
        )
    if "stripe-billing-evaluated" in asset_names:
        fields.extend(
            [
                "  STRIPE_SECRET_KEY: z.string().optional(),",
                "  STRIPE_WEBHOOK_SECRET: z.string().optional(),",
                "  NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY: z.string().optional(),",
            ]
        )

    return f"""import {{ z }} from "zod";

export const envSchema = z.object({{
{chr(10).join(fields)}
}});

export type AppEnv = z.infer<typeof envSchema>;

export function parseEnv(source: Record<string, string | undefined> = process.env): AppEnv {{
  return envSchema.parse(source);
}}

export const env = parseEnv();
"""


def render_env_example(project_name: str, asset_names: set[str]) -> str:
    lines = [
        f"NEXT_PUBLIC_APP_NAME={project_name}",
        "",
        "# Optional until the corresponding asset pack is configured.",
    ]
    if "auth-evaluated" in asset_names:
        lines.extend(
            [
                "AUTH_SECRET=",
                "AUTH_TRUST_HOST=true",
                "",
            ]
        )
    if "media-r2-s3" in asset_names:
        lines.extend(
            [
                "MEDIA_BUCKET=",
                "MEDIA_REGION=auto",
                "MEDIA_ENDPOINT=",
                "MEDIA_PUBLIC_BASE_URL=",
                "MEDIA_ACCESS_KEY_ID=",
                "MEDIA_SECRET_ACCESS_KEY=",
                "",
            ]
        )
    if "stripe-billing-evaluated" in asset_names:
        lines.extend(
            [
                "STRIPE_SECRET_KEY=",
                "STRIPE_WEBHOOK_SECRET=",
                "NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY=",
                "",
            ]
        )
    return "\n".join(lines).rstrip() + "\n"


def asset_decision_rejections(asset_name: str) -> list[str]:
    if asset_name == "auth-evaluated":
        return [
            "Clerk is not the default because hosted auth can trade away UI control and creates provider lock-in; choose it only when speed and hosted identity win.",
            "Custom auth is not the default because generic login/session behavior is security-sensitive and mature OSS/provider implementations reduce risk.",
        ]
    if asset_name == "stripe-billing-evaluated":
        return [
            "Third-party billing wrappers are not the default because Stripe's official SDK plus explicit domain ports keeps webhook and entitlement behavior auditable.",
            "Copying any previous plan rules is rejected unless the new project has the same SaaS billing model.",
        ]
    if asset_name == "media-r2-s3":
        return [
            "Provider-specific blob storage is not the default because the S3-compatible boundary keeps R2/S3/MinIO replaceable.",
            "Browser blob URLs are rejected as durable state; only API/object-storage URLs may be persisted.",
        ]
    if asset_name == "ui-foundation":
        return [
            "Project-specific branding is rejected as a default; only token discipline and primitive structure are reusable.",
        ]
    return []


def render_asset_decisions_yaml(
    project_name: str,
    project_slug: str,
    profile: str,
    assets: list[AssetPack],
) -> str:
    lines = [
        "# Generated by agentic_project.py scaffold. Update when asset choices change.",
        "project:",
        f"  name: {yaml_quote(project_name)}",
        f"  slug: {yaml_quote(project_slug)}",
        f"profile: {yaml_quote(profile)}",
        "selected_assets:",
    ]
    for asset in assets:
        lines.extend(
            [
                f"  - name: {yaml_quote(asset.name)}",
                f"    category: {yaml_quote(asset.category)}",
                f"    source: {yaml_quote(asset.source)}",
                f"    decision: {yaml_quote(asset.default_decision or 'Selected for this scaffold.')}",
                "    provides:",
                format_yaml_list(list(asset.provides), "      "),
                "    rejected_alternatives:",
                format_yaml_list(asset_decision_rejections(asset.name), "      "),
            ]
        )
    return "\n".join(lines) + "\n"


def render_scaffold_decisions(
    project_name: str,
    project_slug: str,
    profile: str,
    assets: list[AssetPack],
) -> str:
    sections = [
        "# Scaffold Decisions",
        "",
        f"Project: `{project_name}` (`{project_slug}`)",
        f"Profile: `{profile}`",
        "",
        "This file records why the scaffold used these code assets. It should be updated when the project chooses different providers, business boundaries, or code ownership.",
        "",
        "## Selected Assets",
        "",
    ]
    for asset in assets:
        sections.extend(
            [
                f"### {asset.name}",
                "",
                f"- Category: `{asset.category}`",
                f"- Source: `{asset.source}`",
                f"- Decision: {asset.default_decision or 'Selected for this scaffold.'}",
            ]
        )
        if asset.provides:
            sections.append(f"- Provides: {', '.join(asset.provides)}")
        if asset.official_sources:
            sections.append(f"- Official sources: {', '.join(asset.official_sources)}")
        rejections = asset_decision_rejections(asset.name)
        if rejections:
            sections.append("- Rejected alternatives:")
            sections.extend(f"  - {rejection}" for rejection in rejections)
        sections.append("")
    sections.extend(
        [
            "## Next Evaluation Pass",
            "",
            "- Run `agentic_project evaluate --domain auth --stack nextjs-fullstack` before locking auth.",
            "- Run `agentic_project providers doctor` before creating cloud resources.",
            "- Keep `.env.example` public and put real secrets only in local/provider secret stores.",
        ]
    )
    return "\n".join(sections) + "\n"


def render_provider_setup(asset_names: set[str]) -> str:
    sections = [
        "# Provider Setup",
        "",
        "Generated guidance only. Do not paste secrets into tracked files.",
        "",
        "## Doctor",
        "",
        "Run:",
        "",
        "```bash",
        "python3 docs/agentic-delivery-kit/cli/agentic_project.py providers doctor --repo .",
        "```",
        "",
    ]
    if "media-r2-s3" in asset_names:
        sections.extend(
            [
                "## Media Storage",
                "",
                "- Preferred dev path: Cloudflare R2 or S3-compatible storage with least-privilege access keys.",
                "- Required env: `MEDIA_BUCKET`, `MEDIA_ENDPOINT`, `MEDIA_PUBLIC_BASE_URL`, `MEDIA_ACCESS_KEY_ID`, `MEDIA_SECRET_ACCESS_KEY`.",
                "- Use Codex Cloudflare MCP when available; otherwise use the Cloudflare dashboard or `wrangler`.",
                "",
            ]
        )
    if "auth-evaluated" in asset_names:
        sections.extend(
            [
                "## Auth",
                "",
                "- Default scaffold path: Auth.js-compatible config for free/open-source and UI-customizable auth.",
                "- Re-evaluate Clerk when hosted social login and low ops are more important than lock-in.",
                "- Required env before production: `AUTH_SECRET` and provider-specific client secrets.",
                "",
            ]
        )
    if "stripe-billing-evaluated" in asset_names:
        sections.extend(
            [
                "## Stripe",
                "",
                "- Use Stripe test mode first.",
                "- Required env: `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY`.",
                "- Webhook handlers must verify signatures and store idempotency/replay state before changing entitlements.",
                "",
            ]
        )
    if "ci-browser-e2e" in asset_names:
        sections.extend(
            [
                "## CI / Browser Evidence",
                "",
                "- Run unit/type/lint checks on every PR.",
                "- Run Playwright smoke tests after the dev server starts.",
                "- Attach screenshots or browser evidence to MIU handoffs for UI-impacting work.",
                "",
            ]
        )
    return "\n".join(sections)


def base_scaffold_files(project_name: str, project_slug: str, asset_names: set[str]) -> dict[Path, str]:
    return {
        Path("package.json"): render_package_json(project_slug, asset_names),
        Path(".gitignore"): """node_modules
.next
out
coverage
playwright-report
test-results
*.tsbuildinfo
.DS_Store
.env
.env.local
.env.*.local
.orocsy/delivery/
.orocsy/runtime/
.pnpm-store/
.codex/delivery/
.codex/symphony/*.legacy*
""",
        Path("next-env.d.ts"): """/// <reference types="next" />
/// <reference types="next/image-types/global" />

// This file is generated by the agentic delivery scaffold and kept in git so
// TypeScript and Next.js agree before the first local build.
""",
        Path("tsconfig.json"): """{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["dom", "dom.iterable", "es2022"],
    "allowJs": false,
    "skipLibCheck": true,
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "module": "esnext",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "react-jsx",
    "incremental": true,
    "plugins": [{ "name": "next" }],
    "paths": { "@/*": ["./src/*"] }
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts", ".next/dev/types/**/*.ts"],
  "exclude": ["node_modules"]
}
""",
        Path("next.config.mjs"): """/** @type {import('next').NextConfig} */
const nextConfig = {};

export default nextConfig;
""",
        Path("eslint.config.mjs"): """import nextVitals from "eslint-config-next/core-web-vitals";
import nextTypescript from "eslint-config-next/typescript";

const config = [
  ...nextVitals,
  ...nextTypescript,
  {
    ignores: [
      ".codex/**",
      ".orocsy/**",
      "design/**",
      "Design/**",
      "*Design/**",
      "**/*.html",
    ],
  },
];

export default config;
""",
        Path("vitest.config.ts"): """import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [react()],
  resolve: {
    tsconfigPaths: true,
  },
  test: {
    environment: "jsdom",
    globals: true,
    include: ["tests/unit/**/*.test.ts", "tests/unit/**/*.spec.ts", "tests/integration/**/*.test.ts", "tests/integration/**/*.spec.ts"],
    setupFiles: ["./vitest.setup.ts"],
  },
});
""",
        Path("vitest.setup.ts"): """import "@testing-library/jest-dom/vitest";
""",
        Path("src/app/layout.tsx"): f"""import type {{ Metadata }} from "next";
import "./globals.css";

export const metadata: Metadata = {{
  title: "{project_name}",
  description: "Agentic project scaffold",
}};

export default function RootLayout({{
  children,
}}: Readonly<{{
  children: React.ReactNode;
}}>) {{
  return (
    <html lang="en">
      <body>{{children}}</body>
    </html>
  );
}}
""",
        Path("src/app/page.tsx"): f"""import {{ Card }} from "@/components/ui/card";
import {{ env }} from "@/lib/env";

const scaffoldSignals = [
  "MIU trace ready",
  "Asset decisions recorded",
  "Provider setup is guided",
];

export default function Home() {{
  return (
    <main className="page-shell">
      <section className="hero">
        <p className="eyebrow">Agentic scaffold</p>
        <h1>{{env.NEXT_PUBLIC_APP_NAME || "{project_name}"}}</h1>
        <p>
          A reusable project base composed from evaluated code assets, not a
          blank framework starter.
        </p>
      </section>
      <section className="signal-grid" aria-label="Scaffold readiness">
        {{scaffoldSignals.map((signal) => (
          <Card key={{signal}}>{{signal}}</Card>
        ))}}
      </section>
    </main>
  );
}}
""",
        Path("src/app/globals.css"): """:root {
  --color-bg: #f8fafc;
  --color-panel: #ffffff;
  --color-text: #111827;
  --color-muted: #4b5563;
  --color-border: #d1d5db;
  --color-accent: #2563eb;
  --radius-card: 8px;
  --shadow-panel: 0 12px 30px rgba(15, 23, 42, 0.08);
}

* {
  box-sizing: border-box;
}

html,
body {
  margin: 0;
  min-height: 100%;
  background: var(--color-bg);
  color: var(--color-text);
  font-family: Arial, Helvetica, sans-serif;
}

.page-shell {
  width: min(960px, calc(100% - 32px));
  margin: 0 auto;
  padding: 64px 0;
}

.hero {
  display: grid;
  gap: 16px;
  margin-bottom: 32px;
}

.eyebrow {
  margin: 0;
  color: var(--color-accent);
  font-size: 0.875rem;
  font-weight: 700;
  text-transform: uppercase;
}

h1 {
  max-width: 760px;
  margin: 0;
  font-size: 3rem;
  line-height: 1.05;
}

p {
  max-width: 680px;
  margin: 0;
  color: var(--color-muted);
  font-size: 1rem;
  line-height: 1.6;
}

.signal-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 16px;
}

.ui-card {
  min-height: 104px;
  padding: 20px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-card);
  background: var(--color-panel);
  box-shadow: var(--shadow-panel);
  font-weight: 700;
}

@media (max-width: 720px) {
  .page-shell {
    width: min(100% - 24px, 960px);
    padding: 40px 0;
  }

  h1 {
    font-size: 2.25rem;
  }

  .signal-grid {
    grid-template-columns: 1fr;
  }
}
""",
        Path("src/components/ui/card.tsx"): """import type { PropsWithChildren } from "react";

export function Card({ children }: PropsWithChildren) {
  return <div className="ui-card">{children}</div>;
}
""",
        Path("src/components/ui/button.tsx"): """import type { ButtonHTMLAttributes } from "react";

export function Button(props: ButtonHTMLAttributes<HTMLButtonElement>) {
  return <button {...props} />;
}
""",
        Path("src/components/ui/index.ts"): """export { Button } from "./button";
export { Card } from "./card";
""",
        Path("src/lib/env.ts"): render_env(project_name, asset_names),
        Path("src/lib/runtime-boundaries.ts"): """export type BusinessBoundary = {
  name: string;
  applies: boolean;
  invariant: string;
};

export const initialBusinessBoundaries: BusinessBoundary[] = [
  {
    name: "ownership",
    applies: false,
    invariant: "Fill before implementation when the project has tenants, teams, accounts, or customer-owned data.",
  },
  {
    name: "external-provider",
    applies: false,
    invariant: "Provider calls need idempotency, rate limits, secret boundaries, and replay handling.",
  },
  {
    name: "user-visible-truth",
    applies: true,
    invariant: "The UI must not promise a state the backend or provider has not made durable.",
  },
];
""",
        Path("tests/unit/env.test.ts"): """import { describe, expect, it } from "vitest";
import { parseEnv } from "@/lib/env";

describe("parseEnv", () => {
  it("keeps the starter runnable before provider secrets are configured", () => {
    expect(parseEnv({}).NEXT_PUBLIC_APP_NAME).toBeTruthy();
  });
});
""",
        Path(".env.example"): render_env_example(project_name, asset_names),
    }


def media_scaffold_files() -> dict[Path, str]:
    return {
        Path("src/lib/media/media-file-validation.ts"): """export type MediaValidationRule = {
  maxBytes: number;
  allowedMimeTypes: readonly string[];
};

export const defaultMediaValidationRule: MediaValidationRule = {
  maxBytes: 8 * 1024 * 1024,
  allowedMimeTypes: ["image/jpeg", "image/png", "image/webp", "image/gif"],
};

export function validateMediaFile(
  file: { size: number; type: string },
  rule: MediaValidationRule = defaultMediaValidationRule,
): string[] {
  const errors: string[] = [];
  if (file.size > rule.maxBytes) {
    errors.push(`File must be ${rule.maxBytes} bytes or smaller.`);
  }
  if (!rule.allowedMimeTypes.includes(file.type)) {
    errors.push(`Unsupported media type: ${file.type}`);
  }
  return errors;
}
""",
        Path("src/lib/media/media-url.ts"): """export function assertDurableMediaUrl(url: string): string {
  if (url.startsWith("blob:")) {
    throw new Error("Browser blob URLs are preview-only and must never be persisted.");
  }
  if (!url.startsWith("/media/") && !url.startsWith("https://") && !url.startsWith("http://")) {
    throw new Error(`Unsupported durable media URL: ${url}`);
  }
  return url;
}

export function buildMediaPath(parts: readonly string[]): string {
  const safeParts = parts.map((part) => encodeURIComponent(part));
  return `/media/${safeParts.join("/")}`;
}
""",
        Path("src/lib/media/object-storage.ts"): """import {
  DeleteObjectCommand,
  PutObjectCommand,
  S3Client,
  type PutObjectCommandInput,
} from "@aws-sdk/client-s3";
import { env, type AppEnv } from "@/lib/env";

export type ObjectStorageConfig = {
  bucket: string;
  region: string;
  endpoint: string;
  publicBaseUrl: string;
  accessKeyId: string;
  secretAccessKey: string;
};

export function getObjectStorageConfig(source: AppEnv = env): ObjectStorageConfig {
  const missing = [
    ["MEDIA_BUCKET", source.MEDIA_BUCKET],
    ["MEDIA_ENDPOINT", source.MEDIA_ENDPOINT],
    ["MEDIA_PUBLIC_BASE_URL", source.MEDIA_PUBLIC_BASE_URL],
    ["MEDIA_ACCESS_KEY_ID", source.MEDIA_ACCESS_KEY_ID],
    ["MEDIA_SECRET_ACCESS_KEY", source.MEDIA_SECRET_ACCESS_KEY],
  ].filter(([, value]) => !value);

  if (missing.length > 0) {
    throw new Error(`Missing media storage env: ${missing.map(([key]) => key).join(", ")}`);
  }

  return {
    bucket: source.MEDIA_BUCKET!,
    region: source.MEDIA_REGION,
    endpoint: source.MEDIA_ENDPOINT!,
    publicBaseUrl: source.MEDIA_PUBLIC_BASE_URL!,
    accessKeyId: source.MEDIA_ACCESS_KEY_ID!,
    secretAccessKey: source.MEDIA_SECRET_ACCESS_KEY!,
  };
}

export function createObjectStorageClient(config = getObjectStorageConfig()): S3Client {
  return new S3Client({
    region: config.region,
    endpoint: config.endpoint,
    forcePathStyle: true,
    credentials: {
      accessKeyId: config.accessKeyId,
      secretAccessKey: config.secretAccessKey,
    },
  });
}

export async function putMediaObject(input: {
  key: string;
  body: PutObjectCommandInput["Body"];
  contentType: string;
  cacheControl?: string;
  client?: S3Client;
  config?: ObjectStorageConfig;
}): Promise<string> {
  const config = input.config ?? getObjectStorageConfig();
  const client = input.client ?? createObjectStorageClient(config);
  await client.send(
    new PutObjectCommand({
      Bucket: config.bucket,
      Key: input.key,
      Body: input.body,
      ContentType: input.contentType,
      CacheControl: input.cacheControl ?? "public, max-age=31536000, immutable",
    }),
  );
  return `${config.publicBaseUrl.replace(/\\/$/, "")}/${input.key}`;
}

export async function deleteMediaObject(input: {
  key: string;
  client?: S3Client;
  config?: ObjectStorageConfig;
}): Promise<void> {
  const config = input.config ?? getObjectStorageConfig();
  const client = input.client ?? createObjectStorageClient(config);
  await client.send(new DeleteObjectCommand({ Bucket: config.bucket, Key: input.key }));
}
""",
        Path("tests/unit/media-url.test.ts"): """import { describe, expect, it } from "vitest";
import { assertDurableMediaUrl, buildMediaPath } from "@/lib/media/media-url";

describe("media-url", () => {
  it("rejects browser-local blob URLs as durable state", () => {
    expect(() => assertDurableMediaUrl("blob:http://localhost/preview")).toThrow(/preview-only/);
  });

  it("builds API-hosted media paths", () => {
    expect(buildMediaPath(["tenants", "t1", "avatar.png"])).toBe("/media/tenants/t1/avatar.png");
  });
});
""",
    }


def auth_scaffold_files() -> dict[Path, str]:
    return {
        Path("src/auth.ts"): """import NextAuth, { type NextAuthConfig } from "next-auth";

export const authConfig = {
  providers: [],
  session: { strategy: "jwt" },
} satisfies NextAuthConfig;

export const { handlers, auth, signIn, signOut } = NextAuth(authConfig);
""",
        Path("src/app/api/auth/[...nextauth]/route.ts"): """import { handlers } from "@/auth";

export const { GET, POST } = handlers;
""",
        Path("src/lib/auth/auth-boundary.ts"): """export type AuthDecision = {
  strategy: "authjs" | "clerk" | "custom-domain-token";
  reason: string;
  rejected: string[];
};

export const defaultAuthDecision: AuthDecision = {
  strategy: "authjs",
  reason: "Default to free/open-source auth with strong UI control until product needs prove hosted identity is better.",
  rejected: [
    "Clerk by default: faster hosted identity, but less control and more provider lock-in.",
    "Custom auth by default: higher security burden for generic sessions.",
  ],
};
""",
    }


def stripe_scaffold_files() -> dict[Path, str]:
    return {
        Path("src/lib/billing/stripe.ts"): """import Stripe from "stripe";
import { env } from "@/lib/env";

export function createStripeClient(secretKey = env.STRIPE_SECRET_KEY): Stripe {
  if (!secretKey) {
    throw new Error("Missing STRIPE_SECRET_KEY.");
  }
  return new Stripe(secretKey, {
    appInfo: {
      name: "agentic-delivery-kit",
    },
  });
}
""",
        Path("src/lib/billing/webhook.ts"): """import type Stripe from "stripe";
import { env } from "@/lib/env";
import { createStripeClient } from "./stripe";

export function constructStripeEvent(input: {
  payload: string | Buffer;
  signature: string;
  webhookSecret?: string;
  stripe?: Stripe;
}): Stripe.Event {
  const webhookSecret = input.webhookSecret ?? env.STRIPE_WEBHOOK_SECRET;
  if (!webhookSecret) {
    throw new Error("Missing STRIPE_WEBHOOK_SECRET.");
  }
  const stripe = input.stripe ?? createStripeClient();
  return stripe.webhooks.constructEvent(input.payload, input.signature, webhookSecret);
}

export type BillingProjectionInput = {
  providerCustomerId: string;
  providerSubscriptionId: string;
  status: string;
  currentPeriodEnd?: Date;
};
""",
    }


def tenant_scaffold_files() -> dict[Path, str]:
    return {
        Path("src/lib/boundaries/tenant.ts"): """export type TenantScoped<T> = T & { tenantId: string };

export function assertSameTenant(left: { tenantId: string }, right: { tenantId: string }): void {
  if (left.tenantId !== right.tenantId) {
    throw new Error("Cross-tenant access rejected.");
  }
}
""",
    }


def booking_concurrency_scaffold_files() -> dict[Path, str]:
    return {
        Path("src/lib/concurrency/slot-lock.ts"): """export type SlotLock = {
  key: string;
  ttlMs: number;
};

export function buildSlotLock(input: {
  scopeId: string;
  resourceId: string;
  startsAtIso: string;
  ttlMs?: number;
}): SlotLock {
  return {
    key: `lock:slot:${input.scopeId}:${input.resourceId}:${input.startsAtIso}`,
    ttlMs: input.ttlMs ?? 5000,
  };
}

export type SerializableWritePlan = {
  lock: SlotLock;
  transactionIsolation: "Serializable";
  recheckInsideTransaction: true;
};

export function planSerializableSlotWrite(lock: SlotLock): SerializableWritePlan {
  return {
    lock,
    transactionIsolation: "Serializable",
    recheckInsideTransaction: true,
  };
}
""",
    }


def ci_scaffold_files() -> dict[Path, str]:
    return {
        Path("playwright.config.ts"): """import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/e2e",
  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL ?? "http://127.0.0.1:3000",
    trace: "on-first-retry",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
""",
        Path("tests/e2e/smoke.spec.ts"): """import { expect, test } from "@playwright/test";

test("home page renders scaffold readiness", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
  await expect(page.getByText("Asset decisions recorded")).toBeVisible();
});
""",
        Path(".github/workflows/ci.yml"): """name: CI

on:
  pull_request:
  push:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
        with:
          version: 9
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - run: pnpm typecheck
      - run: pnpm lint
      - run: pnpm test
""",
    }


def scaffold_files(
    project_name: str,
    project_slug: str,
    profile: str,
    assets: list[AssetPack],
) -> dict[Path, str]:
    asset_names = {asset.name for asset in assets}
    files = base_scaffold_files(project_name, project_slug, asset_names)
    if "media-r2-s3" in asset_names:
        files.update(media_scaffold_files())
    if "auth-evaluated" in asset_names:
        files.update(auth_scaffold_files())
    if "stripe-billing-evaluated" in asset_names:
        files.update(stripe_scaffold_files())
    if "ownership-boundary" in asset_names:
        files.update(tenant_scaffold_files())
    if "scarce-resource-concurrency" in asset_names:
        files.update(booking_concurrency_scaffold_files())
    if "ci-browser-e2e" in asset_names:
        files.update(ci_scaffold_files())

    files[Path(".codex/agentic/ASSET_DECISIONS.yml")] = render_asset_decisions_yaml(
        project_name,
        project_slug,
        profile,
        assets,
    )
    files[Path("SCAFFOLD_DECISIONS.md")] = render_scaffold_decisions(
        project_name,
        project_slug,
        profile,
        assets,
    )
    files[Path("docs/providers/PROVIDER_SETUP.md")] = render_provider_setup(asset_names)
    return files


def write_scaffold_files(
    repo: Path,
    files: dict[Path, str],
    *,
    overwrite: bool,
    dry_run: bool,
) -> list[str]:
    operations: list[str] = []
    for relative_path, content in sorted(files.items(), key=lambda item: str(item[0])):
        operations.append(
            write_text(
                repo / relative_path,
                content,
                overwrite=overwrite,
                dry_run=dry_run,
            )
        )
    return operations


def command_list(_args: argparse.Namespace) -> int:
    paths = package_paths()
    print("Stacks:")
    for name, description in profile_summary(paths.stack_root):
        print(f"  {name}: {description}")
    print("\nDeploy profiles:")
    for name, description in profile_summary(paths.deploy_root):
        print(f"  {name}: {description}")
    print("\nFeature packs:")
    for name, description in profile_summary(paths.feature_pack_root):
        print(f"  {name}: {description}")
    return 0


def command_init(args: argparse.Namespace) -> int:
    paths = package_paths()
    repo = Path(args.repo).expanduser().resolve()
    project_slug = slugify(args.project_name or repo.name)
    args.project_name = args.project_name or repo.name

    if not profile_exists(paths.stack_root, args.stack):
        raise SystemExit(f"Unknown stack profile: {args.stack}")
    if not profile_exists(paths.deploy_root, args.deploy):
        raise SystemExit(f"Unknown deploy profile: {args.deploy}")
    for pack in args.feature_pack or []:
        if not profile_exists(paths.feature_pack_root, pack):
            raise SystemExit(f"Unknown feature pack: {pack}")

    operations: list[str] = []

    agents_template = paths.template_root / "AGENTS.next-project.md"
    workflow_template = paths.root / "WORKFLOW.concurrent-symphony.template.md"
    if not workflow_template.exists():
        workflow_template = paths.template_root / "WORKFLOW.concurrent-symphony.template.md"

    operations.append(
        copy_file(
            agents_template,
            repo / "AGENTS.md",
            overwrite=args.force,
            dry_run=args.dry_run,
        )
    )
    operations.append(
        copy_file(
            paths.template_root / "miu-execution.md",
            repo / ".codex" / "agentic" / "miu-execution.md",
            overwrite=args.force,
            dry_run=args.dry_run,
        )
    )
    operations.append(
        copy_file(
            paths.template_root / "linear-workstream.md",
            repo / ".codex" / "agentic" / "linear-workstream.md",
            overwrite=args.force,
            dry_run=args.dry_run,
        )
    )

    if args.skill_mode in {"project", "both"}:
        operations.append(
            copy_tree(
                paths.skill,
                repo / ".codex" / "skills" / "agentic-delivery-loop",
                overwrite=args.force,
                dry_run=args.dry_run,
            )
        )

    operations.append(
        write_text(
            repo / ".codex" / "agentic" / "PROJECT_STACK.yml",
            render_manifest(args, project_slug),
            overwrite=args.force,
            dry_run=args.dry_run,
        )
    )
    operations.append(
        write_text(
            repo / "PROJECT_STACK.md",
            render_stack_doc(args, project_slug, paths),
            overwrite=args.force,
            dry_run=args.dry_run,
        )
    )
    operations.append(
        write_workflow_text(
            repo / ".codex" / "symphony" / "WORKFLOW.concurrent-symphony.md",
            render_workflow(read_text(workflow_template), project_slug, args.linear_project_slug or ""),
            overwrite=args.force,
            dry_run=args.dry_run,
        )
    )

    start_script = repo / ".codex" / "symphony" / "start-symphony.sh"
    operations.append(
        write_start_script_text(
            start_script,
            render_start_script(),
            overwrite=args.force,
            dry_run=args.dry_run,
        )
    )

    for operation in operations:
        print(operation)

    print("\nNext agent action:")
    print("- Read AGENTS.md and PROJECT_STACK.md.")
    print("- Fill the business boundary inventory before implementation.")
    print("- Use the MIU execution doc for the first non-trivial change.")
    print("- If Symphony is requested, set project-specific environment outside git and run .codex/symphony/start-symphony.sh.")
    return 0


EVALUATION_MATRIX: dict[str, dict[str, Any]] = {
    "auth": {
        "recommendation": "Start from auth-evaluated. Default to Auth.js for free/open-source and UI control; switch to Clerk only when hosted identity speed is worth lock-in.",
        "candidates": [
            "Auth.js: free/open-source, strong UI control, app-owned routes and session decisions.",
            "Clerk: hosted identity, fast social login and org features, but higher lock-in and less deep UI ownership.",
            "Custom domain token/OTP: use only for domain-specific customer flows, not generic admin login.",
        ],
        "assets": ["auth-evaluated"],
        "sources": [
            "https://authjs.dev/getting-started",
            "https://clerk.com/docs/quickstarts/nextjs",
        ],
    },
    "media": {
        "recommendation": "Use media-r2-s3 when uploads are needed. It keeps Cloudflare R2, S3, and local S3-compatible storage replaceable.",
        "candidates": [
            "Reusable S3/R2-compatible boundary: reusable object adapter, durable URL builder, and validation.",
            "Provider-native blob storage: simpler on one platform but weaker portability.",
            "Hosted CMS/media platform: valid when editorial workflows matter more than direct upload ownership.",
        ],
        "assets": ["media-r2-s3"],
        "sources": [
            "https://developers.cloudflare.com/r2/api/s3/api/",
        ],
    },
    "billing": {
        "recommendation": "Use stripe-billing-evaluated. The code should use Stripe's official SDK plus explicit domain ports and idempotent webhook handling.",
        "candidates": [
            "Stripe official SDK with Checkout/Customer Portal/Webhooks.",
            "Third-party billing wrappers: faster in narrow cases but can hide entitlement and webhook edge cases.",
            "Copied previous plan rules: reject unless the new project has the same SaaS billing model.",
        ],
        "assets": ["stripe-billing-evaluated"],
        "sources": [
            "https://docs.stripe.com/checkout",
            "https://docs.stripe.com/webhooks",
        ],
    },
    "ui": {
        "recommendation": "Use ui-foundation for token discipline and primitives, then replace visual brand through the project DESIGN.md.",
        "candidates": [
            "Reusable token discipline and primitive shape.",
            "shadcn/ui: strong OSS component base when the project wants Tailwind/Radix conventions.",
            "Fully custom UI: use when brand/product interaction is unusual enough to justify it.",
        ],
        "assets": ["ui-foundation"],
        "sources": [
            "https://ui.shadcn.com/",
        ],
    },
    "ci": {
        "recommendation": "Use ci-browser-e2e when UI or customer-visible behavior exists.",
        "candidates": [
            "Vitest for fast unit checks.",
            "Playwright for browser truth and responsive/customer journey evidence.",
            "Provider preview smoke checks after deployment is selected.",
        ],
        "assets": ["ci-browser-e2e"],
        "sources": [
            "https://playwright.dev/docs/intro",
        ],
    },
}


def command_list_assets(_args: argparse.Namespace) -> int:
    paths = package_paths()
    by_category: dict[str, list[AssetPack]] = {}
    for asset in all_asset_packs(paths):
        by_category.setdefault(asset.category, []).append(asset)

    for category in sorted(by_category):
        print(f"{category}:")
        for asset in by_category[category]:
            print(f"  {asset.name}: {asset.description}")
        print()
    return 0


def command_evaluate(args: argparse.Namespace) -> int:
    paths = package_paths()
    if not profile_exists(paths.stack_root, args.stack):
        raise SystemExit(f"Unknown stack profile: {args.stack}")
    if args.domain not in EVALUATION_MATRIX:
        known = ", ".join(sorted(EVALUATION_MATRIX))
        raise SystemExit(f"Unknown evaluation domain: {args.domain}. Known domains: {known}")

    evaluation = EVALUATION_MATRIX[args.domain]
    print(f"# Evaluation: {args.domain}")
    print()
    print(f"Stack: `{args.stack}`")
    print()
    print(f"Recommendation: {evaluation['recommendation']}")
    print()
    print("Candidates:")
    for candidate in evaluation["candidates"]:
        print(f"- {candidate}")
    print()
    print("Suggested asset packs:")
    for asset_name in evaluation["assets"]:
        if not asset_exists(paths, asset_name):
            raise SystemExit(f"Evaluation references missing asset pack: {asset_name}")
        print(f"- {asset_name}")
    print()
    print("Official sources to verify during implementation:")
    for source in evaluation["sources"]:
        print(f"- {source}")
    return 0


def command_scaffold(args: argparse.Namespace) -> int:
    paths = package_paths()
    repo = Path(args.repo).expanduser().resolve()
    project_name = args.project_name or repo.name
    project_slug = slugify(project_name)

    if not profile_exists(paths.stack_root, args.profile):
        raise SystemExit(f"Unknown stack/profile: {args.profile}")

    assets = resolve_asset_selection(
        paths,
        args.profile,
        args.asset_pack or [],
        include_defaults=not args.no_default_assets,
    )
    files = scaffold_files(project_name, project_slug, args.profile, assets)
    operations = write_scaffold_files(
        repo,
        files,
        overwrite=args.force,
        dry_run=args.dry_run,
    )
    for operation in operations:
        print(operation)

    print("\nSelected code assets:")
    for asset in assets:
        print(f"- {asset.name} ({asset.category})")
    print("\nNext agent action:")
    print("- Read SCAFFOLD_DECISIONS.md before adding product-specific code.")
    print("- Fill .codex/agentic/ASSET_DECISIONS.yml when changing providers or assets.")
    print("- Run provider doctor before creating cloud resources.")
    return 0


def assert_file_exists(repo: Path, relative_path: str) -> None:
    if not (repo / relative_path).exists():
        raise SystemExit(f"verify-scaffold failed: missing {relative_path}")


def assert_no_latest_dependencies(repo: Path) -> None:
    package = json.loads(read_text(repo / "package.json"))
    for section in ("dependencies", "devDependencies"):
        for name, version in package.get(section, {}).items():
            if version == "latest":
                raise SystemExit(f"verify-scaffold failed: {section}.{name} uses latest")


def assert_no_secret_literals(repo: Path) -> None:
    secret_patterns = [
        "sk" + r"_live_[A-Za-z0-9]+",
        "sk" + r"_test_[A-Za-z0-9]+",
        "AK" + r"IA[0-9A-Z]{16}",
        "-----BEGIN " + "PRIVATE KEY-----",
    ]
    for relative_path in (".env.example", "SCAFFOLD_DECISIONS.md", ".codex/agentic/ASSET_DECISIONS.yml"):
        content = read_text(repo / relative_path)
        for pattern in secret_patterns:
            if re.search(pattern, content):
                raise SystemExit(f"verify-scaffold failed: secret-like literal in {relative_path}")


def verify_scaffold_structure(repo: Path) -> None:
    required_files = [
        "package.json",
        "next-env.d.ts",
        "tsconfig.json",
        "eslint.config.mjs",
        "vitest.config.ts",
        ".env.example",
        ".gitignore",
        "src/app/page.tsx",
        "src/lib/env.ts",
        "tests/unit/env.test.ts",
        "SCAFFOLD_DECISIONS.md",
        ".codex/agentic/ASSET_DECISIONS.yml",
        "docs/providers/PROVIDER_SETUP.md",
    ]
    for relative_path in required_files:
        assert_file_exists(repo, relative_path)

    assert_no_latest_dependencies(repo)
    assert_no_secret_literals(repo)

    gitignore = read_text(repo / ".gitignore")
    if "*.tsbuildinfo" not in gitignore:
        raise SystemExit("verify-scaffold failed: .gitignore must ignore *.tsbuildinfo")
    if ".DS_Store" not in gitignore:
        raise SystemExit("verify-scaffold failed: .gitignore must ignore .DS_Store")
    if ".orocsy/delivery/" not in gitignore:
        raise SystemExit("verify-scaffold failed: .gitignore must ignore .orocsy/delivery/")
    if ".orocsy/runtime/" not in gitignore:
        raise SystemExit("verify-scaffold failed: .gitignore must ignore .orocsy/runtime/")
    if ".pnpm-store/" not in gitignore:
        raise SystemExit("verify-scaffold failed: .gitignore must ignore .pnpm-store/")
    if ".codex/delivery/" not in gitignore:
        raise SystemExit("verify-scaffold failed: .gitignore must ignore .codex/delivery/")

    eslint_config = read_text(repo / "eslint.config.mjs")
    if '".orocsy/**"' not in eslint_config:
        raise SystemExit("verify-scaffold failed: ESLint must ignore Orocsy runtime files")
    if "FlatCompat" in eslint_config:
        raise SystemExit("verify-scaffold failed: generated ESLint config must not use FlatCompat")

    tsconfig = json.loads(read_text(repo / "tsconfig.json"))
    compiler_options = tsconfig.get("compilerOptions", {})
    if compiler_options.get("jsx") != "react-jsx":
        raise SystemExit("verify-scaffold failed: tsconfig jsx should match Next's generated default")
    if ".next/dev/types/**/*.ts" not in tsconfig.get("include", []):
        raise SystemExit("verify-scaffold failed: tsconfig missing .next/dev/types include")

    decisions = read_text(repo / "SCAFFOLD_DECISIONS.md")
    if "Selected Assets" not in decisions or "Next Evaluation Pass" not in decisions:
        raise SystemExit("verify-scaffold failed: SCAFFOLD_DECISIONS.md missing decision sections")


def run_checked(command: list[str], cwd: Path) -> None:
    print(f"$ {' '.join(command)}")
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=False)
    if result.stdout:
        print(result.stdout)
    if result.stderr:
        print(result.stderr, file=sys.stderr)
    if result.returncode != 0:
        raise SystemExit(f"verify-scaffold failed: {' '.join(command)} exited {result.returncode}")


def command_verify_scaffold(args: argparse.Namespace) -> int:
    paths = package_paths()
    if not profile_exists(paths.stack_root, args.profile):
        raise SystemExit(f"Unknown stack/profile: {args.profile}")

    temp_context = tempfile.TemporaryDirectory(prefix="agentic-scaffold-")
    temp_path = Path(temp_context.name)
    repo = temp_path / "repo"
    repo.mkdir(parents=True)

    try:
        project_name = args.project_name or "Scaffold Verify"
        project_slug = slugify(project_name)
        assets = resolve_asset_selection(
            paths,
            args.profile,
            args.asset_pack or [],
            include_defaults=not args.no_default_assets,
        )
        files = scaffold_files(project_name, project_slug, args.profile, assets)
        write_scaffold_files(repo, files, overwrite=True, dry_run=False)
        verify_scaffold_structure(repo)
        print("Structural scaffold verification passed.")

        if args.run_checks:
            package_manager = args.package_manager
            if not shutil.which(package_manager):
                raise SystemExit(f"verify-scaffold failed: package manager not found: {package_manager}")
            run_checked([package_manager, "install"], repo)
            for script in ("typecheck", "test", "lint", "build"):
                run_checked([package_manager, script], repo)
            print("Runtime scaffold verification passed.")

        if args.keep_temp:
            print(f"Kept verification repo: {repo}")
        return 0
    finally:
        if args.keep_temp:
            temp_context._finalizer.detach()
        else:
            temp_context.cleanup()


def selected_asset_names_from_decisions(repo: Path) -> set[str]:
    decision_file = repo / ".codex" / "agentic" / "ASSET_DECISIONS.yml"
    if not decision_file.exists():
        return set()
    names: set[str] = set()
    for line in read_text(decision_file).splitlines():
        stripped = line.strip()
        if stripped.startswith("- name:"):
            names.add(stripped.split(":", 1)[1].strip().strip('"'))
    return names


def command_providers_doctor(args: argparse.Namespace) -> int:
    repo = Path(args.repo).expanduser().resolve()
    asset_names = selected_asset_names_from_decisions(repo)
    print("# Provider Doctor")
    print()
    print(f"Repo: {repo}")
    print(f"Asset decisions found: {'yes' if asset_names else 'no'}")
    if asset_names:
        print(f"Selected assets: {', '.join(sorted(asset_names))}")
    print()
    for command in ["git", "gh", "vercel", "wrangler", "stripe", "aws"]:
        found = shutil.which(command)
        status = "found" if found else "missing"
        print(f"- {command}: {status}{f' ({found})' if found else ''}")
    print()
    print("Secret check: this command only checks variable presence; it never prints values.")
    expected_env = {
        "media-r2-s3": [
            "MEDIA_BUCKET",
            "MEDIA_ENDPOINT",
            "MEDIA_PUBLIC_BASE_URL",
            "MEDIA_ACCESS_KEY_ID",
            "MEDIA_SECRET_ACCESS_KEY",
        ],
        "auth-evaluated": ["AUTH_SECRET"],
        "stripe-billing-evaluated": ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"],
    }
    for asset_name, variables in expected_env.items():
        if asset_name not in asset_names:
            continue
        missing = [variable for variable in variables if not os.environ.get(variable)]
        print(f"- {asset_name}: {'missing ' + ', '.join(missing) if missing else 'env present'}")
    return 0


def command_providers_plan(args: argparse.Namespace) -> int:
    repo = Path(args.repo).expanduser().resolve()
    asset_names = selected_asset_names_from_decisions(repo)
    content = render_provider_setup(asset_names)
    if args.write:
        result = write_text(
            repo / "docs" / "providers" / "PROVIDER_SETUP.md",
            content,
            overwrite=True,
            dry_run=args.dry_run,
        )
        print(result)
    else:
        print(content)
    return 0


def command_providers_apply(args: argparse.Namespace) -> int:
    print("# Provider Apply")
    print()
    print("This kit keeps external mutations behind explicit Codex MCP/CLI approval.")
    print("Current v1 apply mode does not create cloud resources directly.")
    print()
    print("Use this sequence:")
    print("1. Run `providers doctor`.")
    print("2. Run `providers plan --write`.")
    print("3. Ask Codex to use the relevant MCP/CLI for the chosen provider.")
    print()
    print("Supported guided providers: GitHub, Linear, Cloudflare, Stripe, Vercel CLI, AWS CLI/IaC.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Bootstrap agentic delivery assets into a repo.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list", help="List available stack/deploy profiles.")
    list_parser.set_defaults(func=command_list)

    list_assets_parser = subparsers.add_parser("list-assets", help="List reusable code asset packs.")
    list_assets_parser.set_defaults(func=command_list_assets)

    evaluate_parser = subparsers.add_parser("evaluate", help="Evaluate a domain and suggest code asset packs.")
    evaluate_parser.add_argument("--domain", required=True, help="Domain to evaluate, such as auth, media, billing, ui, or ci.")
    evaluate_parser.add_argument("--stack", default="nextjs-fullstack", help="Stack profile name.")
    evaluate_parser.set_defaults(func=command_evaluate)

    init_parser = subparsers.add_parser("init", help="Initialize a project with agentic delivery assets.")
    init_parser.add_argument("--repo", default=os.getcwd(), help="Target repository path.")
    init_parser.add_argument("--project-name", default="", help="Human-readable project name.")
    init_parser.add_argument("--stack", default=STACK_DEFAULT, help="Stack profile name.")
    init_parser.add_argument("--deploy", default=DEPLOY_DEFAULT, help="Deployment profile name.")
    init_parser.add_argument("--feature-pack", action="append", default=[], help="Optional feature pack name. Repeatable.")
    init_parser.add_argument("--workflow-mode", default="symphony-linear", help="Workflow mode label.")
    init_parser.add_argument("--linear-project-slug", default="", help="Tracker project slug for generated workflow.")
    init_parser.add_argument("--workspace-root", default="", help="Symphony workspace root to record in manifest.")
    init_parser.add_argument("--branch-policy", default="per-issue-pr", help="Branch/PR policy label.")
    init_parser.add_argument(
        "--skill-mode",
        choices=["global", "project", "both", "none"],
        default="global",
        help="Whether to copy the skill into the target project.",
    )
    init_parser.add_argument("--force", action="store_true", help="Overwrite existing generated files.")
    init_parser.add_argument("--dry-run", action="store_true", help="Show operations without writing files.")
    init_parser.set_defaults(func=command_init)

    scaffold_parser = subparsers.add_parser("scaffold", help="Generate runnable code from selected asset packs.")
    scaffold_parser.add_argument("--repo", default=os.getcwd(), help="Target repository path.")
    scaffold_parser.add_argument("--project-name", default="", help="Human-readable project name.")
    scaffold_parser.add_argument("--profile", default="nextjs-fullstack", help="Stack profile for default assets.")
    scaffold_parser.add_argument("--asset-pack", action="append", default=[], help="Code asset pack name. Repeatable.")
    scaffold_parser.add_argument("--no-default-assets", action="store_true", help="Do not include profile default assets.")
    scaffold_parser.add_argument("--force", action="store_true", help="Overwrite existing generated files.")
    scaffold_parser.add_argument("--dry-run", action="store_true", help="Show operations without writing files.")
    scaffold_parser.set_defaults(func=command_scaffold)

    verify_parser = subparsers.add_parser(
        "verify-scaffold",
        help="Generate a temp scaffold and verify it before trusting the bootstrap.",
    )
    verify_parser.add_argument("--profile", default="nextjs-fullstack", help="Stack profile for default assets.")
    verify_parser.add_argument("--project-name", default="Scaffold Verify", help="Human-readable temp project name.")
    verify_parser.add_argument("--asset-pack", action="append", default=[], help="Code asset pack name. Repeatable.")
    verify_parser.add_argument("--no-default-assets", action="store_true", help="Do not include profile default assets.")
    verify_parser.add_argument("--run-checks", action="store_true", help="Install dependencies and run typecheck/test/lint/build in the temp repo.")
    verify_parser.add_argument("--package-manager", default="pnpm", help="Package manager command for --run-checks.")
    verify_parser.add_argument("--keep-temp", action="store_true", help="Keep the temp repo for debugging.")
    verify_parser.set_defaults(func=command_verify_scaffold)

    providers_parser = subparsers.add_parser("providers", help="Inspect or plan provider setup.")
    provider_subparsers = providers_parser.add_subparsers(dest="providers_command", required=True)

    doctor_parser = provider_subparsers.add_parser("doctor", help="Check local provider tooling and env presence.")
    doctor_parser.add_argument("--repo", default=os.getcwd(), help="Target repository path.")
    doctor_parser.set_defaults(func=command_providers_doctor)

    plan_parser = provider_subparsers.add_parser("plan", help="Print or write provider setup guidance.")
    plan_parser.add_argument("--repo", default=os.getcwd(), help="Target repository path.")
    plan_parser.add_argument("--write", action="store_true", help="Write docs/providers/PROVIDER_SETUP.md.")
    plan_parser.add_argument("--dry-run", action="store_true", help="Show write operation without writing.")
    plan_parser.set_defaults(func=command_providers_plan)

    apply_parser = provider_subparsers.add_parser("apply", help="Show the guarded provider apply handoff.")
    apply_parser.add_argument("--repo", default=os.getcwd(), help="Target repository path.")
    apply_parser.set_defaults(func=command_providers_apply)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
