# Review: OpenAI Extension Migration Technical MIU Design

Status: **Finalized — OXE-0.1 APPROVED for implementation after the parent
approval gate. The design findings are resolved; privacy-safe corpus
preservation remains an explicit pre-Slice operational prerequisite.**

Date: 2026-07-29

Reviewer: claude (co-review channel `openai-extension`; relay state in
`.claude/co-review/openai-extension/REVIEW-CYCLE.md`)

Artifact reviewed: `elixir/docs/openai_extension_miu_technical_design.md`
(authored by codex, untracked on branch `codex/openai-extension-architecture`;
content sha256 prefix 653ba76f9dabfbd2, 454 lines), plus the 8-line
"Technical MIU Traces" link section added to the parent architecture doc.

## Plain-language summary

Codex's first implementation unit is a small tool that proves, mechanically,
that the code being built on really is the exact OpenAI version the whole plan
is pinned to — right commit, right content, right branch topology — before
anything else is built on top. That is the correct first brick: every later
promise ("no-op mode matches upstream", "kernel changes stay within budget")
is only checkable against a trusted baseline, and this makes the baseline
machine-checked instead of a sentence in a document.

The unit is well designed: it never touches the network, never modifies
anything, fails with typed error codes instead of prose, and its test list
includes the one counterexample that matters most — content that is correct
but merged in the wrong direction. I verified every factual claim in the doc
independently (both tree hashes, the ancestry statement, the toolchain APIs
and make targets it relies on, in both the fork and the upstream tree). All
exact.

One real finding: the plan makes archiving the old runtime logs wait behind
branch setup it doesn't need. Those logs are the only record of how the old
system behaved, they exist on one machine, and they are not in git — saving
them should not wait for anything.

## Verified facts (round 1)

| Claim in doc | Verification |
| --- | --- |
| Repository tree `37a4c6c1…` for pinned commit | `git rev-parse f8e8b8a^{tree}` — exact match |
| `elixir/` subtree `77d9ba67…` | `git rev-parse f8e8b8a:elixir` — exact match |
| Design branch does not descend from baseline | `git merge-base --is-ancestor` — confirmed false |
| Only `origin` remote configured | confirmed (`openai/*` refs exist but no durable remote config) |
| `make all` handoff validation exists | `all: ci` in fork AND upstream Makefiles |
| `mix specs.check` exists upstream | `specs.check` task present in pinned tree |
| `Mix.Project.project_file/0` available | added Elixir 1.15; project requires `~> 1.19` |

## MIU-methodology conformance (OXE-0.1)

Judged in substance against the two-level decomposition rubric; the doc uses
the repo's own trace format (Runtime Problem / Data Shape / Constraint / Flow /
Alternatives / Code Translation / Risk-Test), which is richer than the minimum:

- Technical naming, not product language — pass (`ExtensionsAudit`,
  `mix extensions.audit --only baseline`).
- Smallest testable unit — pass. The manifest, library, Mix task, and focused
  tests form one observable command contract; splitting them would create
  non-functional fragments. The repository MIU standard defines no numeric
  file-count limit.
- Dependencies form a DAG, no cycles, contract-before-consumer — pass. The
  manifest (contract) and its verifier land together and precede every
  consumer (OXE-0.2 budget audit consumes the verified baseline).
- TDD test plan with exact failing tests — pass, including the two hardest
  cases: second-parent-only reachability must fail
  (`:baseline_not_on_first_parent`), and shallow-clone missing history must
  fail closed with no fetch. Side-effect negative test present ("never invokes
  fetch/checkout/merge/reset/config", enforced via injected git function).
- Build/Deploy/Runtime impact stated — pass: no CI wiring yet (explicitly
  deferred to OXE-0.9), no mutation of files/refs/config (acceptance 6), no
  runtime behavior (acceptance 7).
- Scope discipline — pass, and worth praise: it refuses to define
  `UPSTREAM_PATCH_BUDGET.yml` now because real hook paths don't exist until
  the Slice 1 prototype ("adding them now would create false precision"), and
  it names a disposable hook prototype to inform OXE-0.2 instead of guessing.
  This resolves the round-2 note about budgets being set after the prototype.

Design-quality notes in the doc's favor: the first-parent check
(`git rev-list --first-parent` containment, not just `--is-ancestor`) encodes
the exact merge-topology invariant from architecture review round 1 into CI;
typed finding codes; strict manifest (unknown keys rejected, full 40-char SHAs
only, validated before any value reaches `System.cmd/3` as a revision);
argument-list git invocation, no shell interpolation; worktree-safe root
detection.

## Findings

### [P2] Trace-corpus archival is gated behind branch mechanics it does not need — locator: Slice 0 Decomposition DAG

The DAG places OXE-0.5 (trace archive and sanitizer) downstream of Bootstrap
and OXE-0.1. But the archive half of OXE-0.5 is data preservation of volatile,
gitignored, single-machine logs (`elixir/log/symphony.log.1-5`, ~45 MB, the
only behavioral record of the old runtime — architecture Slice 0 already
acknowledges this). Archival requires no integration branch, no baseline
verifier, and no code in this repo; every day it waits is risk with zero
compensating benefit. Recommendation: split OXE-0.5 into (a) an immediate
archival action — copy + checksum the corpus to durable storage now, before
any Slice 0 code — and (b) the in-repo sanitizer/fixture tooling, which keeps
its current DAG position. The doc should state that (a) is already done or
scheduled independently of the branch model.

### [P3] Manifest shape drift between parent architecture and this trace — locator: Data Shape

The parent architecture's Upstream Sync Governance section still shows a
5-field manifest (`repository/commit/version/spec_status/verified_at`); this
trace defines the authoritative 8-field strict schema (adds `schema_version`,
`tree`, `elixir_tree`) that rejects unknown keys. Since OXE-0.1's
implementation "updates the parent architecture to name UPSTREAM_BASE.yml as
machine authority", that same edit must replace the 5-field example — two
different manifest shapes in two normative docs is exactly the two-sources
defect this migration keeps eliminating.

### [P3] Round-2 architecture follow-ups still open while the doc is being touched — locator: parent doc

The parent doc was edited this round (trace link section) but the two one-line
round-2 fixes are still pending: the state machine still reads
`ContractRejected --> AdmissionPending: issue revision changed` (contradicts
the contract-source-hash dedupe rule), and the canary section still says
"compare against E1-E15" (list now ends at E25). Fold both into the next
parent-doc edit — each is a one-line change.

## Watch item (not a doc defect)

The baseline audit is lineage-dependent by design: it fails on any branch not
descended from the pinned commit — which includes every old-`main`-lineage
hotfix branch during the freeze window. That is correct behavior, but it means
the audit's CI wiring must stay scoped to the integration lineage. OXE-0.9
(which owns gate wiring) should state the branch scoping explicitly so the
audit never lands in CI config shared with the frozen fork.

## Verdict

OXE-0.1 is approved as specified — implement it as the first unit once the
parent approval gate is formally accepted. The P2 archival split should be
decided before Slice 0 starts (it changes what happens first); the P3s ride
along with the next doc edit. The stated next design action (OXE-0.2 trace
derived from a real hook prototype, not guessed budgets) is the right one.

## Codex Finalization — 2026-07-30

The review was checked independently against the architecture, MIU trace,
repository state, and co-review protocol.

| Review item | Final disposition |
| --- | --- |
| Trace preservation sequencing | Accepted with a privacy correction. Source-log protection and checksums begin before branch work. Raw data may enter only an owner-approved restricted quarantine; the redacted durable archive still requires automated secret scanning and human privacy review. No external preservation receipt is claimed yet. |
| Manifest schema drift | Resolved. The parent now carries the same strict eight-field schema and names `UPSTREAM_BASE.yml` as machine authority. |
| Rejection transition label | Resolved as `contract source or policy changed`. |
| Canary scenario reference | Resolved as the applicable E1-E25 scenarios, with the canary plan required to map live versus replay/contract/CI proof. |
| OXE-0.9 CI watch | Captured as lineage-scoped execution. Shared CI configuration remains valid when conditions prevent the audit on old-`main` hotfix branches. |
| MIU file-count rubric | Corrected. The repository MIU standard has no three-file guideline or named exception. |
| Co-review handoff metadata | Corrected. The turn marker and cursor agree, and architecture and MIU artifacts have separate structured sources. |

One review recommendation was not accepted literally: copying raw logs to
general durable storage before redaction would violate the architecture's
privacy boundary. The finalized design separates restricted quarantine from
the redacted long-lived archive while preserving the urgency of the finding.

---

# Round 2 addendum (2026-07-30) — owner ruling on dual-fidelity, and one new P1 design requirement

## Owner ruling (recorded)

The owner ruled on the branch-sequencing question: **intermediate branch
mechanics do not matter. What matters is that the final runtime provably
preserves BOTH the fork's three months of delivery improvements AND upstream's
battle-proven behavior.** Working directly on the pinned baseline is blessed;
the MIU precondition wording ("merge Orocsy history first") should be relaxed
to match, and the merge remains Slice 2's concern.

## Double-check result: the two sides are NOT equally protected today

Asked to verify that the design guarantees both sides, I re-audited revision 2.

**Upstream side — structurally protected, no gap.** Pinned immutable baseline
verified by OXE-0.1; same-path files resolved in upstream's favor; no-op
extension mode must be behaviorally identical to the pinned kernel (E16);
kernel divergence capped by the patch budget + `mix extensions.audit`; every
FUTURE upstream commit gets a per-commit `adopt/adapt/superseded/irrelevant`
classification in sync governance. Upstream behavior cannot silently drift.

**Orocsy side — protected in depth but not in COVERAGE.** The design ports a
behavior only when "a characterization test and an explicit extension owner
prove that the behavior is still required" — drop-by-default. That is the
right default for accidental behavior, but nothing enumerates the candidate
set. The port-forward ledger covers only freeze-window hotfixes; the per-commit
classification covers only upstream commits. The existing 229 fork commits —
the very thing the owner does not want to lose — have NO completeness
mechanism: a behavior nobody happens to write a characterization test for
vanishes without anyone having decided to drop it. "We decided to drop X" and
"X fell through the cracks" are indistinguishable in the current design.

### [P1] design: add a fork-behavior disposition ledger with a zero-unclassified gate — locator: OXE-0.7 / Slice 0

Requirement for the OXE-0.7 trace (and a sentence in the parent architecture):
apply the design's own ledger tool — already used twice, for upstream commits
and for hotfixes — to the existing fork history.

- **Seed rows mechanically.** The 229 commits cluster tractably: 199 May
  commits built the delivery layer that `workflows/symphony-runtime-delivery.md`
  (Status: Implemented) already specifies behavior-by-behavior — disposition
  those at the behavior level from that document plus the three design docs
  and E1-E25. The 30 June/July commits are discrete reviewed incident fixes
  (#4x-#73) — one row each, since each encodes a production lesson.
- **Every row gets exactly one disposition:** `port` (names its
  characterization test + target owner from the Legacy-To-Target mapping) /
  `superseded-by-upstream` (names the upstream commit) / `drop`
  (owner-acknowledged, with reason) / `defer` (named slice).
- **Completeness is gated, not aspirational:** OXE-0.9 and the cutover
  checklist require zero unclassified rows, mirroring "port-forward ledger has
  no unresolved port entries."

This makes the owner's ruling enforceable in both directions: upstream fidelity
is already machine-checked by OXE-0.1; fork fidelity becomes checkable by the
ledger + characterization corpus. Without it, only one side of the "respect
both" promise has teeth.
