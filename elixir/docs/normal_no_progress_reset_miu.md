# Normal No-Progress Reset MIU

Status: implementation green; focused and module validation complete
Date: 2026-08-13
Pull request: #52 (`orocsy/block-normal-no-progress-retries`)
Fixed review head: `bccecc643ca52c23895338d82defe0c6898eef62`

## Requirement

Normal worker completion must classify consecutive no-progress telemetry before
scheduling another worker. That accounting must not cross a later durable-progress
boundary for the same issue, thread, and running window.

## Smallest Testable Unit

Given three ordered worker summaries:

1. `blocked_no_durable_progress` with 10,000 counted tokens;
2. a productive summary with a current-turn durable event;
3. `blocked_no_durable_progress` with 9,000 counted tokens;

and a 15,000-token threshold, the normal completion schedules its ordinary
continuation. It does not park a correction using 19,000 tokens.

## Red Evidence

Before the implementation change, the focused regression failed because no retry
was scheduled: the reducer summed both blocked summaries across the productive
middle summary and parked the worker.

## Design

`accumulated_worker_summary_counted_tokens/3` remains bounded to telemetry from the
same issue, thread, and current running window. Within that ordered stream:

- a durable event, current-turn dirty file, or new commit resets the total to zero;
- a blocked no-progress summary adds its counted guard tokens;
- any other matching summary leaves the current total unchanged.

The reset uses the same evidence fields that `TokenTelemetry` uses to classify a
turn as productive or handoff recovery.

## Acceptance

- Focused reset regression passes.
- Existing normal-completion no-progress regressions remain green (7 tests).
- Token telemetry remains green (19 tests).
- The complete core module passes 267 of 268 tests, including the new regression;
  the sole failure is a pre-existing timing-sensitive GitHub-command PID fixture.
- `mix format --check-formatted`, `mix specs.check`, and `git diff --check` pass.
- Repository-wide validation results are recorded in the PR body.
