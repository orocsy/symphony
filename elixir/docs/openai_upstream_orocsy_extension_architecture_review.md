# Review: OpenAI-Upstream Orocsy Extension Architecture

Status: Review round 1 — approve direction, revise before the approval gate

Date: 2026-07-29

Reviewer: claude (co-review channel `openai-extension`; live relay state in
`.claude/co-review/openai-extension/REVIEW-CYCLE.md`)

Artifact reviewed: `elixir/docs/openai_upstream_orocsy_extension_architecture.md`
(authored by codex, branch `codex/openai-extension-architecture`; content sha256
prefix ca27393b1f1c4350). Line references are against orocsy `main` @ 9a001b4 and
upstream `openai/main` @ f8e8b8a, approximate.

## Owner decisions taken during review

- **2026-07-29 — Worker backend is Codex-only.** No multi-worker support and no
  reserved seam for one. Codex-specific naming and protocol semantics in the
  kernel are accepted deliberately. See the resolved worker-heterogeneity
  finding below; the design doc must add this to Non-Goals.

## Plain-language summary

The fork's problem: three months of custom delivery logic (~27,500 added lines)
was written inside the same files OpenAI keeps changing, so every upstream sync
is a painful hand-merge. The design's answer: take OpenAI's code unmodified as a
"kernel", add a small number of sockets to it, and move all Orocsy logic into
plugs behind those sockets. Empty sockets = exact upstream behavior, which is
also the conformance test. Old fork commits are never merged or replayed; each
behavior is ported deliberately, protected by a characterization test.

Verdict: this is the right architecture for the stated goal. Every number in the
design verified exactly against git (229/31 divergence, merge-base 58cf97d,
orchestrator 5970/1990 lines, app-server 5595/1071, 21 same-path files, all 9
cited upstream commits, upstream v0.0.2). But the plan is incomplete in specific
ways: four sockets are really six roles (prompt/session composition and signed-
evidence notarization are unowned), "observer-only telemetry" is a behavior
change the doc misstates as an existing fact, one socket requires refactoring
upstream's hot read loop, there is no mechanism keeping the kernel patch small,
the replay gate presupposes tooling and traces that do not exist, and there is
no policy for fork `main` moving during the migration. None of this reverses
the direction; all of it must be fixed in the doc before implementation.

What the code confirms in the doc's favor: the orchestrator contains three
parallel review-gate implementations (orchestrator.ex:2000–2303, :1407–1998,
:1417–1530); load-bearing regexes over raw worker stdout park issues
(:4790–4817 → :673–717); Codex protocol failure strings drive delivery decisions
(:4168–4217); the dispatch predicate makes GitHub API calls mid-loop
(:2781–2860); contract errors surface as generic worker failures AFTER claim +
workspace creation, with the contract recompiled in ≥7 places. "Easy to add,
hard to compose" is demonstrably true, and admission-before-claim fixes a real
defect class.

## Findings

### [P1] Interface set is incomplete — prompt/session composition and evidence notarization are unowned (#upstream-ownership-matrix)

The 4 interfaces return decisions, verdicts, and records; nothing owns two
things the fork's governance depends on. (a) Prompt + session composition: fork
prompt_builder.ex is 1,735 lines vs upstream 64; app_server.ex additionally
injects ~120 lines of per-mode English policy plus per-mode skill/plugin disable
lists and sandbox config at thread start (app_server.ex:29–63, :447–549,
:551–683). These are session-scoped decisions, so per-command
CommandAuthorization cannot express them, and `next_prompt: PromptFragment.t()`
in RetryPlan understates the surface. Give RunPlan/TurnPlan explicit ownership
of full prompt + thread-config composition (a PromptComposer inside the Orocsy
extension). (b) Evidence notarization: certification baselines, MIU
certificates, handoff certificates, policy patches, and preflights are
HMAC-signed with a key outside the workspace (controller_evidence.ex:11,38–41),
verification fails closed, and a replay-attack guard exists
(validation_controller_test.exs:1710). A pure DeliveryPolicy cannot mint signed
evidence and a record-only Observer must not. Name the notary role explicitly
under the controller-evidence adapters and carry the fail-closed invariant into
the design. Also add DispatchPreflight (2,663 lines) to the ownership matrix
with a decomposition owner: today it is admission + policy-input + prompt-input
+ workspace mutation in one (it consumes policy patches, performs a real
`git checkout` at :360–380, signs and writes state) — it spans all four
interfaces and someone must own each shard.

### [P1] Telemetry is a live policy input today — observer-only is a behavior change to engineer, not an invariant to ratify (#controller-evidence-versus-telemetry)

orchestrator.ex:3544–3638 reads `.orocsy/delivery/token-telemetry/workers.jsonl`
and requires `summary["status"] == "blocked_no_durable_progress"` plus
`counted_guard_tokens` (:3357–3358) to decide park-vs-continue after a normal
worker exit. The older elixir/docs/token_usage_telemetry_design.md also wires
Analyzer→Corrections and Analyzer→Policy (its MIU 5 is a dispatch gate). So E15
("observer disabled → identical decisions") FAILS against faithfully-ported
current behavior. The doc must (a) enumerate these inputs and re-home them as
controller evidence (token/guard counters computed kernel-side from app-server
events into DeliverySnapshot fields), and (b) add a Supersedes section that
explicitly retires the analyzer→policy arrows in token_usage_telemetry_design.md
and the stale "do not merge PRs automatically" non-goal in
scope_unblock_runtime_design.md:972 — otherwise two normative documents coexist.

### [P1] The CommandAuthorization call site is a read-loop refactor, not an additive hook (#interface-3-commandauthorization)

Upstream's only approval decision point, approve_or_require/8 (upstream
app_server.ex:761/783), has no workspace, issue, or config in scope; its logic
is one auto-approve boolean. Wiring the interface means threading context
through ~7 private positional-arity functions in the hot receive loop (run_turn
→ await_turn_completion → receive_loop → handle_incoming → handle_turn_method →
maybe_handle_approval_request [7 clause heads] → approve_or_require) — the loop
upstream actively edits (3c372fa touched it, −165 lines). Even the no-op default
requires the signature churn. Two mitigations, use both: (a) capture an
immutable TurnContext once at start_session/start_turn so the hook needs only
payload + snapshot — the fork's own resolve_scope_access_violation (fork
app_server.ex:2393–2447) already returns {:allow, ...} | {:deny, ...} | :defer,
i.e. the proposed verdict shape has a proven core to port; (b) propose the
context-threading + approval-callback seam to upstream FIRST so the baseline
carries it (see next finding). Also widen the interface: the fork also
authorizes tracker tool calls — dynamic_tool.ex:94–137 blocks Linear issueUpdate
mutations carrying stateId during review_rework — so CommandIntent must cover
tool/GraphQL intents, not only shell commands. Do NOT port the 1,025-line scope
derivation engine (fork app_server.ex:692–1710: tsconfig alias resolution,
2-level import-graph walking, test↔source guessing) into the kernel client — it
belongs behind the extension.

### [P1] No concrete mechanism keeps the kernel patch small across upstream churn (#open-design-risks)

The doc's stability claim ("future upstream merges touch only stable call
sites") has no enforcement mechanism, and the seam audit says 3 of 4 call sites
have no natural upstream seam (only DeliveryObserver does — `on_message` at
upstream app_server.ex:87 already funnels all ~15 emissions through
emit_message/4; DispatchAdmission has a single choke point do_dispatch_issue/4
at orchestrator.ex:940 but no behaviour; DeliveryPolicy is a concept upstream
lacks entirely). Upstream is pre-1.0 (0.0.2, draft spec) with no stability
promises. Add: (a) a single facade module (e.g. SymphonyElixir.Extensions) so
each kernel file carries only 1-line greppable call sites; (b) an architecture
check that fails CI when kernel-file divergence from the pinned baseline exceeds
a small budget (this also guards against the drift pattern already observed
in-fork: ProgressController.decide/1 is pure and has ZERO callers — the
orchestrator reimplements it inline at :3921–3998); (c) an explicit attempt to
upstream the extension HOST (registry + hook points + no-op defaults). The
Non-Goals section currently rejects "upstreaming Orocsy's full delivery
workflow" — correct — but the generic host is a different, small, high-leverage
contribution, and upstream demonstrably accepts generic seams (they built the
tracker behaviour + 5 adapters, 7af5a76). If the host lands upstream, future
syncs become nearly free, which is the entire point of this migration.

### [P1] The replay gate presupposes tooling and traces that do not exist (#slice-8-replay-canary-and-cutover)

No trace-replay harness exists anywhere in the repo (the only "replay" test is a
replay-ATTACK guard, validation_controller_test.exs:1710). The only trace corpus
is ~45 MB of gitignored, local-only runtime logs (elixir/log/symphony.log.1–5,
spanning 2026-06-10→07-27; elixir/.gitignore:20 excludes /log/) — they disappear
on any fresh clone, and COD-276 exists only there. Move to Slice 0: (a) archive
the log corpus somewhere durable NOW, applying the privacy rules from
token_accounting.md / token_usage_telemetry_design.md (the logs contain full
Codex app-server payloads); (b) define the replay fixture format; (c) build the
harness skeleton. Otherwise the Slice 8 gate silently degrades to "canary only".

### [P1] Migration-window change management is unspecified while fork main is active (#migration-strategy)

Fork main landed 10 correctness PRs in July alone (#64–#73), the newest 3 days
before the doc's date. Every fork commit during slices 0–8 re-conflicts the 21
same-path files against the integration branch. State a policy: either freeze
fork main except hotfixes, or maintain a port-forward ledger (every fork commit
during the window classified port / skip / superseded-by-upstream, mirroring
the upstream-sync classification) with a defined re-merge cadence. Without this
the integration branch decays while it is being built.

### [P2] Provide the 4-interface ↔ 7-module mapping and mark prior docs superseded (#target-architecture)

workflows/symphony-runtime-delivery.md:534–546 ("Status: Implemented") already
normatively names 7 runtime modules: RuntimeContract.compile,
CommandIntent.classify, ScopeController.decide, ValidationController.evaluate,
ProgressController.evaluate, HandoffController.evaluate, Telemetry.record. The
doc redefines the seam set to 4 without a correspondence table. Add it
(Admission ⊇ RuntimeContract.compile; CommandAuthorization ⊇
CommandIntent.classify + ScopeController.decide; DeliveryPolicy ⊇
Validation/Progress/Handoff.evaluate + merge + rescue-replacement; Observer ⊇
Telemetry.record) and mark symphony-runtime-delivery.md superseded-in-part, so
exactly one document is normative for seams.

### [P2] DeliverySnapshot lacks controller-grade inputs, and merge must not trust any snapshot (#delivery-snapshot)

Fields the ported logic reads today that the proposed snapshot lacks: live
token/guard counters and provider rate limits (park guards at
orchestrator.ex:666–679, :3040–3048; also the only realistic wake source for
the failure table's "provider quota" row); the durable-progress quiet-time
clock (:802–830); delivery event-log queries (events.jsonl filtered by event
name/tool/timestamp in 4 modules); correction HISTORY with classifications
(loop limits at rescue_supervisor.ex:792–804 count resolved corrections); retry
fingerprints including the policy_hash recompute (:5448–5579); the certificate
ancestor chain (MIU statuses alone are insufficient —
handoff_controller.ex:127–199 verifies contiguity to HEAD); worker_host (~30
behavior branches today — remote SSH workers skip preflight and scope-access
entirely; decide whether extensions apply to SSH workers and add an E-scenario
for it); toolchain probe results (dispatch_preflight.ex:1654–1741). Separately:
merge_controller.ex:26–33 deliberately RE-FETCHES live GitHub state immediately
before merging — specify that snapshot.review is advisory and that
{:complete, ...} decisions carry evidence-freshness preconditions the kernel
re-verifies at execution time, else the snapshot model is a correctness
regression on the one irreversible action.

### [P2] Typed unblock rules must replace RescueSupervisor's FUNCTION, or the correction gate deadlocks (#delivery-state-machine)

"Replace with typed decisions; do not port wholesale" is the right call — the
current implementation decides staleness by substring-matching a hand-bumped
version tag ("runtime-preflight-worker-progress-contract-v19",
rescue_supervisor.ex:25) inside prose summaries it wrote earlier (bumping the
constant auto-resolves every parked correction), and free-text regex
classifiers (:1367–1384) drive tracker mutations. But RescueSupervisor is the
SOLE automatic unblocker: should_dispatch_issue? refuses any issue with an open
blocking correction (orchestrator.ex:2789, :5317–5397), so without a typed
replacement every parked issue deadlocks until a human edits JSON in
.orocsy/delivery/inbox/. The state machine needs: (a) typed Parked→Ready
unblock rule classes (policy-superseded, review-superseded,
progress-superseded, loop-exhausted→operator_required); (b) a named
operator-decision ingestion path (today: correction inbox JSON +
scope.access.decided events) as controller evidence — the current doc has no
operator input surface at all; (c) an event class for background reconcilers —
both RescueSupervisor.run_once and ReviewMonitor.run_once act on issues that
are neither admitted nor running, which the DeliveryEvent taxonomy cannot
express.

### [P2] Pure DeliveryPolicy needs an effectful ValidationRunner counterpart (#interface-2-deliverypolicy)

The policy is specified as deterministic and side-effect-free, but something
must actually execute the contract's declared validation commands —
validation_controller.ex:1481 opens a Port with a scrubbed environment (env
allow/deny regexes at :18–25). Name the execution adapter explicitly (kernel
invokes it when the policy returns a decision requiring validation; results
return as ValidationResult evidence), keep the env-scrubbing rules, and give it
a row in the ownership matrix.

### [P2] orocsy.py and .orocsy/delivery are unversioned cross-repo contracts (#governing-principles)

Workers signal lifecycle transitions by shelling out to
`.codex/delivery/bin/orocsy.py … event append --type miu.completion_requested`
— a Python CLI living in each TARGET repo, referenced from 8 prompt sites and
specially recognized by the command guard (fork app_server.ex:4231–4262). The
`.orocsy/delivery/*` layout is hardcoded across ≥7 runtime modules. Both are
load-bearing contracts the doc never mentions; version them explicitly (they
are also what replay fixtures and the canary comparison will diff), and state
whether the durable admission-record move to <runtime-state-root>/admission/
coexists with the workspace-local state layout.

### [P2 — RESOLVED by owner decision 2026-07-29] Worker backend is Codex-only; state it as an explicit non-goal (#non-goals)

Original finding: the doc was silent on whether the worker backend must stay
Codex. Today Codex is welded in at every layer — the only behaviour in either
tree is Tracker; protocol constants, config namespace (codex.*), orchestrator
state keys (codex_totals, codex_rate_limits), and message atoms
({:codex_worker_update, ...}) are all Codex-named, and Interface 3's own
definition says "inside the active Codex app-server turn". A WorkerRuntime
behaviour would have been a fifth extension point larger than the other four
combined.

**Decision (repository owner, 2026-07-29): Codex is the only supported worker
backend. No multi-worker compatibility layer, now or as a reserved seam.**

Required doc change: add to Non-Goals — "Supporting worker backends other than
the Codex app-server." Consequences, all of which simplify the plan and should
be stated rather than left implicit:

- No fifth interface. The extension set is exactly the four described (plus the
  prompt-composer and notary roles from the first P1 finding).
- Codex-specific naming in kernel state, config (`codex.*`), message atoms, and
  interface names is accepted deliberately, not by omission. Interface 3 keeping
  "Codex app-server turn" in its definition is correct.
- Codex protocol semantics may be treated as kernel semantics — turn/thread
  lifecycle, approval methods, token/rate-limit payload shapes — so the kernel
  is not obliged to abstract them behind neutral types.
- Reversal cost if this ever changes: a rename sweep across orchestrator state
  keys, config schema, message atoms, and the dashboard presenter, plus a new
  worker behaviour and a rewrite of the agent-runner turn loop. That is a real
  cost, accepted knowingly; it is not a hidden risk.

### [P3] Rejection dedupe keying and two migration landmines (#rejection-behavior)

(a) issue_revision is the full description SHA today, so any non-contract
description edit re-triggers admission evaluation and a new tracker comment;
key rejection dedupe on contract_hash (already present in Admission) with
issue_revision as tiebreaker. (b) Upstream 7af5a76 replaced the fork's
`assigned_to_worker` field with `dispatchable` — with the DEFAULT FLIPPED — and
Tracker.Issue.routable?/2 also requires required_labels; port naively and issue
eligibility silently inverts. Add a characterization test for eligibility
semantics before Slice 2. (c) Upstream SPEC §6.3 already uses the name
"Dispatch Preflight Validation" for scheduler-side config validation — a
different thing from the fork's 2,663-line DispatchPreflight (workspace
checkpoint writer). Rename the ported fork concept (e.g. CertificationBaseline)
before pinning the baseline to avoid two meanings of "preflight" in one
codebase.

## Nits (seen, intentionally not blocking)

An explicit no-op-differential E-scenario could be added (Slice 1 already
covers it); weekly sync cadence is fine; Burrito packaging / release-skill
upstream commits are correctly deprioritized.
