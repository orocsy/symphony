# OXE-1.2 Admission And Workspace-Ready Delivery Hooks

Status: GREEN cleared at `943fbdd`; manifest activation deferred to OXE-1.4

Date: 2026-08-15

Parent traces:

- `openai_upstream_orocsy_extension_architecture.md`
- `openai_extension_oxe11_extension_host.md`
- `openai_extension_oxe11a_host_prototype_reconciliation.md`
- `openai_extension_oxe02_kernel_patch_budget.md`

## Decision

`OXE-1.2` owns exactly two lifecycle hooks:

1. admission after the final tracker refresh and before worker selection,
   claim mutation, task creation, or workspace creation;
2. workspace-ready delivery after successful workspace creation and before the
   repository `before_run` hook or Codex app-server launch.

Pinned kernel files import only `SymphonyElixir.Extensions`. They pass closed
lifecycle facts, not registry values, selectors, raw workflow configuration,
adapter modules, or extension options. The facade resolves the registry and
constructs the adapter-owned typed values.

This RED checkpoint does not land either hook, revise the patch manifest,
enable an Orocsy adapter, implement rejection reporting, or absorb command
authorization and observation.

## Kernel-Facing Facts

The facade retains its two public operation names while narrowing their
kernel inputs:

```elixir
@type attempt :: non_neg_integer() | nil
@type worker_host :: String.t() | nil
@type workspace_ready_facts ::
        {Issue.t(), Path.t(), worker_host(), attempt()}

@spec evaluate_admission(Issue.t(), attempt()) :: DispatchAdmission.result()
@spec handle_delivery(:workspace_ready, workspace_ready_facts()) ::
        DeliveryController.result()
```

The tuple is a closed product type whose position and validation live in the
facade. It is not an extensible policy map. A future lifecycle event requires
a new tagged input clause and interface revision; extra fields are not silently
accepted.

The attempt value follows the existing orchestrator convention: `nil`, zero,
or an invalid non-positive value normalizes to zero; a positive retry attempt
is preserved. Worker host is the one selected once by `AgentRunner`, not a
fresh scheduler lookup.

Inputs outside those closed shapes fail before registry lookup or adapter
invocation:

- malformed admission attempts return an `ExtensionFailure` with code
  `:invalid_kernel_input`, interface `:dispatch_admission`, and reason
  `:attempt_invalid`;
- an unknown delivery event, malformed facts, or a tuple with missing/extra
  fields returns `{:error, ControllerFailure.t(), []}` with code
  `:invalid_kernel_input`, interface `:delivery_controller`, and reason
  `:workspace_ready_facts_invalid`.

Those input failures have no adapter or registry revision because authority was
not resolved.

## Adapter-Owned Values

The adapter contracts receive concrete immutable structs:

```elixir
%SymphonyElixir.Extensions.AdmissionContext{
  attempt: non_neg_integer(),
  registry_revision: String.t(),
  options: map()
}

%SymphonyElixir.Extensions.DeliveryEvent{
  type: :workspace_ready
}

%SymphonyElixir.Extensions.DeliveryContext{
  issue: Issue.t(),
  workspace: Path.t(),
  worker_host: String.t() | nil,
  attempt: non_neg_integer(),
  registry_revision: String.t(),
  options: map()
}
```

All three structs use `@enforce_keys`, exact `@type t`, and no catch-all field.
The issue remains a separate argument to admission because the existing
adapter contract already owns that normalized tracker value. Delivery owns the
issue in its context because its callback's first argument is the lifecycle
event.

No timestamp is added to `:workspace_ready`: the call site's ordering is the
fact this MIU can prove, while wall-clock capture would add nondeterminism and
no current policy value.

## Options Snapshot Ownership

`ExtensionRegistry.lock/1` returns an immutable adapter selection plus a fresh,
validated options map. `Extensions` owns that pair and builds the context in
the same call that invokes the adapter:

```text
kernel facts
  -> Extensions
     -> Workflow.current
     -> ExtensionRegistry.lock
     -> typed event/context with revision + options snapshot
     -> selected adapter
```

The kernel never reads or transports options. Each decision invocation owns
one snapshot; admission and delivery do not share a mutable reference. A safe
workflow reload may therefore affect a later admission or a later session,
while the context observed by one adapter invocation cannot change beneath it.
Selector drift remains restart-required and fails before context construction.

The initial options schema is the validated extension options map already
owned by `OXE-1.1`. This MIU does not invent adapter-specific secret resolution
or promote worker-authored values into authority.

## Admission Differential

The hook is inserted only after `refresh_issue_for_dispatch/1` returns the
final `Issue` and before `do_dispatch_issue/4` selects a worker.

| Facade result | Required kernel behavior |
| --- | --- |
| `:kernel_default` | enter the exact existing `do_dispatch_issue/4` branch |
| `{:admit, _admission}` | enter that same dispatch branch |
| `{:reject, _rejection}` | do not dispatch; release any inherited retry claim |
| `{:error, _failure}` | log a sanitized failure; do not dispatch; release any inherited retry claim |

For a fresh dispatch, rejection and failure leave `running`, `claimed`, and
`retry_attempts` unchanged. A fired retry has already removed its retry entry
but still carries the previous worker's claim; rejection or failure must release
that inherited claim so the issue is not permanently hidden from polling. Both
paths create no task, perform no final worker selection, and create no
workspace. Reporting and persistence belong to the future Orocsy admission
adapter, not the kernel.
An adapter failure writes one sanitized operator log with fixed metadata
`extension admission failed code=<code> interface=<interface>`. It must not
include the issue title/description, adapter reason, options, or inspected
failure payload.

The RED test supplies different initial and refreshed issue values through a
stateful in-memory tracker stream. The fixture must receive the refreshed
value. A local-call trace observes the scheduler's existing capacity probe and
asserts that rejection/failure prevents the later worker-selection call. This
pins both sides of the admission location rather than inferring them only from
the absence of a task.

The no-op and explicit-admit differential observation is the existing second
worker-selection call, worker task, claim, workspace, and `before_run` marker.
The RED rejection/failure observation is one capacity probe, no worker
selection, no task, no claim, and no workspace.

## Workspace-Ready Differential

The delivery hook is inserted after `Workspace.create_for_issue/2` succeeds
and after the existing runtime-info notification, but before
`Workspace.run_before_run_hook/3`. The event proves that the concrete workspace
exists and that no repository or model work has started.

| Facade result | Required kernel behavior in this MIU |
| --- | --- |
| `:kernel_default` | enter the exact existing `before_run` and Codex branch |
| `{:error, failure, events}` | return `{:error, {:extension_delivery_failed, failure, events}}` from the worker-host run, so existing `AgentRunner.run/3` raises its normal `RuntimeError` with that tagged reason |
| `{:ok, decision, events}` | return `{:error, {:extension_delivery_decision, decision, events}}` from the worker-host run, so existing `AgentRunner.run/3` raises its normal `RuntimeError` with that tagged reason |

The generic kernel does not interpret Orocsy delivery policy, execute effect
plans, or turn an unknown decision into permission. A later Orocsy adapter may
complete its bounded internal controller loop before returning; any additional
kernel action requires its own reviewed interface revision and remeasurement.

The no-op differential observation is the same workspace path, runtime-info
message, `before_run` marker, and downstream outcome as the pre-hook branch.
The RED blocking-controller observation is an existing workspace with neither
the `before_run` marker nor a Codex session.

The test sends runtime information and fixture observations to the same parent
process. It consumes messages without selective receive: runtime information
must be first, and the delivery fixture must be second. This pins the hook
after runtime notification. Absence of the `before_run` marker pins its other
side. The final assertion compares the complete deterministic `RuntimeError`
message, including the exact tagged reason tuple, so an extra or reordered
wrapper cannot pass by substring.

## RED Tests

The checkpoint adds test-only closed adapters and eleven focused tests for:

1. admission input normalization and facade-owned revision/options enrichment;
2. workspace-ready event and delivery-context construction;
3. a refreshed issue rejected before worker selection, claim, task, or
   workspace creation;
4. admission adapter failure preserving the same fail-closed boundary;
5. no-op and explicit admission preserving the current
   selection/task/claim/`before_run` observation;
6. delivery failure occurring after runtime information and workspace creation
   but before `before_run` or Codex;
7. a controller decision producing an exact tagged outer failure rather than
   permission or `CaseClauseError`;
8. no-op delivery preserving the current runtime-info, workspace, and
   `before_run` outcome;
9. same-registry option reload, nil/zero/negative attempt normalization, nil
   host, and a table of unknown tags, missing/extra tuple fields, maps, invalid
   issue/path/host/attempt values, and typed pre-registry rejection;
10. the budget manifest remaining unchanged and optional at RED; the first
    non-empty GREEN hook candidate must fail its stale fingerprint until the
    exact reviewed two-file patch is recorded and both owned paths become
    required.
11. retry rejection and failure both release the inherited claim while creating
    no running worker or replacement retry entry.

The test adapters are available only in `MIX_ENV=test`. They communicate with
one registered non-async test process and derive their deterministic result
from the facade-provided options snapshot. Production remains closed to
`noop`.

## Manifest Boundary

The current admission and delivery fingerprints remain stale evidence and must
continue to fail against a new hook candidate. `OXE-1.2` changes neither hash
nor `required` flag in its RED checkpoint.

After GREEN, remeasure exact baseline-to-worktree patches for only:

- `elixir/lib/symphony_elixir/orchestrator.ex`;
- `elixir/lib/symphony_elixir/agent_runner.ex`.

If the compatible implementation exceeds either historical 7/8-line ceiling,
record the measured replacement rather than hiding work or adding contingency.
The two replacements require architecture review before the manifest becomes
authority.

## RED Evidence

The focused command is:

```bash
mix test test/symphony_elixir/extensions_admission_delivery_red_test.exs --seed 0
```

It runs ten tests with eight expected failures:

1. admission receives the raw attempt instead of an `AdmissionContext`;
2. delivery receives the raw event atom and facts tuple instead of the typed
   event and context;
3. malformed admission facts are delegated instead of producing the typed
   pre-registry input failure;
4. rejection is never evaluated after refresh/before worker selection;
5. admission failure is never evaluated at that same boundary;
6. explicit admission is never evaluated before the current dispatch branch;
7. workspace-ready controller failure is never evaluated after runtime info;
8. a workspace-ready controller decision is never evaluated there either.

The two independent no-op differentials pass at RED: admission still creates
the worker, claim, workspace, and blocking `before_run` marker; delivery emits
runtime info, creates the workspace, and reaches the existing failing
`before_run` hook. The test build compiles, setup is local and network-free,
and failures are therefore localized to the missing facade enrichment, input
validation, and lifecycle hooks.

Final independent Spec review at `e3b7844` reproduced the ten-test/eight-failure
differential and found no surviving requirement gap. It verified the refreshed
issue and exact placement evidence, all facade result branches, closed-input
matrix, option reload, attempt normalization, runtime-info ordering, and exact
delivery wrappers. The last review repair gives the admission fixture distinct
secret-bearing title, description, options, and adapter reason values; the RED
assertion permits exactly one fixed-metadata failure log line and excludes
those values plus inspected failure, adapter, and registry metadata. Final
Standards review found no scope, teardown, trace, mailbox-ordering, or
determinism issue. The committed RED checkpoint is cleared for GREEN.

## GREEN Candidate Evidence

The first compatible GREEN candidate implements the facade-owned context/event
construction and both reviewed lifecycle hooks. It also replaces the old host
tests' caller-authored admission/delivery context escape hatch with option-driven
test adapters, so the test suite exercises the narrowed kernel facts rather than
preserving the discarded API.

Local evidence before independent review:

- the cleared ten-test RED contract plus the retry-claim review regression pass
  eleven tests with zero failures at seed zero;
- the combined lifecycle, host, and registry suite passes 32 tests with zero
  failures at seeds zero and one;
- the unchanged core and orchestrator-status suites pass 95 tests;
- the complete test suite passes 374 tests with zero failures and six skips;
- exact `make all` passes those 374 tests with 100% total coverage, formatting,
  public-spec coverage, strict Credo, and Dialyzer all clean;
- baseline identity audit passes; budget audit fails closed only on the
  intentionally stale file/hook fingerprints for the two owned paths and their
  per-file ceilings.

The exact baseline-to-candidate patches measure 24 changed lines in
`orchestrator.ex` and 15 in `agent_runner.ex`, 39 total. That stays below the
reviewed aggregate ceiling of 40 while honestly exceeding the obsolete
prototype ceilings of 7 and 8. The manifest remains unchanged until independent
architecture review clears those exact replacements.

First-round Standards review found that a fired retry had already popped its
retry entry but retained its old claim, so returning an unchanged state on
reject/error would strand the issue outside both polling and retry. Spec review
required the correction to be an explicit contract revision and rejected a
test that entered below the real retry-pop boundary. The rework releases only
that inherited claim and drives both reject/error cases through the production
`handle_info({:retry_issue, issue_id, retry_token}, state)` ingress with a real
token and retry entry. Fresh-dispatch state behavior remains unchanged. The
generic host test adapters now also declare their narrowed behaviors and
implementations for compile-time drift checking.

Final Spec re-review found no actionable issue. It independently verified both
production retry-token cases, fresh-dispatch equivalence, the 11-test lifecycle
and 32-test combined suites, the baseline audit, and the unchanged 24/15-line
measurement. Final Standards re-review also found no issue in claim cleanup,
fixture behavior conformance, deterministic option reload, or scope. The exact
GREEN candidate is cleared at `943fbdd`; the stale manifest remains a deliberate
fail-closed handoff rather than an OXE-1.2 defect.

## Acceptance Conditions

1. RED fails because context enrichment and the two lifecycle hooks are absent,
   not because of syntax, setup, network, or nondeterministic timing.
2. Only the two owned kernel files may change in GREEN.
3. Kernel code references only `SymphonyElixir.Extensions`.
4. Options and registry revision never cross into a pinned kernel file.
5. Admission reject/error creates no final worker selection, task, or workspace;
   fresh dispatch creates no claim and retry dispatch releases its inherited
   claim; admit/default preserves the dispatch branch.
6. Delivery failure and non-default decision preserve the workspace, use exact
   tagged outer failures, and start neither `before_run` nor Codex.
7. Same-selector reload reaches a new options snapshot with one registry
   revision; malformed closed inputs fail before registry lookup.
8. No-op observations match the pre-hook baseline, including runtime-info
   ordering.
9. Focused tests, unchanged upstream tests, baseline audit, and exact `make all`
   pass in OXE-1.2; budget audit rejects the stale manifest until OXE-1.4 applies
   the independently reviewed replacements atomically.
10. Independent Spec and Standards review clears the exact GREEN patch before
   either manifest entry becomes required.

## Next Action

Begin the `OXE-1.3` context/differential RED design from cleared checkpoint
`943fbdd`. Carry the reviewed 24/15-line measurements forward as evidence for
the later OXE-1.4 manifest-owning checkpoint; do not activate either path
piecemeal.
