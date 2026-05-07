# Delivery Session Learnings

This is the reusable learning layer from prior delivery sessions. It is intentionally
written as project-transferable operating knowledge, not as a history log.

## Session Timeline

| Session area | What happened | Reusable pattern |
| --- | --- | --- |
| GitHub/auth setup | Tool auth and local git setup blocked progress until the environment was explicit. | Create an environment gate before feature work: auth, remotes, package manager, browser runtime, and write permissions. |
| Worktree creation | Multiple project copies and branches existed at once. | Name the active branch, PR, base, and worktree before dispatch or push. |
| Frontend skill review | Big instructions helped at first but became heavy. | Keep the root instructions short; move detailed procedures into skills and references. |
| Browser CLI evaluation | In-app browser and Playwright can fail for different reasons. | Try the requested browser first, then record fallback evidence with exact blockers. |
| OpenClaw/Symphony review | Automation is powerful but unsafe without issue filters and branch contracts. | Dispatch automation only after filters, assignees, branch target, PR behavior, and concurrency are locked. |
| Design review sessions | Agents drifted when UI work skipped the existing product language. | Design source of truth comes before UI code; implementation extends current components and tokens. |
| Linear triage | Issue state and branch state could diverge. | Treat Linear as the work queue and GitHub as code truth; update both after each MIU. |
| Compact timeout/handoff failures | Work repeated when compaction lost the exact state. | Every long task needs a living handoff with branch, commit, commands, blockers, and next action. |
| Service photo upload | Browser-only `blob:` state and durable storage state were conflated. | MIU traces must name value lifetime: browser, request, database, object storage, cache, external provider. |
| Booking PRD split | Original requirement sections overlapped on the same page and services. | Split by ownership boundary, not by PRD heading. Shared UI needs stable slots. |
| Customer identity review | Review found legacy rows, duplicate customers, and session fallback cases. | Business correction must ask "what real old data exists?" and "what if there are many matches?" |
| OTP/session hardening | Brute-force, timing, cookie attribute, and stale token paths needed review fixes. | Security-adjacent "small fixes" still require Technical MIU with tests. |
| COD-145 recovery | Good MIU flow shipped quickly: failing tests, route access shape, client state, backend ownership tests. | One MIU at a time works when each MIU has runtime scenario, data shape, test, and validation command. |
| COD-147 browser QA | Automated browser tests were blocked by local browser/runtime issues, but visible browser evidence proved parts of the journey. | Browser verification must distinguish product failure from harness failure and keep screenshots/evidence. |
| PR review loops | GitHub showed stale unresolved review threads after fixes. | Use thread-aware review fetches; classify each comment as valid, stale, duplicate, or intentionally rejected. |
| Squash merge check | `git log branch..main` was misleading after squash merge. | After squash merges, compare trees or PR merge commit, not ancestry alone. |

## Strongest Practices

1. **Intent Lock**
   Restate the active user scope before edits, dispatch, or git operations. If
   the newest user instruction narrows scope, stop older queued work.

2. **Business Correction Loop**
   Before implementation and before final answer, ask whether the code matches
   the business truth:
   customer identity, tenant isolation, old data, duplicate records, external
   providers, rate limits, tokens, payments, cancellation money, and browser
   state lifetimes.

3. **Technical MIU Trace**
   Thin status text is not enough. A real MIU has a runtime scenario, code
   shape, data lifetime, technology constraint, alternatives rejected, and exact
   test/command proof.

4. **Design Before UI**
   UI agents should read the current product implementation and design source
   before drawing or coding. Do not create a new page treatment when the task is
   to extend an existing product surface.

5. **Concurrency With Ownership**
   Multi-agent speed came from disjoint write scopes. Parallel work without
   branch, issue, file, and PR contracts created merge/review churn.

6. **Review Comments Are Inputs, Not Orders**
   Accept valid comments, fix duplicates once, reject stale or wrong comments
   with code evidence, and trigger a fresh review after pushing.

7. **Browser Truth**
   Passing unit tests is not enough for customer journeys. Record the browser
   path tested, viewport, screenshots, interactions, and blockers.

8. **Compaction Survival**
   Every long-running session should be restartable from durable artifacts:
   current branch, PR, latest commit, dirty files, tests run, pending review
   threads, and exact next command.

## Anti-Patterns To Block Early

- Dispatching agents before ownership boundaries are clear.
- Treating review fixes as too small for MIU.
- Updating `AGENTS.md` by duplicating long examples already present elsewhere.
- Letting UI designs ignore the real product shell.
- Inferring business behavior from happy-path UI state.
- Declaring browser testing done without screenshots or actual interactions.
- Treating all GitHub unresolved review threads as current truth.
- Merging or pushing without checking unrelated dirty files.

