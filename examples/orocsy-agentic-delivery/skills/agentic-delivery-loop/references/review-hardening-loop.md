# Review Hardening Loop

Use this when Codex, a human reviewer, or CI comments on a PR.

## Thread-Aware Scan

Flat PR comments are not enough. Fetch review threads with:

- File path.
- Line.
- Resolved state.
- Outdated state.
- Latest commit reviewed.
- Comment body.

## Classify Each Finding

| Mode | Meaning | Action |
| --- | --- | --- |
| `accept` | Comment is valid on current code. | Fix with MIU if behavior/security/business-adjacent. |
| `duplicate` | Same issue already represented elsewhere. | Fix once and note duplicate. |
| `stale` | Comment points to old code or old commit. | Do not churn code; cite current code/test evidence. |
| `reject` | Comment is technically wrong or conflicts with business rule. | Explain with source code or test evidence. |
| `needs-design` | Business behavior is ambiguous. | Ask or write a design note before coding. |

## Fix Loop

1. Restate the active review scope.
2. Apply Technical MIU if touching auth, booking, payment, tenant, storage, UI
   architecture, external providers, or customer-visible behavior.
3. Add or update regression tests.
4. Run focused tests, type-check, lint, and relevant build/browser checks.
5. Stage only scoped files.
6. Commit and push.
7. Trigger another review.
8. Poll for fresh review result and distinguish it from old unresolved threads.
9. Do not hand back as complete while active accepted review threads remain.
   If accepted threads are too broad or unrelated for one MIU, leave the issue
   in Rework and record the remaining thread IDs plus next action.

## Squash Merge Caveat

After a squash merge, ancestry comparisons can be misleading:

```bash
git log origin/main..origin/feature
```

may still list old feature commits. Compare trees or PR merge commit instead:

```bash
git diff --name-status origin/main origin/feature
gh pr view <number> --json state,mergedAt,mergeCommit,headRefName
```
