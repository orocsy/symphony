---
name: agentic-delivery-loop
description: Use for planning or executing complex product work with MIU traces, business correction, Linear/Symphony coordination, PR review hardening, or full browser E2E verification. Trigger when the user asks for reusable agent workflow, high-quality fast shipping, multi-agent dispatch, workstream splitting, design-to-browser delivery, or review-fix loops.
---

# Agentic Delivery Loop

Use this skill to ship product work quickly without losing business correctness.

## Core Loop

1. Lock the latest user intent in one practical sentence.
2. Identify the delivery mode:
   - `solo-miu`: one agent, one narrow feature or bug.
   - `symphony-linear`: multiple bounded workstreams.
   - `review-hardening`: PR review comments and fixes.
   - `browser-truth`: UI/customer journey verification.
3. Name the business invariants before code.
4. Write or update the Technical MIU trace.
5. Implement one MIU at a time with failing tests first when behavior changes.
6. Run focused validation immediately after each MIU.
7. Run the business correction pass before final validation.
8. Run browser verification for UI or customer-visible flow changes.
9. Update handoff state: branch, PR, commit, tests, blockers, next action.

## Business Correction Pass

Ask this before and after implementation:

- Does this match the real business state, including old data and duplicates?
- Does every ownership, actor, value, time/concurrency, storage, provider, and
  user-visible boundary remain scoped?
- If the project has tenants, customers, bookings, payments, or media, have
  those specific boundaries been checked too?
- Could an attacker enumerate, replay, brute-force, exhaust provider quota, or
  bypass a lock by racing?
- Is a browser-local value being treated as durable state?
- Is the UI showing an action the backend would reject?
- Would a customer or staff member understand the flow without hidden context?

Read `references/business-correction-loop.md` when touching auth, booking,
payments, storage, external delivery, multi-tenancy, or customer-visible flows.

## MIU Standard

An MIU is a **Minimum Implementable Unit**: one behavior change that can be
understood, implemented, tested, reviewed, and handed off independently. It is
not a vague milestone and not a status update.

Every non-trivial MIU must include concrete code context, data shapes, tradeoffs,
technical constraints, and tests. Read `references/miu-trace.md` before writing
or reviewing MIUs.

## References

- Read `references/miu-trace.md` for the full MIU format.
- Read `references/symphony-linear-loop.md` for workstream splitting,
  concurrency, Linear, and Symphony dispatch.
- Read `references/browser-e2e-gate.md` for UI/browser verification.
- Read `references/review-hardening-loop.md` for PR review comments.
- Read `references/reusable-package-format.md` when packaging the workflow for
  another project or a Symphony fork.
- Read `references/symphony-fork-workflow.md` when moving the reusable Symphony
  setup into a fork such as `orocsy/symphony`.

## Templates

Copy from `assets/templates/` when bootstrapping a project or ticket:

- `AGENTS.next-project.md`
- `linear-workstream.md`
- `symphony-dispatch.md`
- `miu-execution.md`
- `WORKFLOW.concurrent-symphony.template.md`
