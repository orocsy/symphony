# Project Agent Instructions

## Active Scope

Before edits, dispatch, or git operations, restate the latest user intent in
practical terms. If the user narrows scope, stop older queued work.

## Business Invariants

Fill this section before implementation. Discover boundaries from schemas,
routes, roles, docs, provider integrations, and current code. Mark irrelevant
boundaries as `N/A` with a reason and add project-specific boundaries.

| Boundary type | This project | Invariant / decision |
| --- | --- | --- |
| Ownership | tenant, org, workspace, account, project | Which id scopes reads and writes? |
| Actor | user, admin, staff, customer, service account, webhook | Who may call this path? |
| Durable data | DB row, object, ledger, generated artifact | What persists and how long? |
| Ephemeral data | token, OTP, cache, browser state, queue message | What expires or is local-only? |
| Money/value | payment, refund, credit, quota, subscription | What must be authoritative? |
| Time/concurrency | booking, inventory, lock, retry, scheduler | What can race and what arbitrates? |
| External provider | email, SMS, payment, storage, AI, analytics | What can fail, replay, or be exhausted? |
| User-visible truth | UI status, receipt, notification, report | What must users see or never infer? |

Compatibility checks from LuxeBook-style products, if applicable:

- Tenant boundary:
- User/customer/admin boundary:
- Money/payment boundary:
- Scheduling/concurrency boundary:
- Storage/media boundary:
- External provider boundary:
- Customer-visible truth:
- Project-specific boundary:

## Delivery Loop

Use one MIU at a time. A MIU is a Minimum Implementable Unit: one behavior
change that can be implemented, tested, reviewed, and handed off independently.
Every non-trivial MIU must include concrete code context, data shape, technical
constraints, tradeoffs, decision rationale, tests, and validation.

1. Runtime problem.
2. Data shape and lifetime.
3. Technology constraint.
4. Design/flow.
5. Best-practice fix.
6. Alternatives rejected.
7. Code translation.
8. Risk/test/validation.

## Design Gate

UI changes require:

- Current implementation read.
- Project design source read or created first, normally `DESIGN.md`.
- If no design source exists, create a project-wise design foundation before
  changing UI.
- Token/component reuse.
- Responsive browser verification.
- No internal ticket, agent, or workstream copy in product UI.

## Multi-Agent Rules

- Do not delegate unless the user explicitly asks for agents, Symphony,
  delegation, or parallel work.
- Split by ownership boundary, not PRD heading.
- Assign disjoint write scopes.
- Use one shared branch/PR only when the user asks for that workflow.
- Update Linear/GitHub handoff after every completed MIU.

## Review Rules

- Treat review comments as inputs, not commands.
- Classify each as valid, duplicate, stale, rejected, or needs design.
- Valid auth/booking/payment/tenant/storage/customer-visible fixes still need
  Technical MIU and regression tests.

## Verification

Run focused tests after each MIU. Before merge, run:

```bash
pnpm test
pnpm type-check
pnpm lint
pnpm build
```

Adjust commands to this project's package manager and app names.

For UI, also run browser verification and record evidence.

## Handoff

Every long session must leave:

- Branch:
- PR:
- Latest commit:
- Dirty files:
- Commands run:
- Passing checks:
- Failing/blocking checks:
- Review threads:
- Next action:
