# Regression efficacy and test environment failures

Use this for tests protecting important deterministic decisions: authorization,
commercial facts, version or recipient binding, execution ownership and
irreversible writes. A small targeted injection is enough when it answers the
risk; do not add mutation infrastructure to ordinary prose or low-impact edits.

## Prove the intended rejection

- Start with a passing baseline and identify the exact behavior assertion.
- Break one relevant guard in a disposable source copy or isolated runtime
  override. Confirm the test executes that change, not the original checkout.
  Invalid input against unchanged code is a negative test, not this proof.
- Keep every other prerequisite valid. Another guard rejecting first does not
  prove the intended guard works. Separate mutable fixture values when a shared
  list or object could accidentally create a second error.
- Count a defect as caught only when the intended assertion fails. Compile,
  import, environment and timeout errors are different outcomes. Record a
  surviving defect, strengthen the test or explain why the change is equivalent,
  then rerun the clean baseline and the same injection.
- Preserve the initial miss, selected test, code identity and final result.
  Targeted injections do not prove exhaustive coverage, and reruns do not add
  distinct test cases.

At database or language boundaries, check the decoded types used by control
logic as well as equal values. A real SQL expression can return a decimal
where a fixture supplies an integer; exercise the resulting retry writeback.

## Exercise partial commits across boundaries

For a multi-write transaction, inject a failure after earlier writes have run,
not only at the first write. Check that no partial state remains and the same
request can succeed after recovery. For a cross-service handoff, first prove
the remote side committed, then change or revoke local authority before the
reply is accepted. A network error before the handoff does not test that race.

For authorization refreshes, start from a task whose actions were already
narrowed. Verify that renewal or a restored connection does not silently grant
those actions again; only a separate authorized change may widen the task.

## Exercise execution ownership

When a worker can be retried or delivered more than once, test concurrent
invocations as well as repeated calls after success. A contender should not
turn another valid execution into a failed task. Both result writes and failure
transitions must verify the current execution owner; losing a lease or session
must not allow a stale worker to open a new write path.

Exercise ownership loss during generation and immediately before commit or
export. Temporary or partial files from a stale attempt must not block or be
mistaken for a replacement attempt's complete output. Use the actual database
or lease implementation for its concurrency guarantees.

If queue claims and execution locks have different lifetimes, state which one
controls execution and which one controls acknowledgments. A prior execution
can finish while a replacement waits for remote authorization. Recheck the
validated durable outcome before exhausting the retry budget; test lost
acknowledgments after both successful and failed commits.

## Check the whole deadline

A provider timeout does not bound setup or hidden SDK reads. Test credential
loading before the call and slow error responses as well as normal response
timeouts. Reject non-regular credential files without blocking, and verify
that timeout cleanup reaps only the invocation's own process.

For prompt rejection or avoiding response-body reads, hold the body behind an
explicit barrier and assert the result before releasing it. A whole-process
speed threshold also measures cold imports and runner load, so it cannot isolate
that behavior.

## Check bounded queues against history

For a queue or paged scanner, include more completed history than one batch,
a late arrival behind the cursor and a rejected item. Verify that pending work
still progresses, and that completed history does not consume the active batch.
A small empty-queue success case cannot establish those properties.

## Separate setup, behavior and cleanup

A failed environment bootstrap means the behavior tests did not run. A cleanup
failure still makes the run incomplete; do not turn it into a passing suite or
silently skip it. Preserve the log and label which stage failed.

If parallel test services stall on DDL or I/O, isolate and rerun the same failing
cases sequentially before changing application or test deadlines. Record the
environment and any separate bootstrap-wait change. A quiet rerun passing
supports a contention explanation; it does not by itself prove the sole cause.
Own test resource names and identifiers explicitly, and remove only those
resources. Never use a broad cleanup to conceal an uncertain test failure.
