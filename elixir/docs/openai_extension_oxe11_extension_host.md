# OXE-1.1 Slice 1 Extension Host Technical Trace

Status: OXE-1.1/1.1a/1.2 cleared; OXE-1.3 GREEN gate passed, independent review pending; OXE-1.3a observer RED recorded, review pending

Date: 2026-08-13

Last revised: 2026-08-16

Parent architecture:
`openai_upstream_orocsy_extension_architecture.md`, revision 2

Depends on:

- `OXE-0.1` pinned upstream-baseline verifier
- `OXE-0.1a` full-suite gate stabilization
- `OXE-0.2` independently reviewed kernel patch-budget audit
- pinned OpenAI commit `f8e8b8a670c799f6e0ade7a8c25c4bf4a4a56ec7`

## Decision

At the OXE-1.1 fixed point, build Slice 1 from a deep extension-host module
whose interface is four facade operations, a closed immutable registry, four
public adapter interfaces, and neutral no-op adapters. Do not change a pinned
kernel file in `OXE-1.1`. OXE-1.3 later adds four public kernel lifecycle and
protocol-bridge function/arities—`capture_turn/1`, `capture_turn/3`,
`bind_turn/2`, and `handle_turn_authorization/3`—without adding a fifth adapter
interface. These make eight public facade function/arities under seven operation
names over the same four adapter interfaces.

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

A post-implementation compatibility review found that the older `OXE-0.2`
prototype fingerprints call a discarded facade contract and therefore cannot
be activated with this host. The evidence and corrective boundary are recorded
in
[`openai_extension_oxe11a_host_prototype_reconciliation.md`](openai_extension_oxe11a_host_prototype_reconciliation.md).

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
| `OXE-1.1` | facade, registry, public interfaces, shared failure types, no-op adapters | none | interface tests and closed-registry tests |
| `OXE-1.2` | admission and workspace-ready delivery hooks | `orchestrator.ex`, `agent_runner.ex` | unchanged upstream core tests plus neutral-decision tests |
| `OXE-1.3` | immutable turn context and authorization hook | `codex/app_server.ex` | unchanged app-server tests plus recursive-context differential |
| `OXE-1.3a` (internal review subcheckpoint) | bounded observer dispatcher, versioned envelope, app-server observer hook | `codex/app_server.ex` plus extension-owned dispatcher/envelope | full/hung/failing queue differential plus identical subscriber sequence |
| `OXE-1.4` | complete no-op conformance and manifest activation | manifest, audit fixtures, proof task, docs | all three registered files required; reviewed replacement budget and full gate |

The four top-level dependencies remain `1.1 -> 1.2 -> 1.3 -> 1.4`.
Top-level OXE-1.3 has two ordered internal review gates: authorization `1.3`
then observer `1.3a`. The split was required because a synchronous observer
callback violates the parent architecture's bounded-asynchronous/non-blocking
contract. A later MIU may not absorb an earlier failure by widening a kernel
patch.

The private `DeliveryPolicy`, `DeliveryExecutor`, `PromptComposer`,
`ValidationRunner`, and `EvidenceNotary` roles remain documented contracts in
Slice 1. Empty behavior modules would be hypothetical seams with no real
adapter. Their code interfaces land with the first Orocsy delivery MIU, when
both production and in-memory test adapters exist.

## Deep Module And Seam

`SymphonyElixir.Extensions` is the only module imported by pinned kernel files.
The hook-owning MIUs narrow its kernel-facing inputs to closed lifecycle facts;
the facade then constructs the typed adapter contexts. After `OXE-1.2`, its
admission and delivery surface is:

```elixir
@type attempt :: non_neg_integer() | nil
@type workspace_ready_facts ::
        {Issue.t(), Path.t(), String.t() | nil, attempt()}

@spec evaluate_admission(Issue.t(), attempt()) ::
        :kernel_default |
        {:admit, Admission.t()} |
        {:reject, Rejection.t()} |
        {:error, ExtensionFailure.t()}

@spec handle_delivery(:workspace_ready, workspace_ready_facts()) ::
        :kernel_default |
        {:ok, DeliveryDecision.t(), [DeliveryEvent.t()]} |
        {:error, ControllerFailure.t(), [DeliveryEvent.t()]}

@spec capture_turn({Issue.t(), Path.t(), String.t() | nil, String.t()}) ::
        {:ok, TurnSeed.t()} | {:error, ExtensionFailure.t()}

@spec bind_turn(TurnSeed.t(), String.t()) ::
        {:ok, TurnContext.t()} | {:error, ExtensionFailure.t()}

@spec capture_turn(turn_facts(), (-> term()), (-> :ok)) ::
        {:ok, String.t(), TurnContext.t()} | {:error, term()}

@spec authorize({String.t(), map()}, TurnContext.t()) ::
        :kernel_default |
        :allow |
        {:allow_once, AuthorizationLease.t()} |
        {:deny, AuthorizationDenial.t()} |
        {:error, ExtensionFailure.t()}

@spec handle_turn_authorization(
        app_server_authorization_facts(), TurnContext.t(), function()
      ) :: AppServerAuthorization.result()

@spec record(ObserverEnvelope.t()) :: :ok
```

The facade hides protocol-to-`CommandIntent` parsing, adapter lookup,
registry-revision checks, exception capture,
observer fan-out, failure normalization, typed context construction, the fresh
options snapshot, and no-op delegation. Kernel callers learn none of those
details. The exact `OXE-1.2` context fields and tuple order are fixed in
`openai_extension_oxe12_admission_delivery_hooks.md`. OXE-1.3's four added
facade function/arities capture immutable authority, bind the server-returned
turn id, compose start/bind failure disposition, and map authorization results
onto the pinned protocol; none adds an adapter callback. The existing observer input remains the
closed workspace-ready `DeliveryEvent`; the internal OXE-1.3a review
subcheckpoint must revise that surface to its versioned envelope before adding
the app-server observer hook.

Deletion test: deleting the facade would spread registry lookup, adapter
selection, exception/failure normalization, and observer isolation into three
pinned kernel files. The module therefore earns its seam.

Tests use the same public facade functions as kernel callers. OXE-1.1 tests use
the original four; OXE-1.3 adds the four lifecycle/protocol-bridge arities named
above. They do not call private routing functions or inspect registry storage.
Deleting those bridges forces the pinned client to resolve registry/options
authority, construct adapter-visible context, normalize lifecycle failures, or
duplicate protocol mapping, so they earn the public facade seam.

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
first decision-facade call. The normal production path makes that call through
admission before claim, workspace creation, or worker launch. Delivery and
authorization may resolve the same closed configuration when pinned upstream
modules are exercised directly; they do not depend on an orchestrator call
having happened earlier. The resolved value is stored by `ExtensionRegistry`
as an immutable runtime term and cannot be replaced without a BEAM restart.
This avoids an unregistered startup-file or kernel-schema edit while preserving
the real invariant: no extension adapter can change during an in-flight run.

The facade does not accept a registry, adapter module, or catalog argument.
Production adapter names are resolved through a build-time closed catalog; the
production catalog contains only `noop` in `OXE-1.1`. The test build may add
named fixture adapters through compile-time configuration. A test-build-only,
`@doc false` reset function erases the latch between non-async host tests. That
function is absent from production builds and cannot become runtime control
authority. Tests use it only for lifecycle isolation; they never read or
replace registry storage directly.

Workflow reload may change adapter options for future admissions and future
Codex sessions. `OXE-1.1` validates a fresh options snapshot during each
registry lock while keeping adapter selection immutable. The generic facade
does not expose raw options or registry lookup to kernel callers. `OXE-1.2` and
`OXE-1.3` must define their concrete context types and enrich adapter contexts
behind the facade with that snapshot and registry revision. Changing an
adapter selector after registry lock is a typed
`:extension_registry_restart_required` failure; it never hot-swaps a module
and never falls back to no-op.

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

The target signatures below name the hook-owned structs. `OXE-1.1` implements
the same callback names and return shapes, but deliberately leaves hook-owned
input and decision payload positions as `term()` until `OXE-1.2` and `OXE-1.3`
can derive their fields from the reviewed kernel call sites. The three failure
structs are concrete now. This is type refinement across MIUs, not permission
to pass an open policy map through the eventual kernel seam.

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
  @callback record(ObserverEnvelope.t()) :: :ok | {:error, ObserverFailure.t()}
end
```

The shared structs use `@enforce_keys`, explicit `@type t`, stable enum atoms,
and no worker-authored authority Boolean. Contexts are immutable values. Their
first schema contains only facts needed by the owning Slice 1 hook. `OXE-1.1`
does not invent placeholder fields merely to fill the structs: the red tests
exercise the interface modules and facade with explicit fixture terms, while
`OXE-1.2`, `OXE-1.3`, and its internal `OXE-1.3a` subcheckpoint add their
reviewed hook-specific context/intent/envelope schemas before their kernel call
sites land. A later field requires a documented
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
| one observer error/raise/throw/exit | operator-visible log; other observers continue; controller result unchanged |
| malformed adapter return | typed contract violation with adapter/interface/revision; no fallback |

Decision-adapter failure never becomes `:kernel_default`. Observer failure
never becomes a controller decision.

`OXE-1.1` does not claim timeout containment: neither the fixed-point host nor
its tests define an observer process boundary or timeout budget. Independent
OXE-1.3 design review rejected a synchronous app-server observer hook. OXE-1.3a
must define and test a bounded asynchronous handoff, queue saturation, hung
callback containment, sanitized loss signal, and shutdown/drain semantics
before the observer hook lands. Inventing only a callback duration would not
satisfy the non-blocking architecture.

## Kernel Hook Ownership

`OXE-1.2`, `OXE-1.3`, and its internal `OXE-1.3a` subcheckpoint must use the
reviewed lifecycle call sites, not invent adjacent seams. They may not reproduce
the current manifest fingerprints:
`OXE-1.1a` proved those patches call an obsolete facade and do not compile
against this host. Each owning MIU must create its context/differential RED
tests, remeasure the exact compatible patch, and receive architecture review
before revising its manifest entries.

1. Admission: after the final issue refresh and before worker selection, call
   `Extensions.evaluate_admission/2`. `:kernel_default` continues into the
   existing `do_dispatch_issue/4` path without touching scheduler maps.
2. Delivery: after workspace creation and before repository hook/model work,
   call `Extensions.handle_delivery/2`. `:kernel_default` continues the current
   `before_run` and Codex path.
3. Authorization: call `Extensions.capture_turn/3` around `turn/start`, carry
   its immutable `TurnContext` through every recursive app-server receive-loop
   path, and call `Extensions.handle_turn_authorization/3` only for targeted
   approval/tool methods. The bridge parses and authorizes through
   `Extensions.authorize/2`; a no-op decision invokes the exact pinned fallback.
4. Observer (internal `OXE-1.3a` only): after an immutable app-server event is assembled,
   submit its versioned envelope to a bounded asynchronous dispatcher before
   the existing subscriber callback. Full, hung, or failed observer work must
   not block or alter the subscriber.

`OXE-1.2`, `OXE-1.3`, and the internal `OXE-1.3a` subcheckpoint record
independently reviewed replacement measurements without changing manifest
authority piecemeal. `OXE-1.4` atomically revises the
three registered fingerprints/ceilings, makes all three paths required, and
proves them present together. A fingerprint mismatch stops the MIU and requires
a new measured candidate plus architecture review; it is not fixed by editing
the manifest to match unreviewed code.

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

The OXE-1.3a observer fixture runs disabled, no-op, full-queue, hung, raising,
throwing, and exiting cases. All must produce the same
controller/authorization decision and existing subscriber sequence. Failure or
loss adds only the documented sanitized operator evidence.

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
- OXE-1.3a observer disabled/full/hung/failed/no-op cases have identical
  decisions and subscriber ordering;
- `mix extensions.audit --only budget` fails until each owned manifest path is
  required and matches its reviewed fingerprint;
- direct imports from a pinned kernel file to any adapter fail;
- exact `make all` passes with the final no-op host enabled by default.

## OXE-1.1 Acceptance Conditions

1. No pinned-baseline kernel file changes.
2. The facade is the only public kernel-facing extension module.
3. Raw configuration selects only compile-time-known names and defaults to
   no-op without creating atoms.
4. The first decision-facade call atomically publishes one adapter selection,
   which is immutable until BEAM restart. The normal production sequence still
   reaches pre-claim admission first.
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
  divergence; the generic host can own a strict decoder over the decoded
  workflow front-matter map.
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

## OXE-1.1 Implementation Evidence

The reviewed RED checkpoint is `45335b7`. Its focused command ran 11 tests and
all 11 failed only because `SymphonyElixir.ExtensionRegistry`,
`SymphonyElixir.Extensions`, the four behavior modules, and no-op adapters did
not exist.

The implementation then added only the generic host tree and test/build
support:

- `ExtensionRegistry.resolve/1` strictly decodes the closed catalog without
  creating atoms, and `lock/1` atomically latches only adapter selection while
  returning a new validated options snapshot for each future admission; the
  owning hook MIUs remain responsible for carrying that snapshot into their
  concrete contexts;
- any decision facade may establish the same validated immutable latch; the
  production orchestrator still reaches admission first, while direct pinned
  upstream delivery/authorization entry points no longer fail because of a
  lifecycle-order artifact;
- the facade normalizes raise, throw, exit, malformed returns, and typed adapter
  failures, stamping the selected adapter and registry revision itself;
- production contains only the four `noop` selectors. Fixture selectors and
  `reset_for_test/0` are compile-time test-only; a production-mode compilation
  independently proved the reset function is not exported;
- the first GREEN run exposed an Elixir-specific guard error (`nil` satisfies
  `is_atom/1`). The closed-catalog regression now rejects that case instead of
  constructing a registry containing `nil`.

Observed validation on 2026-08-13:

| Proof | Result |
| --- | --- |
| Focused registry/facade suite | 17 tests, 0 failures |
| Existing extension/audit suite before GREEN | 51 tests, 0 failures |
| Full exact `make all` | passed |
| Full suite under coverage | 359 tests, 0 failures, 6 skipped |
| Coverage | 100.00% total, including registry and facade |
| Strict Credo | no issues |
| Dialyzer | 0 errors |
| `mix specs.check` | all public functions covered |
| Baseline and budget audits | pass; 0 changed kernel files, 0 changed kernel lines |
| Production test-reset probe | `production_reset_exported: false` |
| Pinned kernel files | unchanged from `f8e8b8a` |

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
   measured budget forbids that startup edit. Both documents now specify an
   atomic first-decision latch, with pre-claim admission first in the normal
   production sequence.
2. `WorkflowStore` retains a decoded front-matter map, not raw workflow bytes.
   Registry decoding now names the real input and does not claim duplicate-YAML
   evidence that the upstream loader has already discarded.
3. Fixture routing and a BEAM-lifetime latch need an explicit test boundary.
   The OXE-1.1 production facade remains four operations with no injection
   argument; only the test build gets a closed fixture catalog and reset
   helper. OXE-1.3 later adds the separately documented four kernel lifecycle
   and protocol-bridge function/arities without changing the four adapter
   interfaces.

That design review did not by itself clear a kernel path, manifest requirement,
or Orocsy adapter.

The subsequent implementation review found a fourth, load-bearing gap: the
recorded `OXE-0.2` admission and delivery patches pass the budget audit but
call facade functions that do not exist in the production host. Reproducing
those exact patches made compilation fail. The same review showed that direct
upstream `AgentRunner` and app-server tests do not necessarily enter through
admission first. `OXE-1.1a` therefore makes every decision facade capable of
resolving the same closed registry, records the stale-fingerprint evidence, and
keeps the manifest unchanged until a new exact prototype is independently
reviewed.

The first independent Spec review found that broadening the first entry point
also exposed a pre-existing non-atomic check/write in `ExtensionRegistry.lock/1`:
two concurrent valid configurations could both return success and the later
write could replace the earlier selection. The rework serializes publication
on the local BEAM and adds a synchronized concurrent-first-lock regression.
Direct delivery and authorization coverage now also includes targeted unknown
selectors, malformed options, and restart-required selector drift. Standards
review reported no finding. The exact post-rework `make all` gate passes 363
tests with zero failures and six skipped, 100% total coverage, strict Credo
with no issues, and Dialyzer with zero errors. Final Spec re-review repeated
100 synchronized races with exactly one published revision per round; final
Standards re-review reported no finding. `OXE-1.1a` is cleared at `0ea6f5f`.

## Next Action

The `OXE-1.2` RED checkpoint is recorded in
[`openai_extension_oxe12_admission_delivery_hooks.md`](openai_extension_oxe12_admission_delivery_hooks.md).
Its GREEN candidate now implements facade enrichment and both lifecycle hooks
without absorbing authorization, observer dispatch, Orocsy policy, or
manifest-finalization scope. Final review clears its measured 24-line admission
and 15-line delivery patches at `943fbdd`. Begin OXE-1.3's immutable turn
context and authorization RED design; OXE-1.3a owns observation, and the later
manifest-owning checkpoint will activate all reviewed paths together.

The OXE-1.3 contract is recorded in
[`openai_extension_oxe13_turn_authorization.md`](openai_extension_oxe13_turn_authorization.md).
It owns one facade-captured turn snapshot, six closed parsed intent products,
request-scoped allow/deny protocol mappings, and capture-failure behavior.
Observer activation is split to OXE-1.3a so the required bounded asynchronous
handoff and versioned correlation envelope receive their own RED/GREEN gate.
Final Spec and Standards review clear the authorization-only OXE-1.3 RED
checkpoint at 57 tests: 56 expected semantic failures and one passing no-op
differential. No production module, pinned kernel path, or manifest changed.

The authorization-only GREEN candidate now passes the combined 74-test
authorization/host suite and exact `make all`: 433 tests, zero failures, six
skips, 100.00% total coverage, strict Credo clean, and zero Dialyzer errors.
Its only pinned-kernel edit is the 61-line `codex/app_server.ex` seam with
fingerprint
`8a2c7cbe484e7123a136133f3dbec09f88c586191195e61a4a905963369776e`.
The manifest remains deliberately stale and fail-closed pending atomic OXE-1.4
promotion. Independent GREEN review is the remaining OXE-1.3 authorization
gate before OXE-1.3a observer GREEN can begin.

The OXE-1.3a design and RED checkpoint are now recorded in
[`openai_extension_oxe13a_bounded_observer.md`](openai_extension_oxe13a_bounded_observer.md).
Its thirteen focused tests produce twelve expected semantic failures and one passing
no-op AppServer differential; the 99-test AppServer/host/registry/authorization
baseline remains green. The design adds no startup patch: active observers use
a lazy transient dispatcher under the existing task supervisor and a bounded
restart-surviving ETS ledger. Bounded review is required before GREEN.
