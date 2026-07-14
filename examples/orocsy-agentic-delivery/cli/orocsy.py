#!/usr/bin/env python3
"""Orocsy Delivery Runtime CLI.

This CLI is intentionally dependency-free. It provides the first runtime slice:
durable run ledgers plus deterministic gates that can be used by Codex,
Symphony workers, cron, or shell wrappers.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DELIVERY_ROOT = Path(".orocsy") / "delivery"
LEGACY_DELIVERY_ROOT = Path(".codex") / "delivery"
LEGACY_MUTABLE_DELIVERY_PREFIX = ".codex/delivery"
MUTABLE_DELIVERY_PREFIX = ".orocsy/delivery"
TOKEN_TELEMETRY_ROOT = DELIVERY_ROOT / "token-telemetry"
SCHEMA_VERSION = 1
HEAD_BOUND_TRANSITION_EVENTS = {"miu.completion_requested", "handoff.requested"}

DEFAULT_FORBIDDEN_TERMS: tuple[str, ...] = ()

DEFAULT_EXCLUDED_DIRS = {
    ".git",
    ".next",
    ".pnpm-store",
    "node_modules",
    "dist",
    "build",
    "coverage",
    "playwright-report",
    "test-results",
    "__pycache__",
}

DEFAULT_ARTIFACT_PATTERNS = (
    ".DS_Store",
    "*.tsbuildinfo",
    ".next/**",
    ".pnpm-store/**",
    "node_modules/**",
    ".orocsy/runtime/**",
    "dist/**",
    "build/**",
    "coverage/**",
    "playwright-report/**",
    "test-results/**",
    "__pycache__/**",
)

DEFAULT_GENERATED_CLEAN_PATHS = (
    ".next/dev",
    ".orocsy/runtime",
    ".pnpm-store",
    "next-env.d.ts",
)

ALLOWED_GENERATED_CLEAN_ROOTS = (
    ".next/dev",
    ".next/cache",
    ".orocsy/runtime",
    ".pnpm-store",
    ".turbo",
    ".vite",
    ".parcel-cache",
    "dist",
    "build",
    "coverage",
    "playwright-report",
    "test-results",
)

ALLOWED_TRACKED_GENERATED_PATHS = (
    "next-env.d.ts",
)

SECRET_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("aws-access-key", re.compile("AK" + r"IA[0-9A-Z]{16}")),
    ("private-key", re.compile("-----BEGIN " + r"[A-Z ]*" + "PRIVATE " + "KEY-----")),
    ("stripe-live-secret", re.compile("sk_" + r"live_[0-9A-Za-z]{16,}")),
    ("github-token", re.compile("gh" + r"p_[0-9A-Za-z]{20,}")),
    ("slack-token", re.compile("xo" + r"x[baprs]-[0-9A-Za-z-]{20,}")),
)

EVAL_RUBRICS: dict[str, dict[str, Any]] = {
    "miu-quality": {
        "title": "Technical MIU Quality",
        "purpose": "Judge whether one implementation unit is concrete enough to execute and review.",
        "pass_rule": "Pass only when the MIU contains runtime context, code/data detail, tradeoffs, and validation evidence.",
        "criteria": [
            "Concrete runtime scenario and user/system action are named.",
            "Current or target code shape is included when code changes are involved.",
            "Data shape, lifetime, and boundary scope are explicit.",
            "Framework, database, browser, or provider constraints are explained.",
            "Chosen approach and rejected alternatives are technically justified.",
            "Tests or validation commands are named with expected proof.",
        ],
        "output_schema": {
            "rubric": "miu-quality",
            "status": "passed|failed|warn",
            "summary": "one paragraph",
            "findings": ["specific missing or weak item"],
            "required_corrections": ["actionable correction"],
        },
    },
    "business-correction": {
        "title": "Business Boundary Correction",
        "purpose": "Judge whether the work preserves real business invariants and user-visible truth.",
        "pass_rule": "Pass only when relevant ownership, actor, value, time, storage, provider, and visible-state boundaries are checked.",
        "criteria": [
            "Relevant project-specific boundaries are named; irrelevant inherited boundaries are not forced.",
            "Actor and permission boundaries match the implemented code path.",
            "Money, quota, entitlement, or scarce-resource semantics are preserved when present.",
            "Race, replay, enumeration, brute-force, and provider-exhaustion paths are considered when relevant.",
            "Durable state is separated from browser-local, process-local, or temporary state.",
            "Customer-visible messages and UI state match backend truth.",
        ],
        "output_schema": {
            "rubric": "business-correction",
            "status": "passed|failed|warn",
            "summary": "one paragraph",
            "boundary_findings": ["boundary risk or confirmation"],
            "required_corrections": ["actionable correction"],
        },
    },
    "review-classification": {
        "title": "Review Comment Classification",
        "purpose": "Judge whether review feedback was classified and resolved without over-expanding scope.",
        "pass_rule": "Pass only when valid comments are fixed, stale/duplicate comments are explained, and scope is preserved.",
        "criteria": [
            "Every actionable review comment is fetched with thread context.",
            "Each comment is classified as valid, stale, duplicate, unclear, or out-of-scope.",
            "Valid findings map to a code/test/documentation change or a clearly recorded reason.",
            "Unclear findings are escalated instead of guessed.",
            "The fix stays inside declared scope unless the scope is explicitly updated.",
            "A re-review or validation command is recorded after fixes.",
        ],
        "output_schema": {
            "rubric": "review-classification",
            "status": "passed|failed|warn",
            "summary": "one paragraph",
            "comments": [{"id": "review/comment id", "classification": "valid|stale|duplicate|unclear|out-of-scope"}],
            "required_corrections": ["actionable correction"],
        },
    },
    "browser-evidence": {
        "title": "Browser Evidence Quality",
        "purpose": "Judge whether UI or customer-visible work was verified in the real browser path.",
        "pass_rule": "Pass only when evidence proves the intended flow, responsive layout, and failure states that matter.",
        "criteria": [
            "The verified route, viewport, locale, and user role are named.",
            "The browser path covers the user-visible behavior changed by the MIU.",
            "Screenshots, traces, console status, or explicit observations are linked or recorded.",
            "Responsive and long-content risks are checked when UI layout changed.",
            "Error, empty, loading, or permission states are checked when relevant.",
            "Evidence is recent enough to match the committed code.",
        ],
        "output_schema": {
            "rubric": "browser-evidence",
            "status": "passed|failed|warn",
            "summary": "one paragraph",
            "evidence": ["artifact path, URL, or observation"],
            "required_corrections": ["actionable correction"],
        },
    },
    "workstream-split-safety": {
        "title": "Workstream Split Safety",
        "purpose": "Judge whether parallel Symphony/Linear work can run without unsafe overlap.",
        "pass_rule": "Pass only when ownership, dependencies, shared files, and handoff contracts are explicit.",
        "criteria": [
            "Each workstream has a clear write scope and owner.",
            "Shared files and cross-workstream contracts are named before dispatch.",
            "Dependencies and sequencing are explicit enough to prevent blocked agents from guessing.",
            "Branch and PR policy matches the user's requested workflow.",
            "Validation responsibilities are assigned without duplicate or missing coverage.",
            "The split preserves business boundaries and does not create inconsistent user-visible flows.",
        ],
        "output_schema": {
            "rubric": "workstream-split-safety",
            "status": "passed|failed|warn",
            "summary": "one paragraph",
            "overlaps": ["file, module, or business boundary overlap"],
            "required_corrections": ["actionable correction"],
        },
    },
}

ISSUE_REQUIREMENT_KEYS = (
    "write_scope",
    "shared_files",
    "dependencies",
    "mius",
    "validation",
    "out_of_scope",
)


@dataclass(frozen=True)
class Finding:
    gate: str
    severity: str
    message: str
    path: str | None = None
    detail: str | None = None

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "gate": self.gate,
            "severity": self.severity,
            "message": self.message,
        }
        if self.path is not None:
            result["path"] = self.path
        if self.detail is not None:
            result["detail"] = self.detail
        return result


@dataclass(frozen=True)
class GateResult:
    gate: str
    status: str
    findings: tuple[Finding, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "gate": self.gate,
            "status": self.status,
            "findings": [finding.to_dict() for finding in self.findings],
        }


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def new_id(prefix: str) -> str:
    return f"{prefix}_{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}_{uuid.uuid4().hex[:8]}"


def repo_path(value: str) -> Path:
    return Path(value).expanduser().resolve()


def delivery_root(repo: Path) -> Path:
    return repo / DELIVERY_ROOT


def legacy_delivery_root(repo: Path) -> Path:
    return repo / LEGACY_DELIVERY_ROOT


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def load_json(path: Path, default: dict[str, Any]) -> dict[str, Any]:
    if not path.exists():
        return dict(default)
    return json.loads(read_text(path))


def write_json(path: Path, data: dict[str, Any]) -> None:
    write_text(path, json.dumps(data, indent=2, sort_keys=True) + "\n")


def parse_simple_list_config(path: Path) -> dict[str, list[str]]:
    """Parse the small YAML subset used by runtime policy files."""

    result: dict[str, list[str]] = {}
    if not path.exists():
        return result

    current_key = ""
    for raw_line in read_text(path).splitlines():
        line = raw_line.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" ") and ":" in line:
            key, value = line.split(":", 1)
            current_key = key.strip()
            value = value.strip()
            if value:
                result[current_key] = [item.strip().strip('"') for item in value.split(",") if item.strip()]
            else:
                result.setdefault(current_key, [])
            continue
        if current_key and line.startswith("  - "):
            result.setdefault(current_key, []).append(line[4:].strip().strip('"'))
    return result


def load_gate_config(repo: Path) -> dict[str, list[str]]:
    root = delivery_root(repo)
    config: dict[str, list[str]] = {}
    for file_name in ("policy.yml", "gates.yml"):
        parsed = parse_simple_list_config(root / file_name)
        for key, values in parsed.items():
            config.setdefault(key, []).extend(values)
    return config


def merge_unique(existing: list[str], additions: list[str]) -> list[str]:
    merged: list[str] = []
    for value in [*existing, *additions]:
        clean = value.strip()
        if clean and clean not in merged:
            merged.append(clean)
    return merged


def render_list_config(header: str, values: dict[str, list[str]]) -> str:
    lines = [header.rstrip(), ""]
    for key, items in values.items():
        lines.append(f"{key}:")
        for item in items:
            lines.append(f"  - {item}")
    return "\n".join(lines).rstrip() + "\n"


def render_eval_rubric_markdown(name: str, rubric: dict[str, Any]) -> str:
    lines = [
        f"# {rubric['title']}",
        "",
        f"Rubric id: `{name}`",
        "",
        "## Purpose",
        "",
        str(rubric["purpose"]),
        "",
        "## Pass Rule",
        "",
        str(rubric["pass_rule"]),
        "",
        "## Criteria",
        "",
    ]
    for criterion in rubric["criteria"]:
        lines.append(f"- {criterion}")
    lines.extend(
        [
            "",
            "## Required Output Schema",
            "",
            "```json",
            json.dumps(rubric["output_schema"], indent=2, sort_keys=True),
            "```",
            "",
        ],
    )
    return "\n".join(lines)


def write_eval_rubrics(repo: Path, *, force: bool = False) -> list[Path]:
    eval_root = delivery_root(repo) / "evals"
    eval_root.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    for name, rubric in EVAL_RUBRICS.items():
        path = eval_root / f"{name}.rubric.md"
        if force or not path.exists():
            write_text(path, render_eval_rubric_markdown(name, rubric))
            written.append(path)
    return written


def as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, tuple):
        return list(value)
    return [value]


def string_list(value: Any) -> list[str]:
    return [str(item).strip() for item in as_list(value) if str(item).strip()]


def normalize_mutable_delivery_path(value: str) -> str:
    text = str(value).strip()
    if text == LEGACY_MUTABLE_DELIVERY_PREFIX:
        return MUTABLE_DELIVERY_PREFIX
    if text.startswith(f"{LEGACY_MUTABLE_DELIVERY_PREFIX}/"):
        return f"{MUTABLE_DELIVERY_PREFIX}/{text[len(LEGACY_MUTABLE_DELIVERY_PREFIX) + 1:]}"
    return text


def normalize_mutable_delivery_paths(values: list[str]) -> list[str]:
    return [normalize_mutable_delivery_path(value) for value in values]


def load_issue_requirements(path: Path) -> dict[str, Any]:
    raw = json.loads(read_text(path))
    validation_raw = raw.get("validation") or {}
    if isinstance(validation_raw, dict):
        validation = {
            "files": normalize_mutable_delivery_paths(
                string_list(validation_raw.get("files") or validation_raw.get("evidence_files"))
            ),
            "events": string_list(validation_raw.get("events") or validation_raw.get("evidence_events")),
            "commands": string_list(validation_raw.get("commands") or validation_raw.get("evidence_commands")),
            "scenarios": string_list(validation_raw.get("scenarios")),
        }
    else:
        validation = {
            "files": [],
            "events": [],
            "commands": [],
            "scenarios": string_list(validation_raw),
        }

    return {
        "identifier": str(raw.get("identifier") or raw.get("issue") or raw.get("id") or "").strip(),
        "issue_revision": str(raw.get("issue_revision") or "").strip(),
        "contract_hash": str(raw.get("contract_hash") or "").strip(),
        "runtime_contract_status": str(raw.get("runtime_contract_status") or "").strip(),
        "title": str(raw.get("title") or "").strip(),
        "state": str(raw.get("state") or raw.get("status") or "").strip(),
        "branch": str(raw.get("branch") or raw.get("branch_name") or raw.get("branchName") or "").strip(),
        "integration_branch": str(raw.get("integration_branch") or "").strip(),
        "project": str(raw.get("project") or raw.get("project_slug") or "").strip(),
        "write_scope": normalize_mutable_delivery_paths(string_list(raw.get("write_scope") or raw.get("writeScope"))),
        "shared_files": normalize_mutable_delivery_paths(string_list(raw.get("shared_files") or raw.get("sharedFiles"))),
        "dependencies": string_list(raw.get("dependencies")),
        "mius": as_list(raw.get("mius") or raw.get("MIUs")),
        "validation": validation,
        "out_of_scope": string_list(raw.get("out_of_scope") or raw.get("outOfScope")),
    }


def update_runtime_config(
    repo: Path,
    *,
    declared_scope: list[str],
    required_files: list[str],
    required_events: list[str],
    required_commands: list[str],
    forbidden_terms: list[str],
) -> None:
    root = delivery_root(repo)
    policy_path = root / "policy.yml"
    gates_path = root / "gates.yml"
    existing_policy = parse_simple_list_config(policy_path)
    existing_gates = parse_simple_list_config(gates_path)

    policy = {
        "declared_scope": merge_unique(
            normalize_mutable_delivery_paths(existing_policy.get("declared_scope", [])),
            normalize_mutable_delivery_paths(declared_scope),
        ),
        "required_evidence_files": merge_unique(
            normalize_mutable_delivery_paths(existing_policy.get("required_evidence_files", [])),
            normalize_mutable_delivery_paths(required_files),
        ),
        "required_event_types": merge_unique(existing_policy.get("required_event_types", []), required_events),
        "required_commands": merge_unique(existing_policy.get("required_commands", []), required_commands),
    }
    gates = {
        "forbidden_terms": merge_unique(existing_gates.get("forbidden_terms", []), forbidden_terms),
        "artifact_patterns": merge_unique(existing_gates.get("artifact_patterns", []), list(DEFAULT_ARTIFACT_PATTERNS)),
    }

    write_text(policy_path, render_list_config("# Orocsy project policy.", policy))
    write_text(gates_path, render_list_config("# Orocsy deterministic gate configuration.", gates))


def ensure_runtime_files(repo: Path, *, intent: str, issue: str, force: bool = False) -> dict[str, Any]:
    migrate_legacy_delivery_root(repo)
    root = delivery_root(repo)
    (root / "state").mkdir(parents=True, exist_ok=True)
    (root / "events").mkdir(parents=True, exist_ok=True)
    (root / "miu").mkdir(parents=True, exist_ok=True)
    (root / "evals").mkdir(parents=True, exist_ok=True)
    (root / "inbox").mkdir(parents=True, exist_ok=True)

    state_path = root / "state" / "current.json"
    if state_path.exists() and not force:
        state = load_json(state_path, {})
        changed = False
        now = utc_now()
        if not state.get("schema_version"):
            state["schema_version"] = SCHEMA_VERSION
            changed = True
        if not state.get("run_id"):
            state["run_id"] = new_id("run")
            changed = True
        if not state.get("goal_id"):
            state["goal_id"] = new_id("goal")
            changed = True
        if not state.get("created_at"):
            state["created_at"] = now
            changed = True
        if not state.get("updated_at"):
            state["updated_at"] = now
            changed = True
        if "gates" not in state:
            state["gates"] = {}
            changed = True
        if changed:
            write_json(state_path, state)
    else:
        now = utc_now()
        state = {
            "schema_version": SCHEMA_VERSION,
            "run_id": new_id("run"),
            "goal_id": new_id("goal"),
            "status": "scoped",
            "phase": "init",
            "intent": intent,
            "issue": issue,
            "created_at": now,
            "updated_at": now,
            "last_event_id": None,
            "gates": {},
        }
        write_json(state_path, state)

    defaults = {
        "policy.yml": """# Orocsy project policy.
declared_scope:
required_evidence_files:
required_event_types:
required_commands:
""",
        "gates.yml": """# Orocsy deterministic gate configuration.
# Project-specific forbidden terms can be added here.
forbidden_terms:
artifact_patterns:
  - .DS_Store
  - "*.tsbuildinfo"
  - ".next/**"
  - "node_modules/**"
  - "dist/**"
  - "build/**"
  - "coverage/**"
  - "playwright-report/**"
  - "test-results/**"
""",
        "spec.md": "# Spec\n\nFill with durable product truth.\n",
        "plan.md": "# Plan\n\nRecord current delivery strategy and tradeoffs.\n",
        "tasks.md": "# Tasks\n\nMirror active work or Linear issue decomposition.\n",
        "handoff.md": "# Handoff\n\nGenerated or updated from runtime state and events.\n",
    }
    for relative_path, content in defaults.items():
        path = root / relative_path
        if force or not path.exists():
            write_text(path, content)

    write_eval_rubrics(repo, force=force)

    events_path = root / "events" / "events.jsonl"
    events_path.touch(exist_ok=True)
    return state


def migrate_legacy_delivery_root(repo: Path) -> None:
    root = delivery_root(repo)
    legacy_root = legacy_delivery_root(repo)
    if root.exists() or not legacy_root.exists() or not legacy_root.is_dir():
        return

    shutil.copytree(
        legacy_root,
        root,
        ignore=shutil.ignore_patterns("bin", "__pycache__"),
    )


def current_state_path(repo: Path) -> Path:
    return delivery_root(repo) / "state" / "current.json"


def events_path(repo: Path) -> Path:
    return delivery_root(repo) / "events" / "events.jsonl"


def inbox_root(repo: Path) -> Path:
    return delivery_root(repo) / "inbox"


def append_event(repo: Path, event: dict[str, Any]) -> dict[str, Any]:
    state = ensure_runtime_files(repo, intent="", issue="")
    now = utc_now()
    event = dict(event)
    event.setdefault("schema_version", SCHEMA_VERSION)
    event.setdefault("event_id", new_id("evt"))
    event.setdefault("ts", now)
    event.setdefault("run_id", state.get("run_id"))
    event.setdefault("goal_id", state.get("goal_id"))
    if event.get("event") in HEAD_BOUND_TRANSITION_EVENTS:
        event["head_sha"] = current_git_head(repo)
        requirements = state.get("issue_requirements") or {}
        if isinstance(requirements, dict):
            for key in ("contract_hash", "issue_revision"):
                value = str(requirements.get(key) or "").strip()
                if value:
                    event[key] = value

    with events_path(repo).open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")

    state["updated_at"] = now
    state["last_event_id"] = event["event_id"]
    if event.get("phase"):
        state["phase"] = event["phase"]
    if event.get("run_status"):
        state["status"] = event["run_status"]
    write_json(current_state_path(repo), state)
    return event


def current_git_head(repo: Path) -> str:
    result = run_git(repo, ["rev-parse", "HEAD"])
    head_sha = result.stdout.strip()
    if result.returncode != 0 or not head_sha:
        detail = result.stderr.strip() or "HEAD is unavailable"
        raise SystemExit(f"cannot append a head-bound transition event: {detail}")
    return head_sha


def render_correction_markdown(correction: dict[str, Any]) -> str:
    lines = [
        f"# Correction {correction['correction_id']}",
        "",
        f"Status: {correction['status']}",
        f"Source: {correction['source']}",
        f"Next action: {correction['next_action']}",
        "",
        "## Summary",
        "",
        correction["summary"],
        "",
        "## Findings",
        "",
    ]
    findings = correction.get("findings") or []
    lines.extend(f"- {finding}" for finding in findings)
    if not findings:
        lines.append("- None recorded")
    lines.extend(["", "## Required Corrections", ""])
    required = correction.get("required_corrections") or []
    lines.extend(f"- {item}" for item in required)
    if not required:
        lines.append("- Determine the smallest correction before continuing.")
    if correction.get("resolution_summary"):
        lines.extend(["", "## Resolution", "", correction["resolution_summary"]])
    return "\n".join(lines).rstrip() + "\n"


def write_correction_files(repo: Path, correction: dict[str, Any]) -> dict[str, str]:
    root = inbox_root(repo)
    root.mkdir(parents=True, exist_ok=True)
    stem = correction["correction_id"]
    json_path = root / f"{stem}.json"
    markdown_path = root / f"{stem}.md"
    write_json(json_path, correction)
    write_text(markdown_path, render_correction_markdown(correction))
    return {
        "json": str(json_path.relative_to(repo)),
        "markdown": str(markdown_path.relative_to(repo)),
    }


def create_correction(
    repo: Path,
    *,
    source: str,
    status: str,
    summary: str,
    findings: list[str],
    required_corrections: list[str],
    next_action: str,
) -> dict[str, Any]:
    state = ensure_runtime_files(repo, intent="", issue="")
    correction = {
        "schema_version": SCHEMA_VERSION,
        "correction_id": new_id("correction"),
        "status": "open",
        "source": source,
        "source_status": status,
        "summary": summary,
        "findings": findings,
        "required_corrections": required_corrections,
        "next_action": next_action,
        "issue": state.get("issue", ""),
        "run_id": state.get("run_id"),
        "goal_id": state.get("goal_id"),
        "created_at": utc_now(),
        "resolved_at": None,
        "resolution_summary": "",
    }
    artifacts = write_correction_files(repo, correction)
    correction["artifacts"] = artifacts
    write_json(repo / artifacts["json"], correction)
    append_event(
        repo,
        {
            "event": "correction.created",
            "phase": "correction",
            "status": "open",
            "run_status": "blocked" if next_action in {"block", "escalate"} else "retry-ready",
            "correction_id": correction["correction_id"],
            "source": source,
            "source_status": status,
            "summary": summary,
            "next_action": next_action,
            "artifacts": list(artifacts.values()),
        },
    )
    return correction


def load_corrections(repo: Path) -> list[dict[str, Any]]:
    root = inbox_root(repo)
    if not root.exists():
        return []
    corrections: list[dict[str, Any]] = []
    for path in sorted(root.glob("correction_*.json")):
        try:
            correction = json.loads(read_text(path))
        except json.JSONDecodeError:
            correction = {
                "correction_id": path.stem,
                "status": "invalid",
                "source": "inbox",
                "summary": "Correction JSON is invalid.",
                "path": str(path),
            }
        corrections.append(correction)
    return corrections


def open_corrections(repo: Path) -> list[dict[str, Any]]:
    return [correction for correction in load_corrections(repo) if correction.get("status") != "resolved"]


def resolve_correction(repo: Path, correction_ref: str, summary: str) -> dict[str, Any]:
    for correction in load_corrections(repo):
        json_path = repo / correction.get("artifacts", {}).get("json", "")
        if correction_ref in {correction.get("correction_id"), Path(str(json_path)).name, Path(str(json_path)).stem}:
            correction["status"] = "resolved"
            correction["resolved_at"] = utc_now()
            correction["resolution_summary"] = summary
            artifacts = correction.get("artifacts") or write_correction_files(repo, correction)
            write_json(repo / artifacts["json"], correction)
            write_text(repo / artifacts["markdown"], render_correction_markdown(correction))
            append_event(
                repo,
                {
                    "event": "correction.resolved",
                    "phase": "correction",
                    "status": "resolved",
                    "correction_id": correction["correction_id"],
                    "summary": summary,
                },
            )
            return correction
    raise SystemExit(f"unknown correction: {correction_ref}")


def run_git(repo: Path, args: list[str], *, check: bool = False) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.setdefault("GIT_OPTIONAL_LOCKS", "0")
    return subprocess.run(
        ["git", *args],
        cwd=repo,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
    )


def is_git_repo(repo: Path) -> bool:
    result = run_git(repo, ["rev-parse", "--is-inside-work-tree"])
    return result.returncode == 0 and result.stdout.strip() == "true"


def ensure_runtime_git_excludes(repo: Path) -> None:
    if not is_git_repo(repo):
        return
    result = run_git(repo, ["rev-parse", "--git-path", "info/exclude"])
    if result.returncode != 0 or not result.stdout.strip():
        return
    exclude_path = Path(result.stdout.strip())
    if not exclude_path.is_absolute():
        exclude_path = repo / exclude_path
    existing = read_text(exclude_path) if exclude_path.exists() else ""
    additions = [".orocsy/delivery/", ".orocsy/runtime/", ".pnpm-store/", ".codex/delivery/"]
    missing = [entry for entry in additions if entry not in existing.splitlines()]
    if missing:
        exclude_path.parent.mkdir(parents=True, exist_ok=True)
        prefix = "" if existing.endswith("\n") or existing == "" else "\n"
        with exclude_path.open("a", encoding="utf-8") as handle:
            handle.write(prefix + "\n".join(missing) + "\n")


def git_paths(repo: Path, args: list[str]) -> list[str]:
    result = run_git(repo, args)
    if result.returncode != 0:
        return []
    return [path for path in result.stdout.split("\0") if path]


def candidate_files(repo: Path) -> list[Path]:
    if is_git_repo(repo):
        paths = set(git_paths(repo, ["ls-files", "-z"]))
        paths.update(git_paths(repo, ["ls-files", "--others", "--exclude-standard", "-z"]))
        return sorted((repo / path for path in paths if should_scan_path(path)), key=lambda path: str(path))

    files: list[Path] = []
    for root, dirs, names in os.walk(repo):
        dirs[:] = [name for name in dirs if name not in DEFAULT_EXCLUDED_DIRS]
        for name in names:
            relative = str((Path(root) / name).relative_to(repo))
            if should_scan_path(relative):
                files.append(Path(root) / name)
    return sorted(files, key=lambda path: str(path))


def should_scan_path(relative_path: str) -> bool:
    parts = Path(relative_path).parts
    if any(part in DEFAULT_EXCLUDED_DIRS for part in parts):
        return False
    if any(fnmatch.fnmatch(relative_path, pattern) for pattern in DEFAULT_ARTIFACT_PATTERNS):
        return False
    return True


def read_text_if_safe(path: Path) -> str | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if b"\0" in data[:4096]:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def normalize_terms(config: dict[str, list[str]], extra: list[str]) -> list[str]:
    terms = list(DEFAULT_FORBIDDEN_TERMS)
    terms.extend(config.get("forbidden_terms", []))
    terms.extend(extra)
    return sorted({term.lower() for term in terms if term.strip()})


def gate_leaks(repo: Path, config: dict[str, list[str]], args: argparse.Namespace) -> GateResult:
    terms = normalize_terms(config, args.forbid or [])
    findings: list[Finding] = []
    for path in candidate_files(repo):
        content = read_text_if_safe(path)
        if content is None:
            continue
        lower_content = content.lower()
        relative = str(path.relative_to(repo))
        for term in terms:
            if term and term in lower_content:
                findings.append(Finding("leaks", "error", f"forbidden term found: {term}", relative))
    return gate_result("leaks", findings)


def gate_secrets(repo: Path, _config: dict[str, list[str]], _args: argparse.Namespace) -> GateResult:
    findings: list[Finding] = []
    for path in candidate_files(repo):
        content = read_text_if_safe(path)
        if content is None:
            continue
        relative = str(path.relative_to(repo))
        for name, pattern in SECRET_PATTERNS:
            if pattern.search(content):
                findings.append(Finding("secrets", "error", f"secret-looking value matched {name}", relative))
    return gate_result("secrets", findings)


def git_status_paths(repo: Path) -> list[tuple[str, str]]:
    result = run_git(repo, ["status", "--porcelain", "--untracked-files=all"])
    if result.returncode != 0:
        return []
    entries: list[tuple[str, str]] = []
    for line in result.stdout.splitlines():
        if not line:
            continue
        status = line[:2]
        path = line[3:] if len(line) > 3 else ""
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        entries.append((status, path))
    return entries


def artifact_patterns(config: dict[str, list[str]]) -> list[str]:
    patterns = list(DEFAULT_ARTIFACT_PATTERNS)
    patterns.extend(config.get("artifact_patterns", []))
    return sorted({pattern for pattern in patterns if pattern.strip()})


def escape_glob_route_brackets(pattern: str) -> str:
    escaped = []
    for char in pattern:
        if char == "[":
            escaped.append("[[]")
        elif char == "]":
            escaped.append("[]]")
        else:
            escaped.append(char)
    return "".join(escaped)


def path_matches_any(path: str, patterns: list[str]) -> bool:
    for pattern in patterns:
        if path == pattern or fnmatch.fnmatch(path, pattern):
            return True

        escaped_pattern = escape_glob_route_brackets(pattern)
        if escaped_pattern != pattern and fnmatch.fnmatch(path, escaped_pattern):
            return True

    return False


def relative_path_is_child(path: str, root: str) -> bool:
    path_parts = Path(path).parts
    root_parts = Path(root).parts
    return path_parts == root_parts or path_parts[: len(root_parts)] == root_parts


def validate_generated_clean_path(repo: Path, relative_path: str) -> tuple[Path | None, str | None]:
    clean = relative_path.strip().strip("/")
    if not clean or clean in {".", ".."}:
        return None, "path is empty or points at the workspace root"
    path = Path(clean)
    if path.is_absolute() or any(part == ".." for part in path.parts):
        return None, "path must be a relative path inside the workspace"
    if not any(relative_path_is_child(clean, root) for root in ALLOWED_GENERATED_CLEAN_ROOTS):
        return None, "path is not in the generated-clean allowlist"

    target = repo / path
    try:
        target_resolved = target.resolve(strict=target.exists())
        repo_resolved = repo.resolve()
        target_resolved.relative_to(repo_resolved)
    except (OSError, ValueError):
        return None, "path resolves outside the workspace"

    if not target.exists() and not target.is_symlink():
        return target, None

    if not is_git_repo(repo):
        return None, "workspace is not a git repository"

    ignored = run_git(repo, ["check-ignore", "-q", "--", clean])
    if ignored.returncode != 0:
        return None, "path is not git-ignored"

    return target, None


def remove_generated_path(target: Path) -> str:
    if not target.exists() and not target.is_symlink():
        return "missing"
    if target.is_symlink() or target.is_file():
        target.unlink()
        return "removed"
    if target.is_dir():
        shutil.rmtree(target)
        return "removed"
    return "skipped"


def restore_tracked_generated_path(repo: Path, relative_path: str) -> tuple[str, str | None]:
    tracked = run_git(repo, ["ls-files", "--error-unmatch", "--", relative_path])
    if tracked.returncode != 0:
        if not (repo / relative_path).exists():
            return "missing", None
        return "blocked", "tracked generated path is not tracked by git"

    dirty = run_git(repo, ["diff", "--quiet", "--", relative_path])
    deleted = not (repo / relative_path).exists()
    if dirty.returncode == 0 and not deleted:
        return "unchanged", None

    restored = run_git(repo, ["restore", "--worktree", "--", relative_path])
    if restored.returncode != 0:
        return "blocked", "failed to restore tracked generated path"
    return "restored", None


def clean_generated_paths(repo: Path, paths: list[str]) -> dict[str, Any]:
    requested = paths or list(DEFAULT_GENERATED_CLEAN_PATHS)
    removed: list[str] = []
    restored: list[str] = []
    skipped: list[dict[str, str]] = []
    blocked: list[dict[str, str]] = []

    for relative_path in requested:
        clean = relative_path.strip().strip("/")
        if clean in ALLOWED_TRACKED_GENERATED_PATHS:
            outcome, reason = restore_tracked_generated_path(repo, clean)
            if outcome == "restored":
                restored.append(clean)
            elif outcome == "blocked":
                blocked.append({"path": clean or relative_path, "reason": reason or "invalid tracked generated path"})
            else:
                skipped.append({"path": clean, "reason": outcome})
            continue

        target, reason = validate_generated_clean_path(repo, relative_path)
        if target is None:
            blocked.append({"path": clean or relative_path, "reason": reason or "invalid path"})
            continue
        outcome = remove_generated_path(target)
        if outcome == "removed":
            removed.append(clean)
        else:
            skipped.append({"path": clean, "reason": outcome})

    if blocked:
        status = "failed"
    elif removed or restored:
        status = "passed"
    else:
        status = "warn"

    return {
        "status": status,
        "removed": removed,
        "restored": restored,
        "skipped": skipped,
        "blocked": blocked,
    }


def gate_artifacts(repo: Path, config: dict[str, list[str]], _args: argparse.Namespace) -> GateResult:
    findings: list[Finding] = []
    patterns = artifact_patterns(config)
    for status, path in git_status_paths(repo):
        if path_matches_any(path, patterns):
            findings.append(Finding("artifacts", "error", "generated or local artifact is not ignored", path, status))
    return gate_result("artifacts", findings)


def gate_git_state(repo: Path, _config: dict[str, list[str]], args: argparse.Namespace) -> GateResult:
    findings: list[Finding] = []
    if not is_git_repo(repo):
        return gate_result("git-state", [Finding("git-state", "error", "not a git repository")])

    branch = run_git(repo, ["branch", "--show-current"])
    if branch.returncode != 0 or not branch.stdout.strip():
        findings.append(Finding("git-state", "error", "repository is detached or branch cannot be resolved"))

    upstream = run_git(repo, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
    if upstream.returncode != 0:
        findings.append(Finding("git-state", "warning", "branch has no upstream"))
    else:
        counts = run_git(repo, ["rev-list", "--left-right", "--count", f"{upstream.stdout.strip()}...HEAD"])
        if counts.returncode == 0:
            behind, ahead = counts.stdout.strip().split()
            if behind != "0":
                findings.append(Finding("git-state", "warning", f"branch is behind upstream by {behind} commits"))
            if ahead != "0":
                findings.append(Finding("git-state", "warning", f"branch is ahead of upstream by {ahead} commits"))

    dirty = git_status_paths(repo)
    if dirty:
        severity = "error" if args.strict else "warning"
        findings.append(Finding("git-state", severity, f"working tree has {len(dirty)} changed or untracked paths"))

    return gate_result("git-state", findings)


def changed_paths(repo: Path) -> list[str]:
    paths: set[str] = set()
    if not is_git_repo(repo):
        return []
    for args in (
        ["diff", "--name-only", "HEAD"],
        ["diff", "--cached", "--name-only"],
        ["ls-files", "--others", "--exclude-standard"],
    ):
        result = run_git(repo, args)
        if result.returncode == 0:
            paths.update(path for path in result.stdout.splitlines() if path)
    return sorted(paths)


def gate_declared_scope(repo: Path, config: dict[str, list[str]], args: argparse.Namespace) -> GateResult:
    scope = normalize_mutable_delivery_paths(list(config.get("declared_scope", [])))
    scope.extend(normalize_mutable_delivery_paths(args.scope or []))
    if not scope:
        return GateResult(
            "declared-scope",
            "warn",
            (Finding("declared-scope", "warning", "no declared_scope configured; scope gate is advisory only"),),
        )

    findings: list[Finding] = []
    for path in changed_paths(repo):
        if not path_matches_any(path, scope):
            findings.append(Finding("declared-scope", "error", "changed path is outside declared scope", path))
    return gate_result("declared-scope", findings)


def load_events(repo: Path) -> list[dict[str, Any]]:
    path = events_path(repo)
    if not path.exists():
        return []
    events: list[dict[str, Any]] = []
    for line in read_text(path).splitlines():
        if not line.strip():
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            events.append({"event": "invalid-json-line", "raw": line})
    return events


def token_telemetry_root(repo: Path) -> Path:
    return repo / TOKEN_TELEMETRY_ROOT


def token_workers_path(repo: Path) -> Path:
    return token_telemetry_root(repo) / "workers.jsonl"


def token_spans_path(repo: Path) -> Path:
    return token_telemetry_root(repo) / "spans.jsonl"


def load_jsonl_records(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []

    records: list[dict[str, Any]] = []
    for line in read_text(path).splitlines():
        if not line.strip():
            continue
        try:
            decoded = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(decoded, dict):
            records.append(decoded)
    return records


def int_field(record: dict[str, Any], key: str) -> int:
    value = record.get(key)
    return value if isinstance(value, int) else 0


def filter_token_records(
    records: list[dict[str, Any]], *, issue: str = "", worker: str = ""
) -> list[dict[str, Any]]:
    filtered = records
    if issue:
        filtered = [record for record in filtered if str(record.get("issue") or "") == issue]
    if worker:
        filtered = [record for record in filtered if str(record.get("worker_session_id") or "") == worker]
    return filtered


def top_phase_text(summary: dict[str, Any]) -> str:
    phases = summary.get("top_phases")
    if not isinstance(phases, list) or not phases:
        return "-"
    phase = phases[0] if isinstance(phases[0], dict) else {}
    name = phase.get("phase") or "-"
    tokens = int_field(phase, "total_tokens")
    return f"{name}:{tokens}"


def loop_signature_text(summary: dict[str, Any]) -> str:
    signatures = summary.get("loop_signatures")
    if isinstance(signatures, list) and signatures:
        return ",".join(str(signature) for signature in signatures)
    return "-"


def reconstruct_token_worker_records_from_spans(
    spans: list[dict[str, Any]], existing_worker_ids: set[str]
) -> list[dict[str, Any]]:
    reconstructed: dict[str, dict[str, Any]] = {}
    phase_totals: dict[str, dict[str, int]] = {}

    for span in spans:
        worker_id = str(span.get("worker_session_id") or "")
        if not worker_id or worker_id in existing_worker_ids:
            continue

        summary = reconstructed.setdefault(
            worker_id,
            {
                "issue": span.get("issue") or "",
                "worker_session_id": worker_id,
                "turn": span.get("turn"),
                "status": "span_summary_missing_worker_record",
                "total_tokens": 0,
                "cached_input_tokens": 0,
                "counted_guard_tokens": 0,
                "top_phases": [],
                "loop_signatures": ["missing_worker_summary"],
                "summary_source": "spans",
            },
        )
        summary["total_tokens"] += int_field(span, "total_tokens_delta")
        summary["cached_input_tokens"] += int_field(span, "cached_input_tokens_delta")
        summary["counted_guard_tokens"] += int_field(span, "counted_guard_tokens_delta")

        phase = str(span.get("phase") or "-")
        worker_phase_totals = phase_totals.setdefault(worker_id, {})
        worker_phase_totals[phase] = worker_phase_totals.get(phase, 0) + int_field(span, "total_tokens_delta")

    for worker_id, summary in reconstructed.items():
        summary["top_phases"] = [
            {"phase": phase, "total_tokens": tokens}
            for phase, tokens in sorted(
                phase_totals.get(worker_id, {}).items(), key=lambda item: item[1], reverse=True
            )
            if tokens > 0
        ]

    return list(reconstructed.values())


def token_summary_payload(repo: Path, *, issue: str = "", worker: str = "", limit: int = 10) -> dict[str, Any]:
    records = filter_token_records(load_jsonl_records(token_workers_path(repo)), issue=issue, worker=worker)
    spans = filter_token_records(load_jsonl_records(token_spans_path(repo)), issue=issue, worker=worker)
    existing_worker_ids = {str(record.get("worker_session_id") or "") for record in records}
    records.extend(reconstruct_token_worker_records_from_spans(spans, existing_worker_ids))
    records = sorted(records, key=lambda record: int_field(record, "total_tokens"), reverse=True)
    limited = records[: max(limit, 0)]
    top = limited[0] if limited else None

    return {
        "status": "passed" if records else "warn",
        "telemetry_root": str(token_telemetry_root(repo)),
        "count": len(records),
        "total_tokens": sum(int_field(record, "total_tokens") for record in records),
        "top": top,
        "workers": limited,
    }


def token_spans_payload(repo: Path, *, issue: str = "", worker: str = "", limit: int = 50) -> dict[str, Any]:
    records = filter_token_records(load_jsonl_records(token_spans_path(repo)), issue=issue, worker=worker)
    records = sorted(records, key=lambda record: int_field(record, "total_tokens_delta"), reverse=True)

    return {
        "status": "passed" if records else "warn",
        "telemetry_root": str(token_telemetry_root(repo)),
        "count": len(records),
        "spans": records[: max(limit, 0)],
    }


def emit_token_summary(payload: dict[str, Any], *, json_output: bool) -> None:
    if json_output:
        print(json.dumps(payload, indent=2, sort_keys=True))
        return

    print(f"Orocsy token summary: {payload['status']}")
    print(f"telemetry_root: {payload['telemetry_root']}")
    print(f"workers: {payload['count']}")
    print(f"total_tokens: {payload['total_tokens']}")
    for summary in payload["workers"]:
        issue = summary.get("issue") or "-"
        worker = summary.get("worker_session_id") or "-"
        status = summary.get("status") or "-"
        total = int_field(summary, "total_tokens")
        cached = int_field(summary, "cached_input_tokens")
        counted = int_field(summary, "counted_guard_tokens")
        print(
            f"- {issue} worker={worker} turn={summary.get('turn') or '-'}"
            f" status={status} total={total} cached={cached} counted={counted}"
            f" top_phase={top_phase_text(summary)} loops={loop_signature_text(summary)}"
        )


def emit_token_spans(payload: dict[str, Any], *, json_output: bool) -> None:
    if json_output:
        print(json.dumps(payload, indent=2, sort_keys=True))
        return

    print(f"Orocsy token spans: {payload['status']}")
    print(f"telemetry_root: {payload['telemetry_root']}")
    print(f"spans: {payload['count']}")
    for span in payload["spans"]:
        issue = span.get("issue") or "-"
        worker = span.get("worker_session_id") or "-"
        phase = span.get("phase") or "-"
        kind = span.get("kind") or "-"
        total = int_field(span, "total_tokens_delta")
        fingerprint = span.get("command_fingerprint") or "-"
        print(f"- {issue} worker={worker} phase={phase} kind={kind} total_delta={total} command={fingerprint}")


def parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = f"{text[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def git_stdout(repo: Path, args: list[str]) -> str | None:
    result = run_git(repo, args)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def git_summary(repo: Path) -> dict[str, Any]:
    if not is_git_repo(repo):
        return {
            "is_git_repo": False,
            "branch": None,
            "head": None,
            "upstream": None,
            "ahead": None,
            "behind": None,
            "dirty_paths": None,
        }

    upstream = git_stdout(repo, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
    ahead: int | None = None
    behind: int | None = None
    if upstream:
        counts = git_stdout(repo, ["rev-list", "--left-right", "--count", f"{upstream}...HEAD"])
        if counts:
            parts = counts.split()
            if len(parts) == 2 and all(part.isdigit() for part in parts):
                behind = int(parts[0])
                ahead = int(parts[1])

    return {
        "is_git_repo": True,
        "branch": git_stdout(repo, ["branch", "--show-current"]) or None,
        "head": git_stdout(repo, ["rev-parse", "--short", "HEAD"]) or None,
        "upstream": upstream,
        "ahead": ahead,
        "behind": behind,
        "dirty_paths": len(git_status_paths(repo)),
    }


def is_workspace_like(path: Path) -> bool:
    return is_git_repo(path) or current_state_path(path).exists()


def workspace_candidates(root: Path, *, include_empty: bool) -> list[Path]:
    if is_workspace_like(root):
        return [root]

    candidates: list[Path] = []
    for child in sorted(root.iterdir(), key=lambda path: path.name):
        if not child.is_dir() or child.name in DEFAULT_EXCLUDED_DIRS:
            continue
        if is_workspace_like(child):
            candidates.append(child)
            continue

        nested = [
            grandchild
            for grandchild in sorted(child.iterdir(), key=lambda path: path.name)
            if grandchild.is_dir()
            and grandchild.name not in DEFAULT_EXCLUDED_DIRS
            and is_workspace_like(grandchild)
        ]
        candidates.extend(nested)
        if include_empty and not nested:
            candidates.append(child)
    return candidates


def load_current_state(repo: Path) -> tuple[dict[str, Any] | None, str | None]:
    path = current_state_path(repo)
    if not path.exists():
        return None, "delivery_state_missing"
    try:
        return json.loads(read_text(path)), None
    except json.JSONDecodeError as error:
        return None, f"delivery_state_invalid:{error.lineno}:{error.colno}"


def workspace_monitor_snapshot(workspace: Path, *, checked_at: datetime, stale_minutes: int) -> dict[str, Any]:
    state, state_error = load_current_state(workspace)
    events = load_events(workspace)
    last_event = events[-1] if events else None
    git = git_summary(workspace)

    warnings: list[str] = []
    if state_error:
        warnings.append(state_error)
    if git["is_git_repo"] is False:
        warnings.append("not_git_repo")
    if git["dirty_paths"]:
        warnings.append(f"dirty_worktree:{git['dirty_paths']}")
    if any(event.get("event") == "invalid-json-line" for event in events):
        warnings.append("events_invalid_json")

    updated_at = None
    if state:
        updated_at = state.get("updated_at")
    if not updated_at and last_event:
        updated_at = last_event.get("ts")

    parsed_updated_at = parse_timestamp(updated_at)
    age_seconds = None
    stale = False
    if parsed_updated_at:
        age_seconds = max(0, int((checked_at - parsed_updated_at).total_seconds()))
        stale = age_seconds > stale_minutes * 60
        if stale:
            warnings.append(f"stale:{age_seconds}s")
    elif state or last_event:
        warnings.append("updated_at_unparseable")

    return {
        "name": workspace.name,
        "path": str(workspace),
        "issue": state.get("issue") if state else None,
        "intent": state.get("intent") if state else None,
        "run_id": state.get("run_id") if state else None,
        "status": state.get("status") if state else None,
        "phase": state.get("phase") if state else None,
        "updated_at": updated_at,
        "age_seconds": age_seconds,
        "stale": stale,
        "git": git,
        "events": {
            "count": len(events),
            "last": last_event,
        },
        "pull_request": (state or {}).get("pull_request") or (state or {}).get("pr_url"),
        "warnings": warnings,
    }


def monitor_status(workspaces: list[dict[str, Any]], *, strict: bool) -> str:
    if any(workspace["warnings"] for workspace in workspaces):
        return "failed" if strict else "warn"
    return "passed"


def emit_monitor_output(payload: dict[str, Any], *, json_output: bool) -> None:
    if json_output:
        print(json.dumps(payload, indent=2, sort_keys=True))
        return

    print(f"Orocsy Symphony monitor: {payload['status']}")
    print(f"root: {payload['root']}")
    print(f"workspaces: {payload['summary']['count']}")
    for workspace in payload["workspaces"]:
        git = workspace["git"]
        branch = git.get("branch") or "detached/no-branch"
        dirty = git.get("dirty_paths")
        dirty_text = "unknown" if dirty is None else str(dirty)
        stale_text = " stale" if workspace["stale"] else ""
        print(
            f"- {workspace['name']}: {workspace.get('status') or 'unknown'}"
            f" issue={workspace.get('issue') or '-'} branch={branch}"
            f" dirty={dirty_text} events={workspace['events']['count']}{stale_text}"
        )
        if workspace.get("updated_at"):
            print(f"  updated_at: {workspace['updated_at']}")
        last_event = workspace["events"].get("last")
        if last_event:
            event_name = last_event.get("event") or last_event.get("type") or "unknown"
            event_status = last_event.get("status") or "info"
            print(f"  last_event: {event_name} ({event_status})")
        for warning in workspace["warnings"]:
            print(f"  warning: {warning}")


def gate_required_evidence(repo: Path, config: dict[str, list[str]], args: argparse.Namespace) -> GateResult:
    required_files = normalize_mutable_delivery_paths(list(config.get("required_evidence_files", [])))
    required_events = list(config.get("required_event_types", []))
    required_commands = list(config.get("required_commands", []))
    required_files.extend(normalize_mutable_delivery_paths(args.evidence_file or []))
    required_events.extend(args.evidence_event or [])
    required_commands.extend(args.evidence_command or [])

    if not required_files and not required_events and not required_commands:
        return GateResult(
            "required-evidence",
            "warn",
            (Finding("required-evidence", "warning", "no required evidence configured; evidence gate is advisory only"),),
        )

    findings: list[Finding] = []
    for relative_path in required_files:
        if not (repo / relative_path).exists():
            findings.append(Finding("required-evidence", "error", "required evidence file is missing", relative_path))

    events = load_events(repo)
    event_names = {str(event.get("event") or event.get("type") or "") for event in events}
    for required_event in required_events:
        if required_event not in event_names:
            findings.append(Finding("required-evidence", "error", "required event type is missing", detail=required_event))

    command_text = "\n".join(str(event.get("command") or event.get("tool") or "") for event in events)
    for required_command in required_commands:
        if required_command not in command_text:
            findings.append(Finding("required-evidence", "error", "required command evidence is missing", detail=required_command))

    return gate_result("required-evidence", findings)


def gate_issue_requirements(repo: Path, _config: dict[str, list[str]], _args: argparse.Namespace) -> GateResult:
    state, state_error = load_current_state(repo)
    if state_error or not state:
        return gate_result("issue-requirements", [Finding("issue-requirements", "warning", "runtime state is missing")])

    requirements = state.get("issue_requirements") or {}
    if not isinstance(requirements, dict) or not requirements:
        return gate_result(
            "issue-requirements",
            [Finding("issue-requirements", "warning", "issue requirements are missing from runtime state")],
        )

    findings: list[Finding] = []
    for key in ISSUE_REQUIREMENT_KEYS:
        if key not in requirements:
            findings.append(Finding("issue-requirements", "error", f"required issue section is missing: {key}"))

    if not requirements.get("identifier"):
        findings.append(Finding("issue-requirements", "error", "issue identifier is missing"))
    if not requirements.get("write_scope"):
        findings.append(Finding("issue-requirements", "error", "write_scope must name at least one path glob"))
    if not requirements.get("mius"):
        findings.append(Finding("issue-requirements", "error", "mius must name at least one implementable unit"))

    validation = requirements.get("validation") or {}
    if not isinstance(validation, dict) or not any(validation.get(key) for key in ("files", "events", "commands", "scenarios")):
        findings.append(Finding("issue-requirements", "error", "validation must include files, events, commands, or scenarios"))

    return gate_result("issue-requirements", findings)


GATE_FUNCTIONS = {
    "leaks": gate_leaks,
    "secrets": gate_secrets,
    "artifacts": gate_artifacts,
    "git-state": gate_git_state,
    "declared-scope": gate_declared_scope,
    "issue-requirements": gate_issue_requirements,
    "required-evidence": gate_required_evidence,
}


def gate_result(gate: str, findings: list[Finding]) -> GateResult:
    if any(finding.severity == "error" for finding in findings):
        status = "failed"
    elif findings:
        status = "warn"
    else:
        status = "passed"
    return GateResult(gate, status, tuple(findings))


def combined_status(results: list[GateResult], *, strict: bool) -> str:
    if any(result.status == "failed" for result in results):
        return "failed"
    if strict and any(result.status == "warn" for result in results):
        return "failed"
    if any(result.status == "warn" for result in results):
        return "warn"
    return "passed"


def emit_gate_output(results: list[GateResult], *, json_output: bool, strict: bool) -> None:
    status = combined_status(results, strict=strict)
    payload = {
        "status": status,
        "gates": [result.to_dict() for result in results],
    }
    if json_output:
        print(json.dumps(payload, indent=2, sort_keys=True))
        return

    print(f"Orocsy gates: {status}")
    for result in results:
        print(f"- {result.gate}: {result.status}")
        for finding in result.findings:
            location = f" [{finding.path}]" if finding.path else ""
            detail = f" ({finding.detail})" if finding.detail else ""
            print(f"  {finding.severity}: {finding.message}{location}{detail}")


def finding_text(finding: Finding) -> str:
    location = f" [{finding.path}]" if finding.path else ""
    detail = f" ({finding.detail})" if finding.detail else ""
    return f"{finding.gate}: {finding.severity}: {finding.message}{location}{detail}"


def command_tokens_summary(args: argparse.Namespace) -> int:
    repo = repo_path(args.repo)
    payload = token_summary_payload(repo, issue=args.issue, worker=args.worker, limit=args.limit)
    emit_token_summary(payload, json_output=args.json)
    return 0


def command_tokens_spans(args: argparse.Namespace) -> int:
    repo = repo_path(args.repo)
    payload = token_spans_payload(repo, issue=args.issue, worker=args.worker, limit=args.limit)
    emit_token_spans(payload, json_output=args.json)
    return 0


def command_init(args: argparse.Namespace) -> int:
    repo = repo_path(args.repo)
    ensure_runtime_git_excludes(repo)
    state = ensure_runtime_files(repo, intent=args.intent or "", issue=args.issue or "", force=args.force)
    event = append_event(
        repo,
        {
            "event": "run.initialized",
            "phase": "init",
            "run_status": state.get("status", "scoped"),
            "intent": state.get("intent", ""),
            "issue": state.get("issue", ""),
        },
    )
    if args.json:
        print(json.dumps({"state": state, "event": event}, indent=2, sort_keys=True))
    else:
        print(f"initialized Orocsy ledger at {delivery_root(repo)}")
        print(f"run_id: {state['run_id']}")
    return 0


def command_run_start(args: argparse.Namespace) -> int:
    repo = repo_path(args.repo)
    state = ensure_runtime_files(repo, intent=args.intent or "", issue=args.issue or "")
    state["status"] = "running"
    state["phase"] = "running"
    if args.intent:
        state["intent"] = args.intent
    if args.issue:
        state["issue"] = args.issue
    write_json(current_state_path(repo), state)
    event = append_event(
        repo,
        {
            "event": "run.started",
            "phase": "running",
            "run_status": "running",
            "intent": state.get("intent", ""),
            "issue": state.get("issue", ""),
        },
    )
    if args.json:
        print(json.dumps({"state": state, "event": event}, indent=2, sort_keys=True))
    else:
        print(f"started run {state['run_id']}")
    return 0


def command_event_append(args: argparse.Namespace) -> int:
    repo = repo_path(args.repo)
    event: dict[str, Any] = {
        "event": args.type,
        "status": args.status,
    }
    if args.phase:
        event["phase"] = args.phase
    if args.step:
        event["step"] = args.step
        if args.type == "miu.completion_requested":
            event["miu_id"] = args.step
    if args.tool:
        event["tool"] = args.tool
    if args.command:
        event["command"] = args.command
    if args.artifact:
        event["artifacts"] = args.artifact
    written = append_event(repo, event)
    if args.json:
        print(json.dumps(written, indent=2, sort_keys=True))
    else:
        print(f"appended event {written['event_id']}: {args.type}")
    return 0


def command_gate(args: argparse.Namespace) -> int:
    repo = repo_path(args.repo)
    config = load_gate_config(repo)
    selected = list(GATE_FUNCTIONS) if args.gate == "all" else [args.gate]
    results = [GATE_FUNCTIONS[name](repo, config, args) for name in selected]
    status = combined_status(results, strict=args.strict)

    if args.record:
        append_event(
            repo,
            {
                "event": f"gate.{args.gate}",
                "phase": "gate",
                "status": status,
                "gate": args.gate,
                "results": [result.to_dict() for result in results],
            },
        )

    if args.inbox and status == "failed":
        findings = [finding_text(finding) for result in results for finding in result.findings]
        create_correction(
            repo,
            source=f"gate.{args.gate}",
            status=status,
            summary=f"Gate `{args.gate}` failed.",
            findings=findings,
            required_corrections=[
                "Fix the failing gate findings.",
                f"Rerun `orocsy gate {args.gate} --strict` before continuing.",
            ],
            next_action="block",
        )

    emit_gate_output(results, json_output=args.json, strict=args.strict)
    return 0 if status in {"passed", "warn"} else 1


def command_eval_list(args: argparse.Namespace) -> int:
    payload = {
        "rubrics": [
            {
                "name": name,
                "title": rubric["title"],
                "purpose": rubric["purpose"],
            }
            for name, rubric in EVAL_RUBRICS.items()
        ],
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print("Orocsy eval rubrics:")
        for item in payload["rubrics"]:
            print(f"- {item['name']}: {item['title']}")
    return 0


def command_eval_rubric(args: argparse.Namespace) -> int:
    rubric = EVAL_RUBRICS[args.rubric]
    if args.json:
        payload = dict(rubric)
        payload["name"] = args.rubric
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(render_eval_rubric_markdown(args.rubric, rubric))
    return 0


def command_eval_write_rubrics(args: argparse.Namespace) -> int:
    repo = repo_path(args.repo)
    written = write_eval_rubrics(repo, force=args.force)
    payload = {
        "eval_root": str(delivery_root(repo) / "evals"),
        "written": [str(path.relative_to(repo)) for path in written],
        "rubrics": list(EVAL_RUBRICS),
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"eval rubrics available at {payload['eval_root']}")
        for name in payload["rubrics"]:
            print(f"- {name}")
    return 0


def command_eval_record(args: argparse.Namespace) -> int:
    repo = repo_path(args.repo)
    findings = args.finding or []
    required_corrections = args.required_correction or []
    event = append_event(
        repo,
        {
            "event": f"eval.{args.rubric}",
            "phase": "eval",
            "status": args.status,
            "rubric": args.rubric,
            "summary": args.summary,
            "findings": findings,
            "required_corrections": required_corrections,
        },
    )
    correction = None
    if args.inbox and args.status in {"failed", "warn"}:
        correction = create_correction(
            repo,
            source=f"eval.{args.rubric}",
            status=args.status,
            summary=args.summary,
            findings=findings,
            required_corrections=required_corrections
            or [f"Resolve `{args.rubric}` eval findings before handoff."],
            next_action="block" if args.status == "failed" else "retry",
        )
    if args.json:
        payload: dict[str, Any] = dict(event)
        if correction:
            payload["correction"] = correction
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"recorded eval {args.rubric}: {args.status}")
    return 0 if args.status in {"passed", "warn"} else 1


def command_inbox_create(args: argparse.Namespace) -> int:
    repo = repo_path(args.repo)
    correction = create_correction(
        repo,
        source=args.source,
        status=args.status,
        summary=args.summary,
        findings=args.finding or [],
        required_corrections=args.required_correction or [],
        next_action=args.next_action,
    )
    if args.json:
        print(json.dumps(correction, indent=2, sort_keys=True))
    else:
        print(f"created correction {correction['correction_id']}")
    return 0


def command_inbox_list(args: argparse.Namespace) -> int:
    repo = repo_path(args.repo)
    corrections = load_corrections(repo)
    if args.open_only:
        corrections = [correction for correction in corrections if correction.get("status") != "resolved"]
    payload = {
        "status": "passed",
        "count": len(corrections),
        "corrections": corrections,
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"Orocsy corrections: {len(corrections)}")
        for correction in corrections:
            print(f"- {correction.get('correction_id')}: {correction.get('status')} {correction.get('source')}")
    return 0


def command_inbox_resolve(args: argparse.Namespace) -> int:
    repo = repo_path(args.repo)
    correction = resolve_correction(repo, args.correction, args.summary)
    if args.json:
        print(json.dumps(correction, indent=2, sort_keys=True))
    else:
        print(f"resolved correction {correction['correction_id']}")
    return 0


def guidance_for_workspace(workspace: Path, *, stale_minutes: int) -> dict[str, Any]:
    checked_at = datetime.now(timezone.utc).replace(microsecond=0)
    snapshot = workspace_monitor_snapshot(workspace, checked_at=checked_at, stale_minutes=stale_minutes)
    corrections = open_corrections(workspace)
    last_event = snapshot["events"].get("last") or {}
    reasons: list[str] = []

    if "delivery_state_missing" in snapshot["warnings"]:
        action = "block"
        reasons.append("Orocsy delivery state is missing; run symphony prepare-workspace first.")
    elif corrections:
        action = "retry" if all(correction.get("next_action") == "retry" for correction in corrections) else "block"
        reasons.append(f"{len(corrections)} open correction inbox item(s) must be resolved.")
    elif str(last_event.get("status")) == "failed":
        action = "block"
        reasons.append(f"Last event failed: {last_event.get('event') or last_event.get('type')}")
    elif snapshot["stale"]:
        action = "retry"
        reasons.append("Workspace is stale; resume from existing state and rerun gates before editing.")
    else:
        action = "continue"
        reasons.append("No blocking runtime conditions detected.")

    allowed_next_steps = {
        "block": [
            "Read .orocsy/delivery/inbox/ and fix the listed corrections.",
            "Record validation evidence after the fix.",
            "Resolve the correction item before handoff.",
        ],
        "retry": [
            "Resume the existing workspace, do not restart from scratch.",
            "Read the latest event and rerun pre-change gates.",
            "Record recovery evidence before handoff.",
        ],
        "continue": [
            "Continue the current MIU.",
            "Record tool/test/eval evidence before handoff.",
        ],
    }[action]

    return {
        "status": "failed" if action == "block" else "warn" if action == "retry" else "passed",
        "action": action,
        "workspace": str(workspace),
        "issue": snapshot.get("issue"),
        "reasons": reasons,
        "open_corrections": corrections,
        "snapshot": snapshot,
        "allowed_next_steps": allowed_next_steps,
    }


def command_symphony_guidance(args: argparse.Namespace) -> int:
    workspace = repo_path(args.workspace)
    guidance = guidance_for_workspace(workspace, stale_minutes=args.stale_minutes)
    if args.record and current_state_path(workspace).exists():
        run_status = {"block": "blocked", "retry": "retry-ready", "continue": "running"}[guidance["action"]]
        append_event(
            workspace,
            {
                "event": "symphony.guidance",
                "phase": "guidance",
                "status": guidance["status"],
                "run_status": run_status,
                "action": guidance["action"],
                "reasons": guidance["reasons"],
            },
        )
    if args.json:
        print(json.dumps(guidance, indent=2, sort_keys=True))
    else:
        print(f"Orocsy Symphony guidance: {guidance['action']}")
        for reason in guidance["reasons"]:
            print(f"- {reason}")
    return 0 if guidance["status"] in {"passed", "warn"} else 1


def command_symphony_clean_generated(args: argparse.Namespace) -> int:
    repo = repo_path(args.repo)
    result = clean_generated_paths(repo, args.path or [])
    event: dict[str, Any] | None = None
    if args.record:
        event = append_event(
            repo,
            {
                "event": "symphony.generated.cleanup",
                "phase": "symphony-clean-generated",
                "status": result["status"],
                "removed": result["removed"],
                "skipped": result["skipped"],
                "blocked": result["blocked"],
            },
        )
    payload = {"cleanup": result, "event": event}
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"generated cleanup: {result['status']}")
        for path in result["removed"]:
            print(f"- removed {path}")
        for item in result["skipped"]:
            print(f"- skipped {item['path']}: {item['reason']}")
        for item in result["blocked"]:
            print(f"- blocked {item['path']}: {item['reason']}")
    return 0 if result["status"] in {"passed", "warn"} else 1


def command_control_status(args: argparse.Namespace) -> int:
    payload = {
        "status": "deferred",
        "reason": "Full control-plane actions wait until ledger, gates, evals, inbox, and guidance catch real failure modes reliably.",
        "supported_now": [
            "runtime ledger",
            "deterministic gates",
            "eval rubrics and verdict events",
            "correction inbox",
            "read-only Symphony monitor",
            "block/retry guidance",
        ],
        "deferred_actions": [
            "pause or resume external Symphony daemon",
            "kill worker processes",
            "mutate Linear state automatically",
            "mutate provider or production resources",
            "auto-merge pull requests",
            "budget enforcement",
        ],
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print("Orocsy control plane: deferred")
        print(payload["reason"])
    return 0


def symphony_prelude(issue: str) -> list[str]:
    issue_text = issue or "<issue>"
    return [
        "Read AGENTS.md, .orocsy/delivery/state/current.json, and .orocsy/delivery/policy.yml before editing.",
        "Do not load global/plugin skill bodies during the first worker turn; this workflow and the workspace-local Orocsy CLI are the runtime instructions.",
        "Use the workspace-local .codex/delivery/bin/orocsy.py CLI for runtime gates and event evidence.",
        f"Read the assigned issue {issue_text}, including write scope, dependencies, validation, and out-of-scope notes.",
        "Before optional skills, broad docs, or more than eight implementation files, record substantive progress: a scoped edit, focused validation after a change, handoff proof, or an inbox correction for a blocker. review-feedback-classified, technical-miu-trace, and first-turn-miu-handoff are lifecycle context only.",
        "Confirm pre-change gates with `python3 .codex/delivery/bin/orocsy.py --repo . gate all --json`; the ledger is .orocsy/delivery/events/events.jsonl.",
        "Use `python3 .codex/delivery/bin/orocsy.py --repo . symphony clean-generated --record` for bounded ignored generated-artifact cleanup; do not run raw cleanup shell commands.",
        "Implement one MIU at a time and append tool/test/build/browser events.",
        "Run post-MIU, pre-commit, and pre-push gates before handoff.",
        "Run or record applicable Orocsy eval rubrics before handoff.",
    ]


def install_workspace_orocsy_cli(repo: Path, source_cli: str) -> str | None:
    if not source_cli:
        return None
    source_path = Path(source_cli).expanduser()
    if not source_path.exists() or not source_path.is_file():
        return None
    target_path = repo / ".codex" / "delivery" / "bin" / "orocsy.py"
    write_text(target_path, read_text(source_path))
    target_path.chmod(0o755)
    return str(target_path.relative_to(repo))


def command_symphony_prepare_workspace(args: argparse.Namespace) -> int:
    repo = repo_path(args.repo)
    ensure_runtime_git_excludes(repo)
    issue_requirements: dict[str, Any] = {}
    if args.issue_file:
        issue_requirements = load_issue_requirements(repo_path(args.issue_file))

    issue = args.issue or issue_requirements.get("identifier") or ""
    intent = args.intent or issue_requirements.get("title") or (f"Symphony issue {issue}" if issue else "Symphony worker run")
    state = ensure_runtime_files(repo, intent=intent, issue=issue)
    state["status"] = "dispatch-ready"
    state["phase"] = "symphony-prepare"
    state["intent"] = intent
    state["issue"] = issue
    state["workspace"] = args.workspace or str(repo)
    if issue_requirements:
        state["issue_requirements"] = issue_requirements
    if args.orocsy_cli:
        state["orocsy_cli"] = args.orocsy_cli
    workspace_cli = install_workspace_orocsy_cli(repo, args.orocsy_cli)
    if workspace_cli:
        state["workspace_orocsy_cli"] = workspace_cli
    write_json(current_state_path(repo), state)

    validation = issue_requirements.get("validation") or {}
    scope = [*(args.scope or []), *string_list(issue_requirements.get("write_scope"))]
    evidence_files = [*(args.evidence_file or []), *string_list(validation.get("files"))]
    evidence_events = [*(args.evidence_event or []), *string_list(validation.get("events"))]
    evidence_commands = [*(args.evidence_command or []), *string_list(validation.get("commands"))]

    update_runtime_config(
        repo,
        declared_scope=scope,
        required_files=evidence_files,
        required_events=evidence_events,
        required_commands=evidence_commands,
        forbidden_terms=args.forbid or [],
    )

    event = append_event(
        repo,
        {
            "event": "symphony.workspace.prepared",
            "phase": "symphony-prepare",
            "run_status": "dispatch-ready",
            "issue": issue,
            "intent": intent,
            "workspace": state["workspace"],
            "orocsy_cli": args.orocsy_cli,
            "workspace_orocsy_cli": workspace_cli,
            "issue_requirements": issue_requirements,
            "declared_scope": scope,
            "required_evidence_files": evidence_files,
            "required_event_types": evidence_events,
            "required_commands": evidence_commands,
        },
    )

    prelude = symphony_prelude(issue)
    if args.json:
        print(json.dumps({"state": state, "event": event, "prelude": prelude}, indent=2, sort_keys=True))
    else:
        print(f"prepared Orocsy Symphony workspace for {issue or 'unassigned issue'}")
        print("Worker prelude:")
        for index, item in enumerate(prelude, 1):
            print(f"{index}. {item}")
    return 0


def command_symphony_monitor(args: argparse.Namespace) -> int:
    root = repo_path(args.root)
    checked_at = datetime.now(timezone.utc).replace(microsecond=0)
    if not root.exists() or not root.is_dir():
        payload = {
            "status": "failed",
            "checked_at": checked_at.isoformat().replace("+00:00", "Z"),
            "root": str(root),
            "error": "workspace_root_missing",
            "workspaces": [],
            "summary": {
                "count": 0,
                "stale": 0,
                "dirty": 0,
                "missing_delivery_state": 0,
            },
        }
        emit_monitor_output(payload, json_output=args.json)
        return 1

    workspaces = [
        workspace_monitor_snapshot(candidate, checked_at=checked_at, stale_minutes=args.stale_minutes)
        for candidate in workspace_candidates(root, include_empty=args.include_empty)
    ]
    status = monitor_status(workspaces, strict=args.strict)
    payload = {
        "status": status,
        "checked_at": checked_at.isoformat().replace("+00:00", "Z"),
        "root": str(root),
        "stale_minutes": args.stale_minutes,
        "workspaces": workspaces,
        "summary": {
            "count": len(workspaces),
            "stale": sum(1 for workspace in workspaces if workspace["stale"]),
            "dirty": sum(1 for workspace in workspaces if workspace["git"].get("dirty_paths")),
            "missing_delivery_state": sum(
                1 for workspace in workspaces if "delivery_state_missing" in workspace["warnings"]
            ),
        },
    }
    emit_monitor_output(payload, json_output=args.json)
    return 0 if status in {"passed", "warn"} else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Orocsy Delivery Runtime CLI")
    parser.add_argument("--repo", default=".", help="Project repo path")

    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init", help="Create runtime ledger files")
    init_parser.add_argument("--intent", default="", help="Current delivery intent")
    init_parser.add_argument("--issue", default="", help="Issue identifier")
    init_parser.add_argument("--force", action="store_true", help="Rewrite state and default runtime files")
    init_parser.add_argument("--json", action="store_true", help="Print JSON output")
    init_parser.set_defaults(func=command_init)

    run_parser = subparsers.add_parser("run", help="Run lifecycle commands")
    run_subparsers = run_parser.add_subparsers(dest="run_command", required=True)
    start_parser = run_subparsers.add_parser("start", help="Mark the current run as started")
    start_parser.add_argument("--intent", default="", help="Current delivery intent")
    start_parser.add_argument("--issue", default="", help="Issue identifier")
    start_parser.add_argument("--json", action="store_true", help="Print JSON output")
    start_parser.set_defaults(func=command_run_start)

    event_parser = subparsers.add_parser("event", help="Append runtime events")
    event_subparsers = event_parser.add_subparsers(dest="event_command", required=True)
    append_parser = event_subparsers.add_parser("append", help="Append one event")
    append_parser.add_argument("--type", required=True, help="Event type")
    append_parser.add_argument("--status", default="info", help="Event status")
    append_parser.add_argument("--phase", default="", help="Runtime phase")
    append_parser.add_argument("--step", default="", help="Step name")
    append_parser.add_argument("--tool", default="", help="Tool name")
    append_parser.add_argument("--command", default="", help="Command evidence")
    append_parser.add_argument("--artifact", action="append", default=[], help="Artifact path")
    append_parser.add_argument("--json", action="store_true", help="Print JSON output")
    append_parser.set_defaults(func=command_event_append)

    gate_parser = subparsers.add_parser("gate", help="Run deterministic gates")
    gate_parser.add_argument("gate", choices=["all", *GATE_FUNCTIONS.keys()])
    gate_parser.add_argument("--forbid", action="append", default=[], help="Additional forbidden term")
    gate_parser.add_argument("--scope", action="append", default=[], help="Declared scope glob")
    gate_parser.add_argument("--evidence-file", action="append", default=[], help="Required evidence file")
    gate_parser.add_argument("--evidence-event", action="append", default=[], help="Required event type")
    gate_parser.add_argument("--evidence-command", action="append", default=[], help="Required command text")
    gate_parser.add_argument("--strict", action="store_true", help="Treat warnings as failures")
    gate_parser.add_argument("--record", action="store_true", help="Append gate result to events.jsonl")
    gate_parser.add_argument("--inbox", action="store_true", help="Create a correction inbox item on failure")
    gate_parser.add_argument("--json", action="store_true", help="Print JSON output")
    gate_parser.set_defaults(func=command_gate)

    tokens_parser = subparsers.add_parser("tokens", help="Token telemetry report commands")
    tokens_subparsers = tokens_parser.add_subparsers(dest="tokens_command", required=True)
    tokens_summary_parser = tokens_subparsers.add_parser("summary", help="Summarize worker token telemetry")
    tokens_summary_parser.add_argument("--issue", default="", help="Filter by issue identifier")
    tokens_summary_parser.add_argument("--worker", default="", help="Filter by worker session id")
    tokens_summary_parser.add_argument("--limit", type=int, default=10, help="Maximum worker summaries to print")
    tokens_summary_parser.add_argument("--json", action="store_true", help="Print JSON output")
    tokens_summary_parser.set_defaults(func=command_tokens_summary)

    tokens_spans_parser = tokens_subparsers.add_parser("spans", help="List highest token telemetry spans")
    tokens_spans_parser.add_argument("--issue", default="", help="Filter by issue identifier")
    tokens_spans_parser.add_argument("--worker", default="", help="Filter by worker session id")
    tokens_spans_parser.add_argument("--limit", type=int, default=50, help="Maximum spans to print")
    tokens_spans_parser.add_argument("--json", action="store_true", help="Print JSON output")
    tokens_spans_parser.set_defaults(func=command_tokens_spans)

    eval_parser = subparsers.add_parser("eval", help="LLM/human eval rubric commands")
    eval_subparsers = eval_parser.add_subparsers(dest="eval_command", required=True)
    eval_list_parser = eval_subparsers.add_parser("list", help="List available eval rubrics")
    eval_list_parser.add_argument("--json", action="store_true", help="Print JSON output")
    eval_list_parser.set_defaults(func=command_eval_list)

    rubric_parser = eval_subparsers.add_parser("rubric", help="Print one eval rubric")
    rubric_parser.add_argument("rubric", choices=list(EVAL_RUBRICS))
    rubric_parser.add_argument("--json", action="store_true", help="Print JSON output")
    rubric_parser.set_defaults(func=command_eval_rubric)

    write_rubrics_parser = eval_subparsers.add_parser("write-rubrics", help="Write eval rubric files")
    write_rubrics_parser.add_argument("--force", action="store_true", help="Rewrite existing rubric files")
    write_rubrics_parser.add_argument("--json", action="store_true", help="Print JSON output")
    write_rubrics_parser.set_defaults(func=command_eval_write_rubrics)

    record_eval_parser = eval_subparsers.add_parser("record", help="Record an eval verdict")
    record_eval_parser.add_argument("rubric", choices=list(EVAL_RUBRICS))
    record_eval_parser.add_argument("--status", required=True, choices=["passed", "failed", "warn"])
    record_eval_parser.add_argument("--summary", required=True, help="Short eval summary")
    record_eval_parser.add_argument("--finding", action="append", default=[], help="Specific finding")
    record_eval_parser.add_argument("--required-correction", action="append", default=[], help="Required correction")
    record_eval_parser.add_argument("--inbox", action="store_true", help="Create a correction inbox item on warn/failure")
    record_eval_parser.add_argument("--json", action="store_true", help="Print JSON output")
    record_eval_parser.set_defaults(func=command_eval_record)

    inbox_parser = subparsers.add_parser("inbox", help="Correction inbox commands")
    inbox_subparsers = inbox_parser.add_subparsers(dest="inbox_command", required=True)
    inbox_create_parser = inbox_subparsers.add_parser("create", help="Create a correction item")
    inbox_create_parser.add_argument("--source", required=True, help="Correction source")
    inbox_create_parser.add_argument("--status", default="failed", help="Source status")
    inbox_create_parser.add_argument("--summary", required=True, help="Correction summary")
    inbox_create_parser.add_argument("--finding", action="append", default=[], help="Finding")
    inbox_create_parser.add_argument("--required-correction", action="append", default=[], help="Required correction")
    inbox_create_parser.add_argument("--next-action", choices=["block", "retry", "escalate"], default="block")
    inbox_create_parser.add_argument("--json", action="store_true", help="Print JSON output")
    inbox_create_parser.set_defaults(func=command_inbox_create)

    inbox_list_parser = inbox_subparsers.add_parser("list", help="List correction items")
    inbox_list_parser.add_argument("--open-only", action="store_true", help="Only show unresolved corrections")
    inbox_list_parser.add_argument("--json", action="store_true", help="Print JSON output")
    inbox_list_parser.set_defaults(func=command_inbox_list)

    inbox_resolve_parser = inbox_subparsers.add_parser("resolve", help="Resolve a correction item")
    inbox_resolve_parser.add_argument("correction", help="Correction id or file name")
    inbox_resolve_parser.add_argument("--summary", required=True, help="Resolution summary")
    inbox_resolve_parser.add_argument("--json", action="store_true", help="Print JSON output")
    inbox_resolve_parser.set_defaults(func=command_inbox_resolve)

    control_parser = subparsers.add_parser("control", help="Control-plane boundary commands")
    control_subparsers = control_parser.add_subparsers(dest="control_command", required=True)
    control_status_parser = control_subparsers.add_parser("status", help="Show supported and deferred controls")
    control_status_parser.add_argument("--json", action="store_true", help="Print JSON output")
    control_status_parser.set_defaults(func=command_control_status)

    symphony_parser = subparsers.add_parser("symphony", help="Symphony integration commands")
    symphony_subparsers = symphony_parser.add_subparsers(dest="symphony_command", required=True)
    prepare_parser = symphony_subparsers.add_parser(
        "prepare-workspace",
        help="Initialize Orocsy state and policy for a Symphony worker workspace",
    )
    prepare_parser.add_argument("--issue", default="", help="Issue identifier")
    prepare_parser.add_argument("--issue-file", default="", help="Linear-style issue requirements JSON")
    prepare_parser.add_argument("--intent", default="", help="Worker intent")
    prepare_parser.add_argument("--workspace", default="", help="Symphony workspace path")
    prepare_parser.add_argument("--orocsy-cli", default="", help="Resolved Orocsy runtime CLI path")
    prepare_parser.add_argument("--scope", action="append", default=[], help="Declared write scope glob")
    prepare_parser.add_argument("--evidence-file", action="append", default=[], help="Required evidence file")
    prepare_parser.add_argument("--evidence-event", action="append", default=[], help="Required event type")
    prepare_parser.add_argument("--evidence-command", action="append", default=[], help="Required command text")
    prepare_parser.add_argument("--forbid", action="append", default=[], help="Project-specific forbidden term")
    prepare_parser.add_argument("--json", action="store_true", help="Print JSON output")
    prepare_parser.set_defaults(func=command_symphony_prepare_workspace)

    monitor_parser = symphony_subparsers.add_parser(
        "monitor",
        help="Read-only snapshot of Symphony workspaces and Orocsy runtime state",
    )
    monitor_parser.add_argument(
        "--root",
        default="~/.codex/symphony-workspaces",
        help="Symphony workspace root or one workspace path",
    )
    monitor_parser.add_argument("--stale-minutes", type=int, default=30, help="Minutes before a run is stale")
    monitor_parser.add_argument("--include-empty", action="store_true", help="Include child directories without git/runtime state")
    monitor_parser.add_argument("--strict", action="store_true", help="Return failure when warnings are present")
    monitor_parser.add_argument("--json", action="store_true", help="Print JSON output")
    monitor_parser.set_defaults(func=command_symphony_monitor)

    guidance_parser = symphony_subparsers.add_parser(
        "guidance",
        help="Return controlled block/retry/continue guidance for one workspace",
    )
    guidance_parser.add_argument("--workspace", default=".", help="Symphony workspace path")
    guidance_parser.add_argument("--stale-minutes", type=int, default=30, help="Minutes before a run is stale")
    guidance_parser.add_argument("--record", action="store_true", help="Append guidance event to the workspace ledger")
    guidance_parser.add_argument("--json", action="store_true", help="Print JSON output")
    guidance_parser.set_defaults(func=command_symphony_guidance)

    clean_parser = symphony_subparsers.add_parser(
        "clean-generated",
        help="Remove allowlisted git-ignored generated artifacts from a worker workspace",
    )
    clean_parser.add_argument(
        "--path",
        action="append",
        default=[],
        help="Generated path to remove; defaults to .next/dev",
    )
    clean_parser.add_argument("--record", action="store_true", help="Append cleanup event to the workspace ledger")
    clean_parser.add_argument("--json", action="store_true", help="Print JSON output")
    clean_parser.set_defaults(func=command_symphony_clean_generated)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
