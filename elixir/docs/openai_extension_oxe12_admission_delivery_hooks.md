# OXE-1.2 Admission And Workspace-Ready Delivery Hooks

Status: RED checkpoint verified; implementation absent

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
| `{:reject, _rejection}` | return the unchanged scheduler state |
| `{:error, _failure}` | log a sanitized failure and return unchanged state |

Rejection and failure must leave `running`, `claimed`, and `retry_attempts`
unchanged; create no task; select no worker; and create no workspace. Reporting
and persistence belong to the future Orocsy admission adapter, not the kernel.

The no-op differential observation is the existing worker task, claim, and
`before_run` marker for the same refreshed issue. The RED fixture rejection
observation is no task, no claim, and no workspace.

## Workspace-Ready Differential

The delivery hook is inserted after `Workspace.create_for_issue/2` succeeds
and after the existing runtime-info notification, but before
`Workspace.run_before_run_hook/3`. The event proves that the concrete workspace
exists and that no repository or model work has started.

| Facade result | Required kernel behavior in this MIU |
| --- | --- |
| `:kernel_default` | enter the exact existing `before_run` and Codex branch |
| `{:error, failure, events}` | preserve the workspace, skip `before_run` and Codex, surface a typed run failure |
| `{:ok, decision, events}` | preserve the workspace and surface the typed controller result without silently entering the kernel-default branch |

The generic kernel does not interpret Orocsy delivery policy, execute effect
plans, or turn an unknown decision into permission. A later Orocsy adapter may
complete its bounded internal controller loop before returning; any additional
kernel action requires its own reviewed interface revision and remeasurement.

The no-op differential observation is the same workspace path, runtime-info
message, `before_run` marker, and downstream outcome as the pre-hook branch.
The RED blocking-controller observation is an existing workspace with neither
the `before_run` marker nor a Codex session.

## RED Tests

The checkpoint adds test-only closed adapters and focused tests for:

1. admission input normalization and facade-owned revision/options enrichment;
2. workspace-ready event and delivery-context construction;
3. a refreshed issue rejected before worker selection, claim, task, or
   workspace creation;
4. no-op admission preserving the current task/claim/`before_run` observation;
5. delivery failure occurring after workspace creation but before
   `before_run` or Codex;
6. no-op delivery preserving the current workspace and `before_run` outcome;
7. fresh options snapshots across separate decision calls;
8. the budget manifest remaining unchanged and optional at RED; the first
   non-empty GREEN hook candidate must fail its stale fingerprint until the
   exact reviewed two-file patch is recorded and both owned paths become
   required.

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

It runs six tests with four expected failures:

1. admission receives the raw attempt instead of an `AdmissionContext`;
2. delivery receives the raw event atom and facts tuple instead of the typed
   event and context;
3. rejection is never evaluated, so no pre-claim fixture message exists;
4. workspace-ready delivery is never evaluated, so no pre-`before_run`
   fixture message exists.

The two independent no-op differentials pass at RED: admission still creates
the worker, claim, workspace, and blocking `before_run` marker; delivery still
creates the workspace and reaches the existing failing `before_run` hook. The
test build compiles, setup is local and network-free, and failures are therefore
localized to the missing facade enrichment and lifecycle hooks.

## Acceptance Conditions

1. RED fails because context enrichment and the two lifecycle hooks are absent,
   not because of syntax, setup, network, or nondeterministic timing.
2. Only the two owned kernel files may change in GREEN.
3. Kernel code references only `SymphonyElixir.Extensions`.
4. Options and registry revision never cross into a pinned kernel file.
5. Admission rejection creates no task, claim, or workspace.
6. Delivery failure preserves the workspace and starts neither `before_run`
   nor Codex.
7. No-op observations match the pre-hook baseline.
8. Focused tests, unchanged upstream tests, both audits, and exact `make all`
   pass before manifest promotion.
9. Independent Spec and Standards review clears the exact GREEN patch before
   either manifest entry becomes required.

## Next Action

Commit the test-only fixtures, RED lifecycle/context tests, and this trace.
Then implement the facade enrichment and
two hooks, remeasure their patches, and request architecture review before
editing `UPSTREAM_PATCH_BUDGET.yml`.
