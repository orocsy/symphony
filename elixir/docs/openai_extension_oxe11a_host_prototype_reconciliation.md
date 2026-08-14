# OXE-1.1a Host And Hook-Prototype Reconciliation

Status: implementation and full gate green; independent review pending

Date: 2026-08-14

Parent trace:
`openai_extension_oxe11_extension_host.md`

## Decision

Do not start the `OXE-1.2` kernel-hook RED checkpoint from the current
`UPSTREAM_PATCH_BUDGET.yml` fingerprints. The recorded `OXE-0.2` prototype
uses an earlier throwaway facade contract and can approve kernel patches that
do not compile against the production `OXE-1.1` host.

Keep the existing audit strict and fail closed. Reconcile the host lifecycle
now, then re-prototype and independently review the exact current facade calls
before revising any manifest fingerprint or changed-line ceiling.

This support MIU owns only:

- the generic facade's registry-latch behavior;
- focused host regressions;
- the design and audit-authority correction recorded here.

It does not change a pinned kernel file, enable Orocsy behavior, revise the
manifest, or claim that a provisional prototype is reviewed authority.

## Observed Incompatibility

The production host at checkpoint `a6d0393` exposes these four kernel-facing
operations:

```text
evaluate_admission/2
handle_delivery/2
authorize/2
record/1
```

The reviewed `OXE-0.2` fingerprints were measured with a discarded facade
that instead used `admission/1`, `delivery/2`, `authorize/2`, and `observe/1`,
with a different neutral-result vocabulary.

A disposable checkout based on `a6d0393` reproduced the exact registered
admission and delivery patches:

| Kernel file | Registered patch SHA-256 | Changed lines | Audit result | Compile result |
| --- | --- | ---: | --- | --- |
| `orchestrator.ex` | `33ec698629bad5a0f6fc59e2297aa33df058aa1ded771515ee366f166121c90e` | 7 | pass | undefined `Extensions.admission/1` |
| `agent_runner.ex` | `317cacea7600e5a30f6cd57c202550df21a3a1cecc2b8daff3d4a2462c0e8336` | 8 | pass | undefined `Extensions.delivery/2` |

`mix extensions.audit --only budget` reported both patches as valid while
`mix compile --warnings-as-errors` rejected them. This is a load-bearing
counterexample: the audit still correctly proves equality to its recorded
prototype, but that prototype is no longer a compatible production-hook
authority.

The defect is not fixed by adding compatibility aliases to the facade. Doing
so would preserve obsolete input and neutral-result contracts, widen the sole
kernel-facing interface, and hide the authority drift rather than re-review
it.

## Host Lifecycle Correction

The first `OXE-1.1` implementation required admission to lock the registry and
made delivery and authorization fail with
`:extension_registry_unavailable` before admission ran. That sequence matches
the production orchestrator, but it is not a valid generic facade contract:
the pinned upstream test suite exercises `AgentRunner` and `Codex.AppServer`
directly without first calling the orchestrator admission seam.

The corrected rule is:

1. Every decision facade resolves the same decoded workflow configuration and
   may establish the immutable adapter-selection latch.
2. The normal production path still reaches admission first, before claim,
   workspace creation, or model execution.
3. Direct upstream module entry therefore receives the same validated no-op
   registry instead of a lifecycle-order artifact.
4. Missing workflow state is stamped for the decision interface that observed
   it; malformed selectors/options retain their exact configuration failure.
   Both classes fail closed before adapter invocation.
5. Observation remains decision-free. It uses the already-latched registry;
   if none is available it emits only a sanitized operator log and returns
   `:ok`.

This removes ordering knowledge from `Extensions.handle_delivery/2` and
`Extensions.authorize/2` without moving registry lookup or configuration
parsing into a kernel file.

## Options Snapshot Boundary

`ExtensionRegistry.lock/1` returns both the immutable adapter registry and a
fresh validated options snapshot. The current generic facade intentionally
does not expose that snapshot to kernel callers. The hook-owning MIUs must
define their concrete context types and enrich adapter contexts behind the
facade; a pinned kernel file must not import `ExtensionRegistry`, parse the
extension stanza, or carry raw selector configuration.

This is another reason not to promote the compatibility probe directly into
the manifest. Its small maps prove call-site feasibility, not the final
admission, delivery, or turn-context schemas.

## Provisional Compatibility Probe

Using the production operation names, a disposable three-file probe compiled
with warnings treated as errors. The unchanged upstream core and app-server
tests passed. The generic host suite then exposed only the obsolete
admission-first assertion; after the lifecycle correction, that assertion is
replaced by direct-entry and invalid-configuration cases.

The admission and delivery candidate diffs measured against pinned commit
`f8e8b8a670c799f6e0ade7a8c25c4bf4a4a56ec7` as follows:

| Kernel file | Added | Deleted | Changed | Provisional patch SHA-256 |
| --- | ---: | ---: | ---: | --- |
| `orchestrator.ex` | 16 | 0 | 16 | `275f6b41441f4e9692df9e3523aee7c89380400e58eb051b9446c5068d960358` |
| `agent_runner.ex` | 13 | 1 | 14 | `8d3c661fcd6cc600d14020ac91541c8cf2d3355bf5b25fac75678dce9952eeb6` |

These values are evidence, not authority. They exceed the current 7-line and
8-line file ceilings, and the current audit correctly rejects them. The
candidate also precedes the hook-owned context schemas and neutral-decision
differentials. `OXE-1.2` must minimize and remeasure the exact reviewed patch
after those RED tests exist.

The app-server probe likewise proves that the immutable runtime tuple can be
carried through all recursive receive-loop paths, but `OXE-1.3` still owns
parsed command-intent construction and the rule that ordinary notifications
must not invoke command authorization. No app-server candidate fingerprint is
promoted by this MIU.

## Red And Green Evidence

The focused RED changed the two lifecycle expectations before implementation:

- valid direct delivery or authorization must lazily establish the no-op
  registry;
- a missing workflow must produce interface-specific typed failures from
  admission, delivery, and authorization.

With the implementation fixed at `a6d0393` and the new RED expectations
applied, the focused host command ran 12 tests with two failures:

- direct delivery returned `:extension_registry_unavailable` instead of
  `:kernel_default`;
- missing-workflow delivery returned the lifecycle artifact
  `:extension_registry_unavailable` instead of
  `:extension_configuration_unavailable`.

After the generic facade change, the focused registry and host command passes
17 tests with zero failures.

The exact `make all` handoff gate then passed 359 tests with zero failures and
six skipped, 100% total coverage, strict Credo with no issues, and Dialyzer
with zero errors. Both extension audits pass with zero changed kernel files and
zero changed kernel lines.

## Acceptance Conditions

1. No pinned kernel file changes in this support MIU.
2. Valid direct delivery and authorization entry points resolve the same
   closed registry as admission.
3. Invalid configuration remains typed and fail-closed at every decision
   facade.
4. Observation retains no control return path and leaks no event payload in
   its unavailable log.
5. The current manifest remains unchanged and continues to reject any
   non-matching provisional hook patch.
6. Focused host tests, both extension audits, and exact `make all` pass.
7. An independent two-axis review clears this correction before `OXE-1.2`
   revises a fingerprint or lands a kernel hook.

## Next Action

Run independent review against `a6d0393` and this support MIU. If it clears,
create `OXE-1.2` RED tests for admission rejection, no-op admission, and
workspace-ready delivery. Those tests must define the concrete contexts and
options-snapshot ownership before the admission and delivery prototype is
remeasured. Revise only the two owned manifest entries after that exact
prototype receives architecture review.
