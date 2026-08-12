# Review: OXE-0.1 Implementation (extensions.audit baseline verifier)

Status: **Round 2 — implementation findings cleared. Landing remains blocked
only by the required full handoff gate.**

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

- **A. Branch model deviation — RESOLVED by owner ruling 2026-07-30.** The
  owner ruled: intermediate branch mechanics do not matter; what matters is
  that the final runtime provably preserves both the fork's improvements and
  upstream's proven behavior. Deferred-merge sequencing is blessed; Codex must
  relax the MIU precondition wording accordingly. The "provably preserves
  both" half became a new P1 design requirement (fork-behavior disposition
  ledger) — see the round-2 addendum in
  `openai_extension_miu_technical_design_review.md`.
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

---

## Round 2 Rework Disposition — 2026-08-13

Rework commits `923e158`, `9862dfd`, `111f8a4`, and `9994f23` resolve all
three P1 and eight P2 implementation findings above. The final adversarial
re-review found and closed two additional P2 boundaries before handoff:

- top-level YAML sequences now fail with typed `:manifest_invalid_yaml`
  findings rather than crashing the duplicate-key decoder;
- inherited Git trace/trace2, packet, performance, ref, setup, shallow,
  fsmonitor, pack-access, and curl diagnostics are removed so merged stderr
  cannot corrupt evidence or leak caller paths.

Independent final review results:

| Axis | Result |
| --- | --- |
| Spec | No surviving or new findings. All Round 1 and Round 2 adversarial cases are resolved. |
| Standards | No surviving code, test, documentation, or smell findings. Shared fixture cleanup is centralized and the deliberately independent Git environment is documented. |
| Repository gate | `P1` remains: exact `make all` is non-green on unchanged timing-sensitive pinned-upstream SSH/retry tests. |

Validation at final committed candidate `9994f23`:

- 28 focused audit/task tests pass;
- a real audit with `GIT_TRACE=1 GIT_TRACE2_EVENT=1` emits the clean stable
  success line;
- format, specs, Credo strict, build, direct audit, task help, Dialyzer, and
  100% total coverage pass;
- the fourth exact `make all` run executes 324 tests and stops on one unchanged
  retry lower-bound assertion at `core_test.exs:1062` (6 skipped, 100% total
  coverage).

The implementation itself is review-cleared. Repository policy still forbids
landing until the unchanged full-suite failures are fixed or formally waived.
