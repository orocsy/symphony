# Symphony And Linear Loop

Use this when the user explicitly wants multiple agents, Symphony, delegation,
or parallel workstreams.

## Split By Ownership Boundary

Do not split by PRD heading if two headings edit the same route, service, or
state machine. Split by stable ownership:

- Data ownership.
- API/service ownership.
- UI shell versus mounted widget.
- Backend lifecycle semantics versus frontend display.
- Shared files and conflict risk.

## Dispatch Gate

Before dispatch:

1. Lock latest user intent and scope.
2. Name the target branch and PR behavior.
3. Name the Linear issue ids and states.
4. Define each agent's write scope.
5. Define shared files and who owns the first pass.
6. Define validation commands per lane.
7. Define stop conditions and handoff format.

## Recommended Linear Issue Shape

Each issue should include:

- Branch/PR contract.
- Source docs/design links.
- Runtime problem.
- Data shape.
- MIUs in order.
- Out-of-scope boundaries.
- Required tests.
- Validation commands.
- Handoff requirements.

## Concurrency Pattern

Safe parallelism:

```text
Lane A: identity/access shell
Lane B: service card UI refactor
Lane C: backend operational state
```

Unsafe parallelism:

```text
Lane A edits booking manage page
Lane B edits booking manage page
Lane C edits booking manage page
```

If shared UI is unavoidable, create a shell/slot MIU first, then let other
lanes mount into the slot.

## Symphony Auto Loop

Use this rhythm:

1. Sync branch.
2. Read Linear issue and current implementation.
3. Write/refresh MIU trace.
4. Implement one MIU.
5. Run focused tests.
6. Update Linear workpad with result, commands, blockers.
7. Push scoped commit.
8. Continue only if next MIU is unblocked and still in scope.

## Concurrent Symphony Default

Use this when independent Linear issues can ship as separate PRs:

- `max_concurrent_agents`: `3`.
- One issue creates one branch and one PR.
- Base branch is the current project default branch.
- Use Linear's `branchName` when present, otherwise
  `symphony/<ISSUE>-<slug>`.
- Require a strict dispatch-ready gate before pickup.
- Trigger Codex review on every PR.
- Move completed issues to `Human Review`; do not auto-merge by default.

Strict dispatch-ready means the issue has:

- Write scope.
- Shared files.
- Dependencies.
- MIUs.
- Validation commands.
- Out-of-scope notes.

Do not dispatch two issues together if their write scopes overlap or if one
depends on the other.

## Stop Conditions

Stop or ask before continuing when:

- User narrows scope.
- Branch/PR contract is ambiguous.
- Two agents need the same file without a boundary.
- Business rule is missing for auth, money, booking, or tenant data.
- Tests fail outside the owned scope and the failure blocks confidence.
- Tool state differs from Linear or GitHub state.
