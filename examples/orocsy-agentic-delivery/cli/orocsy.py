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
import subprocess
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DELIVERY_ROOT = Path(".codex") / "delivery"
SCHEMA_VERSION = 1

DEFAULT_FORBIDDEN_TERMS: tuple[str, ...] = ()

DEFAULT_EXCLUDED_DIRS = {
    ".git",
    ".next",
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
    "node_modules/**",
    "dist/**",
    "build/**",
    "coverage/**",
    "playwright-report/**",
    "test-results/**",
    "__pycache__/**",
)

SECRET_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("aws-access-key", re.compile("AK" + r"IA[0-9A-Z]{16}")),
    ("private-key", re.compile("-----BEGIN " + r"[A-Z ]*" + "PRIVATE " + "KEY-----")),
    ("stripe-live-secret", re.compile("sk_" + r"live_[0-9A-Za-z]{16,}")),
    ("github-token", re.compile("gh" + r"p_[0-9A-Za-z]{20,}")),
    ("slack-token", re.compile("xo" + r"x[baprs]-[0-9A-Za-z-]{20,}")),
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


def ensure_runtime_files(repo: Path, *, intent: str, issue: str, force: bool = False) -> dict[str, Any]:
    root = delivery_root(repo)
    (root / "state").mkdir(parents=True, exist_ok=True)
    (root / "events").mkdir(parents=True, exist_ok=True)
    (root / "miu").mkdir(parents=True, exist_ok=True)
    (root / "evals").mkdir(parents=True, exist_ok=True)
    (root / "inbox").mkdir(parents=True, exist_ok=True)

    state_path = root / "state" / "current.json"
    if state_path.exists() and not force:
        state = load_json(state_path, {})
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

    events_path = root / "events" / "events.jsonl"
    events_path.touch(exist_ok=True)
    return state


def current_state_path(repo: Path) -> Path:
    return delivery_root(repo) / "state" / "current.json"


def events_path(repo: Path) -> Path:
    return delivery_root(repo) / "events" / "events.jsonl"


def append_event(repo: Path, event: dict[str, Any]) -> dict[str, Any]:
    state = ensure_runtime_files(repo, intent="", issue="")
    now = utc_now()
    event = dict(event)
    event.setdefault("schema_version", SCHEMA_VERSION)
    event.setdefault("event_id", new_id("evt"))
    event.setdefault("ts", now)
    event.setdefault("run_id", state.get("run_id"))
    event.setdefault("goal_id", state.get("goal_id"))

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


def run_git(repo: Path, args: list[str], *, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
    )


def is_git_repo(repo: Path) -> bool:
    result = run_git(repo, ["rev-parse", "--is-inside-work-tree"])
    return result.returncode == 0 and result.stdout.strip() == "true"


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


def path_matches_any(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(path, pattern) for pattern in patterns)


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
    scope = list(config.get("declared_scope", []))
    scope.extend(args.scope or [])
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


def gate_required_evidence(repo: Path, config: dict[str, list[str]], args: argparse.Namespace) -> GateResult:
    required_files = list(config.get("required_evidence_files", []))
    required_events = list(config.get("required_event_types", []))
    required_commands = list(config.get("required_commands", []))
    required_files.extend(args.evidence_file or [])
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


GATE_FUNCTIONS = {
    "leaks": gate_leaks,
    "secrets": gate_secrets,
    "artifacts": gate_artifacts,
    "git-state": gate_git_state,
    "declared-scope": gate_declared_scope,
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


def command_init(args: argparse.Namespace) -> int:
    repo = repo_path(args.repo)
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

    emit_gate_output(results, json_output=args.json, strict=args.strict)
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
    gate_parser.add_argument("--json", action="store_true", help="Print JSON output")
    gate_parser.set_defaults(func=command_gate)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
