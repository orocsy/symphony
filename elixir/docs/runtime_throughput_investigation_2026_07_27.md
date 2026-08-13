# Runtime Throughput Investigation: COD-276

Date: 2026-07-27

## Decision

Do not redispatch COD-276 on Symphony `9a001b4`.

The latest failure is not one isolated command-policy miss. The runtime selected
the wrong lifecycle state, generated instructions that did not match the
workspace, and amplified each recoverable policy decision into another model
session. COD-276 also contains a contradictory read contract. The runtime and
ticket must both be corrected before the next dispatch.

## Observed Evidence

The retained COD-276 delivery workspace contains:

- 14 worker attempts from 2026-07-24T18:26:35Z through
  2026-07-25T18:30:24Z.
- 1,149,528 total model tokens:
  - 1,129,159 input tokens
  - 843,008 cached input tokens
  - 20,369 output tokens
  - 286,151 tokens counted by the progress guard
- 710 seconds of aggregate worker runtime across a 24-hour wall-clock window.
- 11 no-durable-progress attempts consuming 562,147 tokens.
- Two certified local MIU-1 commits:
  - `a40e520229e77822ff0646f0f548048792a876ba`
  - `685e4278500493f4a4faf9843e0388e207a791ce`
- No `tests/e2e/desktop-discover.spec.ts` file at `HEAD`.
- A clean worktree with no upstream tracking branch.
- One remaining MIU, COD-276-MIU-2.

Token concentration by phase:

| Phase | Tokens |
| --- | ---: |
| code read | 441,099 |
| reasoning | 330,027 |
| handoff | 327,514 |
| command | 50,888 |

The last three attempts each spent about 19,000 tokens recreating a worker
session before a bounded read or diff was denied.

## Root Causes

### 1. Lifecycle State Is Derived From Generic Git Risk Before MIU State

`PromptBuilder.workspace_recovery_checkpoint/1` treats clean local commits that
are not reachable from `origin/main` as local handoff risk. For structured
test-spec tickets, `DispatchPreflight.preflight_mode/3` then selects
`handoff_recovery` even when a certified MIU is followed by another remaining
MIU.

This produced the false instruction:

> Recover the existing dirty test-spec checkpoint

The workspace was clean. MIU 2 had never been created. The correct transition
was `certified_miu -> next_miu`, not `local_commit -> handoff_recovery`.

### 2. Recovery Instructions Assume Dirty Files That Do Not Exist

The structured recovery prompt requires a focused diff for each dirty file.
The generated first task then asks the worker to finish an expected-failure
marker and create another commit. There is no dirty-file list in this state,
and the remaining target file is absent.

The worker consequently attempted `sed`, `cat`, and `git diff` against a file
that should have been created as the next MIU.

### 3. Ticket Read Policy Contradicts Itself

COD-276 declares production files below `src/**` as required `read_context` and
also declares `src/**` in `denied_scope`. The controller gives denied scope
precedence, so the worker cannot legally inspect the implementation that the
test contract is intended to describe.

The two writable test targets are also absent from explicit `read_context`.
Write authority must imply read authority for the same path, including a
not-yet-created target.

### 4. Policy Recovery Can Restart the Entire Model Session

There are two policy-decision paths:

- `Codex.AppServer` can approve a bounded read in the active turn.
- `AgentRunner` can receive `{:forbidden_command, ...}`, write an `allow_once`
  patch, terminate the app-server session, and start a new worker turn.

The second path recreates the entire prompt and model context. It is not an
acceptable implementation of an approved read. A safe decision must continue
inside the same app-server turn. A denied decision must stop without a model
retry.

### 5. Tests Cover Components, Not The Failed Composition

Existing tests prove parser, controller, policy-patch, and selected same-session
cases separately. They do not replay this composition:

1. structured test-spec contract
2. one certified MIU
3. one remaining MIU whose target does not exist
4. clean local micro commits without upstream tracking
5. generated preflight and prompt
6. bounded target read/diff policy behavior

That missing composition allowed every narrow repair to pass while the real
dispatch still failed.

### 6. Monitoring Records Events But Does Not Summarize The Failure System

The monitor retained enough raw evidence to diagnose the incident, but the
dashboard did not directly show:

- cumulative attempts and tokens for one issue
- no-progress tokens
- time waiting between correction and redispatch
- the dominant blocker class across attempts
- the selected state transition and the facts used to select it
- repeated logical operations expressed with different shell commands
- whether an `allow_once` continued in-turn or restarted a worker

Monitoring remains observer-only. It must never mutate runner state or choose a
transition.

## Required Runtime Invariants

1. Structured contract state outranks generic git handoff heuristics.
2. If a certified MIU is followed by a remaining MIU and the worktree is clean,
   dispatch the remaining MIU on the same branch.
3. Local certified micro commits are expected between MIUs and do not imply
   final handoff.
4. Final handoff begins only after every declared MIU is certified.
5. A write-scope path is readable by the same MIU.
6. Contract compilation rejects overlapping allow-read and deny-read rules.
7. A missing target declared as creatable may receive one exact-path probe, but
   only after canonical containment proves that the missing path remains inside
   the workspace. Existing targets must also be regular files.
8. `allow_once` executes in the current app-server turn.
9. Policy denial never starts a fresh model session merely to try equivalent
   command syntax.
10. Runtime-generated instructions must be executable under the runtime's own
    policy.

## Regression Matrix

| ID | Starting state | Expected result |
| --- | --- | --- |
| R1 | clean branch, MIU 1 certified, MIU 2 remaining, local commits | `fresh_implementation` for MIU 2 |
| R2 | same as R1, MIU 2 target absent | prompt says create target; no dirty-diff instruction |
| R2a | current pending MIU already has a committed delta after its certification base | `handoff_recovery`; do not reimplement the MIU |
| R3 | all MIUs certified, clean local commits | final handoff gate |
| R4 | current MIU has a dirty declared target | focused recovery for that MIU |
| R5 | read context overlaps denied read scope | contract rejected before dispatch |
| R6 | MIU reads its own write target | allowed without scope patch |
| R7 | safe exact read needs dynamic context | approved and executed in the same app-server turn |
| R8 | unsafe/broad command | blocked once; no fresh model session |
| R9 | retry refresh becomes missing or stale | claim released or retry rescheduled |
| R10 | orchestrator runtime restarts | sibling worker processes terminate with it |
| R11 | issue has repeated attempts | aggregate summary reports tokens, elapsed stages, and dominant blocker |

## OpenAI Upstream Comparison

Compared refs:

- Orocsy main: `9a001b49bb7ea2a4b5854e506e88d33248cb6359`
- OpenAI main: `f8e8b8a670c799f6e0ade7a8c25c4bf4a4a56ec7`
- merge base: `58cf97da06d556c019ccea20c67f4f77da124bf3`

Divergence:

- Orocsy-only commits: 229
- OpenAI-only commits: 31
- direct merge changes both sides of 10 files, including `AgentRunner`,
  `Codex.AppServer`, config, and workflow surfaces.

Relevant upstream changes that are not fully present in Orocsy:

- `476b2b0`: supervise orchestrator and worker tasks as one restart unit.
- `0517275`: release or reschedule retry claims after dispatch-time refresh.
- `cbd2158`: clean failed new workspaces and anchor local roots to the workflow.
- `d476215`: validate workflow settings before scheduling.
- `3365695`: surface input-blocked sessions without retrying them.
- `3c372fa`: treat turn timeout as inactivity and reject generic input.

Do not cherry-pick these blindly into the modified 5,970-line Orocsy
orchestrator. Merge OpenAI main on an integration branch, resolve the ten
changed-both files with characterization tests, then keep Orocsy-specific
delivery controllers as explicit extensions.

## Delivery Sequence

1. Add R1-R8 before changing lifecycle or policy behavior.
2. Correct structured next-MIU dispatch and prompt selection.
3. Add semantic contract validation and write-implies-read behavior.
4. Remove model-session retry as the implementation of `allow_once`.
5. Add observer-only per-attempt and per-issue aggregate telemetry.
6. Integrate the relevant upstream runtime changes under R9-R10.
7. Rewrite COD-276 into two explicit remaining MIUs: harden the existing unit
   contract, then add the missing serial responsive E2E contract.
8. Compile the live issue and verify the generated preflight before starting a
   real worker.
9. Redispatch once. Stop after one abnormal attempt and compare it to R1-R11.

## Implemented Repair

Branch: `codex/systemic-runtime-throughput`

This branch implements the dispatch-blocking subset before COD-276 is
redispatched:

- `DispatchPreflight` now derives the next structured MIU from the authoritative
  Runtime Contract and valid runtime certificates. A clean branch with a
  pending MIU enters `fresh_implementation` only when that MIU has no committed
  delta after its certification base. A committed but uncertified delta remains
  in `handoff_recovery`, even when the branch is clean, tracks a pushed remote
  tip, and has no prior telemetry checkpoint. Its first task names the committed
  pending MIU and write target; it does not fabricate a dirty-file recovery
  instruction.
- `PromptBuilder` clears the generic local-handoff checkpoint for that same
  no-delta state, so certified micro commits do not hide the next MIU
  instructions and an uncertified microcommit is never discarded.
- `integration-check` contracts retain integration mode before generic pending
  MIU classification, and their final prompts omit implementation/MIU-commit
  guidance that would contradict the integration-check task.
- Pending-MIU commit classification is one immutable post-branch-sync snapshot
  binding MIU id/scope, certification base SHA, current HEAD, and concrete paths.
  It distinguishes no committed delta, an entirely in-scope committed delta, an
  invalid delta containing undeclared or explicitly denied paths, and unknown
  evidence. Invalid or unknown evidence fails closed instead of granting
  permission to restart, even when a live correction refreshes the prompt.
  Recovery prompts use a concrete in-scope committed path, including glob scopes.
  Every structured pending-MIU state precedes premature PR feedback. If committed
  recovery finds missing in-scope behavior, it creates one conditional follow-up
  micro commit before certification; a complete delta gets no empty or duplicate
  commit. Legacy review branch refresh remains best effort across temporary remote
  failures. The controller now classifies committed and worktree paths together:
  in-scope dirt must enter the follow-up commit, while out-of-scope dirt fails
  closed. Signed MIU boundary certificates are mirrored into controller-owned
  state outside the issue workspace, so recreation can restore completed MIUs and
  select the actual later pending MIU.
- Fresh preflight names the exact next MIU and its first write target.
- Contract compilation rejects MIU read or write scopes fully covered by
  `denied_scope`, before a worker starts. It returns validation errors for
  malformed non-list `mius` values and uses the same plain-directory descendant
  semantics as command enforcement.
- Handoff exact-read policy decisions, including the historical missing-target
  command shape, are resolved in the active app-server turn. Existing targets
  and missing targets are canonicalized before an allow-once decision, so a
  declared symlink cannot escape the workspace. Unsafe requests are denied
  there instead of being deferred into another model session.
- Token telemetry now writes
  `.orocsy/delivery/token-telemetry/issue-aggregate.json` after every turn. It
  includes attempts, consecutive no-progress count, token totals, dominant
  phase, dominant loop signature, last durable-progress time, and the latest
  worker summary. It remains observer-only.

Regression coverage:

- R1, R2, and R2a: clean multi-MIU progression, missing-target handling, and
  committed-but-uncertified recovery, including a stale prior preflight plus an
  explicit rewritten-contract certification base. The explicit migration base
  also precedes a remote issue-branch tip when no valid current-contract
  preflight exists, so a fresh clone cannot hide a pre-existing MIU delta.
- R3 and R4: retained structured final-handoff and dirty-MIU recovery tests.
- R5: new contradictory contract compiler test.
- R6: retained write-scope exact-read tests.
- R7 and R8: active-session handoff policy tests now cover both allow and deny.
- R11: new per-issue telemetry aggregate test.

R9 and R10 are intentionally separated into an upstream-integration branch.
They concern retry-claim refresh and process supervision, not the deterministic
COD-276 state/policy failure. Mixing those large orchestrator changes into this
repair would make the live-dispatch proof less attributable.
