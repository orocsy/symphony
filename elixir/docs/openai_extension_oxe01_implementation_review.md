# Review: OXE-0.1 Implementation (extensions.audit baseline verifier)

Status: **Round 1 — BLOCKED. 3 P1 findings (1 production, 2 test-infrastructure).
Implementation quality is otherwise high; fix the P1s and this clears.**

Date: 2026-07-30

Reviewer: claude (co-review channel `openai-extension`)

Artifact reviewed: commits `8883315..8b652b3` on branch
`codex/openai-extension-integration` (worktree
/private/tmp/orocsy-symphony-openai-extension-integration) — 994 insertions
across 9 files: `UPSTREAM_BASE.yml`, `extensions_audit.ex` (327),
`extensions.audit.ex` task (61), two test files (472), README/doc updates.

Full ranked findings table: `.claude/review-findings-8b652b3.md` (20 findings:
3 P1 / 8 P2 / 9 P3, plus 2 owner decisions).

## Plain-language summary

The implementation is genuinely good — every promise in the design trace was
kept: all 15 error codes exist exactly as specified, the output format matches
byte-for-byte, all 15 promised tests exist and none of them are fake, the
hardest test (correct content merged in the wrong direction must fail) builds
a real git repository and proves it, and the code passes the formatter, the
linter at strict level, the spec checker, and 100% line coverage. I ran
everything myself: the new tests pass, the audit prints exactly the promised
line on the integration branch, and correctly fails with a typed error and
exit code 1 elsewhere.

But three problems must be fixed before this merges, and one of them matters
a lot:

1. **The audit can be silently pointed at the wrong repository.** Git respects
   an environment variable (`GIT_DIR`) that overrides which repository a
   command talks to — and git itself sets that variable when it runs hooks,
   which is exactly where a "verify before push" tool ends up wired. I
   reproduced it: with that variable present, the audit reported a clean pass
   for a repository that does not contain the pinned commit at all. The fix is
   small (explicitly clear git's environment variables when invoking git), but
   without it the tool's core guarantee is hollow.
2. **CI will be red on the first pull request.** Five tests check the real
   repository instead of a throwaway fixture, and the GitHub workflow checks
   out only the newest commit — so the pinned baseline commit won't exist in
   CI's shallow clone and those five tests fail there.
3. **The test suite is red for any human running it in a terminal.** One test
   compares error output byte-for-byte, but Mix colors error text when a
   terminal is attached. It only passes in CI-style environments (that is why
   my own run was green). The repo already has a color-stripping helper; it
   just wasn't used.

Everything else is polish-level: better error labels for permission problems,
a stricter YAML reading mode, making the task visible in `mix help`, and
turning a "don't call these git commands" test into the stronger "only these
four git commands are ever allowed" form.

## What I verified myself (not taken from the doc or from Codex)

- 21/21 new tests pass; full suite's only failures (2–4 depending on run) are
  timing-flaky tests in upstream files this diff never touched — and Codex
  had already disclosed exactly those in the trace's disposition table.
- `mix extensions.audit --only baseline` on the integration branch prints the
  byte-exact promised success line; against a root without the manifest it
  exits 1 with a typed finding.
- `mix specs.check` passes; reviewers confirmed `mix format --check-formatted`
  and `mix credo --strict` pass and both new modules have 100.00% coverage.
- The GIT_DIR false-PASS reproduces (two independent reproductions: at module
  level and shell level).
- The CI workflow has no `fetch-depth` override (shallow clone confirmed).
- ANSI wrapping of the asserted stderr string confirmed empirically.
- The first-parent counterexample fixture builds a real orphan-branch merge
  where the baseline is second-parent-only, and asserts the exact finding code.

## P1 findings (block merge)

1. **Git environment leak → false PASS against the wrong repository.**
   `extensions_audit.ex:58,321`. `System.cmd`'s `:env` adds, it does not
   sanitize; `git -C` does not override `GIT_DIR`; the worktree guard passes
   because `--show-toplevel` follows `-C`. Fix: add nil-valued entries to
   `@git_env` to unset `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`,
   `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`,
   `GIT_INDEX_FILE`, `GIT_NAMESPACE`, `GIT_CEILING_DIRECTORIES`,
   `GIT_DISCOVERY_ACROSS_FILESYSTEM` (System.cmd unsets on nil — verified),
   and add a regression test that sets `GIT_DIR` and asserts findings are
   unchanged.
2. **Five ambient-repository tests fail under CI's shallow checkout.**
   `extensions_audit_test.exs:119,140`, `extensions_audit_task_test.exs:13,23,38`
   vs `.github/workflows/make-all.yml` (checkout@v4, default depth 1). Convert
   to hermetic fixtures (the fixture machinery already exists in the same
   file); at most one opt-in smoke test against the real root.
3. **ANSI-colored stderr breaks the exact-equality task test in any TTY.**
   `extensions_audit_task_test.exs:66-68`. Use the existing `strip_ansi/1`
   helper or force `ansi_enabled: false` in test setup.

## P2 highlights (fix in the same rework)

- Git non-zero exits are conflated with semantic mismatches and raw `fatal:`
  output leaks into findings — a partial clone reads as "baseline tampered"
  instead of "deepen the clone", and the trace's no-config-leak output promise
  is broken (`extensions_audit.ex:234,285,312`).
- `rescue … in ErlangError` catches every Erlang runtime error (verified for
  `CaseClauseError`), so fixture mistakes become passing `:git_unavailable`
  findings; rescue narrowly and reraise.
- Strict manifest decoding accepts duplicate keys and multi-document YAML
  (verified against the vendored yaml_elixir) — the "human reads one commit,
  audit verifies another" case the strict schema exists to prevent.
- `@moduledoc false` hides the task from `mix help` — the only sibling-task
  idiom deviation, with a functional cost.
- Contract test should be an allowlist of the four read-only git subcommands,
  not a blacklist; fixtures should isolate from global git config (hooksPath,
  gpgsign) — this machine's global hooksPath demonstrably applies.
- Unreadable-manifest errors (`:eacces`) mislabeled as invalid YAML.

## Owner decisions needed (process, not code)

- **A. Branch model deviation.** The MIU precondition required the Orocsy-main
  merge (OpenAI first-parent) before implementation; the integration branch is
  instead linear from the baseline with docs carried over, merge deferred.
  Codex disclosed this as an Open row rather than hiding it. Decide: bless the
  deferred-merge sequencing (and update the branch model + precondition
  wording), or perform the merge before the next MIU. Deferring is defensible
  — the merge is Slice 2's concern and a linear base keeps MIU-1 reviewable —
  but the docs must then say so.
- **B. Trace corpus is still single-host.** The receipt records checksums and
  access controls in place, and honestly states no durable off-host archive
  exists; that step needs your approval per the receipt. The loss-risk window
  stays open until then.

## Verdict

BLOCK until P1s 1–3 are fixed (P1-1 is a small, well-understood patch; P1-2/3
are test-infrastructure changes with existing machinery). The P2s should ride
in the same rework commit. This is otherwise the strongest artifact in the
channel so far: promises kept exactly, deviations disclosed rather than
buried, and validation reproducible end to end. HEAD `8b652b3` is NOT blessed;
do not push or merge until re-review.
