# OXE-1.1 Slice 1 Extension Host Technical Trace

Status: independent design review corrected; OXE-1.1 red checkpoint created

Date: 2026-08-13

Parent architecture:
`openai_upstream_orocsy_extension_architecture.md`, revision 2

Depends on:

- `OXE-0.1` pinned upstream-baseline verifier
- `OXE-0.1a` full-suite gate stabilization
- `OXE-0.2` independently reviewed kernel patch-budget audit
- pinned OpenAI commit `f8e8b8a670c799f6e0ade7a8c25c4bf4a4a56ec7`

## Decision

Build Slice 1 as four ordered MIUs. Start with a deep extension-host module
whose interface is four facade operations, a closed immutable registry, four
public adapter interfaces, and neutral no-op adapters. Do not change a pinned
kernel file in `OXE-1.1`.

The kernel hooks and their no-op differential proofs land only in the later
MIUs that own those exact registered paths. Orocsy behavior remains absent
throughout Slice 1.

One high-level interface correction is required before implementation. The
three decision interfaces need an explicit `:kernel_default` result. Without
it, a no-op adapter must either reimplement upstream scheduler/app-server
mechanics or silently choose a different result. `:kernel_default` means “the
extension made no decision; continue the already-existing OpenAI code path.” It
is legal only for generic/no-op adapters. Orocsy adapters must return a typed
decision or a typed failure.

## Observed Fixed Point

The following facts were re-checked in the integration worktree at `3eba1df`:

- `Orchestrator` refreshes the issue immediately before `do_dispatch_issue/4`,
  then selects a worker and mutates `running`, `claimed`, and retry state only
  after `Task.Supervisor.start_child/2` succeeds.
- `AgentRunner` creates the workspace, emits worker-runtime information, runs
  the repository `before_run` hook, and only then starts Codex turns.
- `Codex.AppServer` derives approval policy once per session, but its receive
  loop currently carries only the derived auto-approval Boolean through every
  recursive branch.
- App-server messages are assembled before the caller's `on_message` subscriber
  is invoked.
- `WorkflowStore` retains the decoded front-matter configuration map and parsed
  kernel settings. It does not retain the original document bytes. The current
  `Config.Schema` intentionally has no extension field and ignores the decoded
  extension stanza while preserving it in `Workflow.current/0`.
- `UPSTREAM_PATCH_BUDGET.yml` permits changes only in `orchestrator.ex`,
  `agent_runner.ex`, and `codex/app_server.ex`. Any change to application startup
  or `Config.Schema` would be an unregistered kernel patch.
- The `OXE-0.2` throwaway prototype proved the four hook locations within 40
  changed kernel lines and exposed the recursive immutable-turn-context hazard.

These observations rule out two tempting designs: changing application startup
to install a registry, and adding extension selectors to the kernel config
schema. Both would violate the already-reviewed patch authority.

## MIU Graph

| MIU | Owns | Kernel write scope | Mechanical proof |
| --- | --- | --- | --- |
| `OXE-1.1` | facade, registry, public interfaces, shared types, no-op adapters | none | interface tests and closed-registry tests |
| `OXE-1.2` | admission and workspace-ready delivery hooks | `orchestrator.ex`, `agent_runner.ex` | unchanged upstream core tests plus neutral-decision tests |
| `OXE-1.3` | immutable turn context, authorization hook, observer hook | `codex/app_server.ex` | unchanged app-server tests plus recursive-context differential |
| `OXE-1.4` | complete no-op conformance and manifest activation | manifest, audit fixtures, proof task, docs | all three registered files required; exact 40-line budget and full gate |

Dependencies are linear: `1.1 -> 1.2 -> 1.3 -> 1.4`. A later MIU may not
absorb an earlier failure by widening a kernel patch.

The private `DeliveryPolicy`, `DeliveryExecutor`, `PromptComposer`,
`ValidationRunner`, and `EvidenceNotary` roles remain documented contracts in
Slice 1. Empty behavior modules would be hypothetical seams with no real
adapter. Their code interfaces land with the first Orocsy delivery MIU, when
both production and in-memory test adapters exist.

## Deep Module And Seam

`SymphonyElixir.Extensions` is the only module imported by pinned kernel files.
Its interface is:

```elixir
@spec evaluate_admission(Issue.t(), AdmissionContext.t()) ::
        :kernel_default |
        {:admit, Admission.t()} |
        {:reject, Rejection.t()} |
        {:error, ExtensionFailure.t()}

@spec handle_delivery(DeliveryEvent.t(), DeliveryContext.t()) ::
        :kernel_default |
        {:ok, DeliveryDecision.t(), [DeliveryEvent.t()]} |
        {:error, ControllerFailure.t(), [DeliveryEvent.t()]}

@spec authorize(CommandIntent.t(), TurnContext.t()) ::
        :kernel_default |
        :allow |
        {:allow_once, AuthorizationLease.t()} |
        {:deny, AuthorizationDenial.t()} |
        {:error, ExtensionFailure.t()}

@spec record(DeliveryEvent.t()) :: :ok
```

The facade hides adapter lookup, registry-revision checks, exception capture,
observer fan-out, failure normalization, and no-op delegation. Kernel callers
learn none of those details.

Deletion test: deleting the facade would spread registry lookup, adapter
selection, exception/failure normalization, and observer isolation into three
pinned kernel files. The module therefore earns its seam.

Tests use the same four facade operations as kernel callers. They do not call
private routing functions or inspect registry storage.

## Registry Authority And Lifetime

`SymphonyElixir.ExtensionRegistry` is a pure, closed registry value:

```elixir
%SymphonyElixir.ExtensionRegistry{
  schema_version: 1,
  revision: "sha256:...",
  dispatch_admission: SymphonyElixir.Extensions.Noop.DispatchAdmission,
  delivery_controller: SymphonyElixir.Extensions.Noop.DeliveryController,
  command_authorization: SymphonyElixir.Extensions.Noop.CommandAuthorization,
  observers: [SymphonyElixir.Extensions.Noop.DeliveryObserver]
}
```

Configuration names map through a compile-time allowlist. YAML never becomes a
module name. Slice 1 accepts only `noop`; later slices add the known `orocsy`
name when its adapter exists.

The registry is resolved from the decoded `WORKFLOW.md` front-matter map on the
first admission facade call, before claim, workspace creation, or worker
launch. The single orchestrator authority makes that first call serialized.
The resolved value is stored by `ExtensionRegistry` as an immutable runtime
term and cannot be replaced without a BEAM restart. This avoids an unregistered
startup-file or kernel-schema edit while preserving the real invariant: no
extension adapter can change during an in-flight run.

The facade does not accept a registry, adapter module, or catalog argument.
Production adapter names are resolved through a build-time closed catalog; the
production catalog contains only `noop` in `OXE-1.1`. The test build may add
named fixture adapters through compile-time configuration. A test-build-only,
`@doc false` reset function erases the latch between non-async host tests. That
function is absent from production builds and cannot become runtime control
authority. Tests use it only for lifecycle isolation; they never read or
replace registry storage directly.

Workflow reload may change adapter options for future admissions and future
Codex sessions. Each accepted admission/session snapshots normalized options
and the registry revision. Changing an adapter selector after registry lock is
a typed `:extension_registry_restart_required` failure; it never hot-swaps a
module and never falls back to no-op.

Default raw configuration is equivalent to:

```yaml
extensions:
  dispatch_admission: noop
  delivery_controller: noop
  command_authorization: noop
  observers:
    - noop
  options: {}
```

Unknown keys, duplicate observers, non-list observers, unknown names, and
ill-typed options fail before adapter invocation. Secret-bearing extension
options are out of scope until an owning adapter defines their resolver.

## Public Adapter Interfaces

The four behavior modules are real seams because each is exercised by both its
neutral production adapter and an in-memory fixture adapter through the facade
in Slice 1. The later Orocsy adapters add the second production behavior
without changing the interface.

```elixir
defmodule SymphonyElixir.Extensions.DispatchAdmission do
  @callback evaluate(Issue.t(), AdmissionContext.t()) ::
              :kernel_default |
              {:admit, Admission.t()} |
              {:reject, Rejection.t()} |
              {:error, ExtensionFailure.t()}
end

defmodule SymphonyElixir.Extensions.DeliveryController do
  @callback handle(DeliveryEvent.t(), DeliveryContext.t()) ::
              :kernel_default |
              {:ok, DeliveryDecision.t(), [DeliveryEvent.t()]} |
              {:error, ControllerFailure.t(), [DeliveryEvent.t()]}
end

defmodule SymphonyElixir.Extensions.CommandAuthorization do
  @callback authorize(CommandIntent.t(), TurnContext.t()) ::
              :kernel_default |
              :allow |
              {:allow_once, AuthorizationLease.t()} |
              {:deny, AuthorizationDenial.t()} |
              {:error, ExtensionFailure.t()}
end

defmodule SymphonyElixir.Extensions.DeliveryObserver do
  @callback record(DeliveryEvent.t()) :: :ok | {:error, ObserverFailure.t()}
end
```

The shared structs use `@enforce_keys`, explicit `@type t`, stable enum atoms,
and no worker-authored authority Boolean. Contexts are immutable values. Their
first schema contains only facts needed by the owning Slice 1 hook. `OXE-1.1`
does not invent placeholder fields merely to fill the structs: the red tests
exercise the interface modules and facade with explicit fixture terms, while
`OXE-1.2` and `OXE-1.3` add the reviewed hook-specific context/event schemas
before their kernel call sites land. A later field requires a documented
interface revision rather than an untyped catch-all map.

## Neutral Adapters

The no-op adapters contain no policy:

- admission returns `:kernel_default`;
- delivery returns `:kernel_default`;
- authorization returns `:kernel_default`;
- observer returns `:ok`.

The kernel handles `:kernel_default` by continuing the exact pre-hook branch.
It must not translate it into an extension-owned admit, dispatch, approval, or
retry. This preserves OpenAI ownership of issue eligibility, worker selection,
workspace mechanics, auto-approval behavior, retries, and process outcomes.

No-op adapters do not read configuration, Git, files, processes, tracker state,
or telemetry. They are deterministic and allocation-bounded.

## Failure Semantics

| Failure | Kernel-visible result |
| --- | --- |
| invalid registry document | typed extension configuration failure; no claim or worker |
| selector changed after lock | restart-required failure; no module replacement |
| admission adapter error/raise/throw | fail closed before claim/workspace/model |
| delivery adapter error/raise/throw | preserve workspace and park; do not launch model |
| authorization adapter error/raise/throw | structured denial/error in the current turn; never auto-approve |
| one observer error/raise/timeout | operator-visible log; other observers continue; controller result unchanged |
| malformed adapter return | typed contract violation with adapter/interface/revision; no fallback |

Decision-adapter failure never becomes `:kernel_default`. Observer failure
never becomes a controller decision.

## Kernel Hook Ownership

`OXE-1.2` and `OXE-1.3` must reproduce the reviewed prototype patches, not
invent adjacent call sites.

1. Admission: after the final issue refresh and before worker selection, call
   `Extensions.evaluate_admission/2`. `:kernel_default` continues into the
   existing `do_dispatch_issue/4` path without touching scheduler maps.
2. Delivery: after workspace creation and before repository hook/model work,
   call `Extensions.handle_delivery/2`. `:kernel_default` continues the current
   `before_run` and Codex path.
3. Authorization: capture one `TurnContext` at turn start and carry that same
   immutable value through every recursive app-server receive-loop path. Call
   `Extensions.authorize/2` only for parsed approval/tool intents.
4. Observer: after an immutable app-server event is assembled and before the
   existing subscriber callback, call `Extensions.record/1`.

`OXE-1.2` changes `required` to `true` only for `orchestrator.ex` and
`agent_runner.ex`. `OXE-1.3` changes it for `codex/app_server.ex`. `OXE-1.4`
proves all registered patches present together. A fingerprint mismatch stops
the MIU and requires a new measured prototype plus architecture review; it is
not fixed by editing the manifest to match unreviewed code.

## No-Op Differential Proof

The proof has three independent layers:

1. Interface neutrality: every no-op decision facade returns
   `:kernel_default`; observer fan-out returns `:ok` and cannot influence the
   decision result.
2. Unchanged upstream characterization: the pinned upstream core and app-server
   test files remain byte-identical to `f8e8b8a` and pass unmodified against the
   hooked candidate. The existing 71-scenario prototype set is the minimum;
   full `make all` remains the landing gate.
3. Hook-specific differential: before each hook implementation, a red fixture
   records the reviewed pinned-baseline observation for that scenario. The
   hooked no-op candidate must produce the same canonical observation:
   dispatch/no-dispatch, prompt, approval response, retry/process outcome,
   subscriber event order, and emitted event type. Timestamps, PIDs, temp
   paths, and log formatting are excluded. No runtime disable switch is added.

The authorization fixture must emit at least two ordinary notifications before
an approval request and prove both that the same `TurnContext` identity reaches
the facade and that `:kernel_default` preserves the old auto-approve versus
approval-required result.

The observer fixture runs three cases: disabled, no-op, and raising observer.
All three must produce the same controller/authorization decision and existing
subscriber sequence. Only the raising case adds one sanitized operator log.

## Red-First Test Plan

### OXE-1.1 red tests

```text
ExtensionRegistryTest:
  defaults an absent stanza to the closed no-op registry
  rejects unknown keys, types, adapter names, and duplicate observers
  never converts configuration strings into module atoms
  locks adapter selection for the runtime lifetime
  accepts option changes only for a future admission/session snapshot
  rejects selector changes after lock as restart-required

ExtensionsHostTest:
  routes each facade operation to its registered adapter
  returns kernel_default through every no-op decision interface
  rejects malformed adapter returns
  normalizes adapter raise, throw, and exit without falling back
  isolates observer failure and continues observer fan-out
  exposes no Orocsy import from the facade, registry, interfaces, or no-op tree
```

The first red checkpoint contains tests, fixtures, and this trace only. It must
fail because the host modules do not exist.

### OXE-1.2 through OXE-1.4 red tests

- admission rejection occurs before claim, workspace, or `Task` creation;
- no-op admission and delivery match the pre-hook branch observations;
- recursive app-server notifications preserve one immutable turn context;
- no-op authorization preserves both auto-approve and approval-required cases;
- observer disabled/failed/no-op cases have identical decisions and subscriber
  ordering;
- `mix extensions.audit --only budget` fails until each owned manifest path is
  required and matches its reviewed fingerprint;
- direct imports from a pinned kernel file to any adapter fail;
- exact `make all` passes with the final no-op host enabled by default.

## OXE-1.1 Acceptance Conditions

1. No pinned-baseline kernel file changes.
2. The facade is the only public kernel-facing extension module.
3. Raw configuration selects only compile-time-known names and defaults to
   no-op without creating atoms.
4. Adapter selection is immutable after the first pre-claim admission call.
5. Each no-op decision returns `:kernel_default`; observer returns `:ok`.
6. Adapter failures are typed and cannot become neutral fallback decisions.
7. Observer failure has no control return path.
8. All public functions have `@spec`; all public adapter callbacks have explicit
   return unions.
9. `mix extensions.audit`, focused host tests, formatter, specs, strict Credo,
   `git diff --check`, and exact `make all` pass.
10. No Orocsy runtime implementation, private delivery-role module, kernel hook,
    or manifest `required` flip lands in this MIU.

## Alternatives Rejected

- Install the registry from `SymphonyElixir.Application`. That changes an
  unregistered pinned-kernel file and invalidates the measured budget.
- Add selectors to `Config.Schema`. That also creates unregistered kernel
  divergence; the generic host can own a strict decoder over raw workflow data.
- Resolve adapter modules on every call. Workflow reload could replace an
  in-flight implementation.
- Store arbitrary module names in YAML. It creates atoms and turns
  configuration into code loading.
- Make no-op adapters reimplement upstream decisions. That duplicates kernel
  authority and can drift silently.
- Omit `:kernel_default`. Admission, delivery, and authorization then have no
  honest neutral result.
- Add empty private delivery-role behavior modules now. With no Orocsy adapter,
  they are hypothetical seams and shallow test-only surface.
- Catch decision-adapter failure and continue upstream behavior. That converts
  uncertainty into permission.

## Strongest Surviving Attack

The runtime registry latch is global to one BEAM. Multiple independent
orchestrators with different workflow files in the same node would therefore
conflict. The current application exposes one named `WorkflowStore` and one
named scheduler authority, so multi-tenant registries are not a supported
runtime shape. A future multi-runtime node must make registry identity an
explicit supervisor dependency and remeasure the kernel patch budget; it must
not weaken the latch.

## Independent Review Disposition

The two-axis review against the parent architecture and current upstream code
found three design-document gaps and corrected them before the red checkpoint:

1. The parent still said the registry arrived at application startup, but the
   measured budget forbids that startup edit. Both documents now specify the
   serialized first pre-claim latch.
2. `WorkflowStore` retains a decoded front-matter map, not raw workflow bytes.
   Registry decoding now names the real input and does not claim duplicate-YAML
   evidence that the upstream loader has already discarded.
3. Fixture routing and a BEAM-lifetime latch need an explicit test boundary.
   The production facade remains four operations with no injection argument;
   only the test build gets a closed fixture catalog and reset helper.

No kernel path, runtime behavior, manifest requirement, or Orocsy adapter is
cleared by this review.

## Next Action

Review the `OXE-1.1` red checkpoint, whose scope is limited to
registry/facade/interface/no-op tests, the test-build fixture catalog, fixtures,
and these reviewed docs. Its focused 11-test command fails only because the
host modules do not exist. Once that checkpoint clears, implement the generic
host without touching a pinned kernel file.
