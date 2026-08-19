# OXE-1.3a Bounded App-Server Observation

Status: RED recorded; bounded design review pending; OXE-1.3 GREEN review remains pending

Date: 2026-08-16

Fixed point: `f6a2418` (OXE-1.3 authorization-only GREEN candidate)

Parent traces:

- `openai_upstream_orocsy_extension_architecture.md`
- `openai_extension_oxe11_extension_host.md`
- `openai_extension_oxe13_turn_authorization.md`
- `openai_extension_oxe02_kernel_patch_budget.md`

## Decision

`OXE-1.3a` is the observation half of the top-level OXE-1.3 MIU. It owns a
bounded asynchronous dispatcher, a versioned sanitized envelope, and one
AppServer subscriber wrapper. It does not implement Orocsy telemetry storage,
aggregate views, delivery policy, retry logic, tracker mutation, MIU parsing,
or manifest activation.

The pinned client continues to construct and deliver its existing subscriber
messages. Immediately after OXE-1.3 binds the immutable `TurnContext`, the
kernel calls one facade function:

```elixir
observed_on_message = Extensions.observe_turn(turn_context, on_message)
```

When every selected observer is the literal no-op adapter, the facade returns
the original subscriber function unchanged and starts no dispatcher. Otherwise
it returns a wrapper that constructs and submits one closed envelope before
calling the original subscriber. Submission is allocation-bounded and never
waits for an adapter callback, spool, network, or queue drain.

The wrapper is the sole new AppServer seam. It observes messages already
assembled by the pinned client, including authorization events emitted by the
deep OXE-1.3 bridge. It does not modify `emit_message/4`, reinterpret raw wire
methods, or introduce a second subscriber sequence.

## Why The Dispatcher Is Lazy

The pinned baseline application supervisor is not a registered kernel hook.
Adding an observer child to `SymphonyElixir.Application.start_runtime/0` would
violate the patch budget and the OXE-1.1 startup decision. OXE-1.3a therefore
starts the dispatcher lazily as a transient child of the already-running
`SymphonyElixir.TaskSupervisor`.

The task supervisor is present in both supported runtime entry points. The
dispatcher task is restartable after abnormal exit and is removed after a
normal bounded drain. No pinned startup, configuration-schema, orchestrator, or
agent-runner file changes.

The first active `observe_turn/2` call initializes the local queue ledger and
dispatcher before returning the wrapper. Initialization performs no observer
callback or external I/O. It runs in an unlinked bootstrap process and has a
fixed 10ms caller budget. Concurrent first calls use one atomic ETS generation
row: one bootstrap wins initialization, while the others observe that same
generation and wait only within their own 10ms budgets. There is no global
process lock and event submission never enters the initialization path.

Each bootstrap generation has `initializing`, `ready`, or `aborted` state. The
dispatcher child receives that generation token and must verify it before
registering its name or accepting ingress. If task-supervisor startup does not
complete inside the caller budget, the caller atomically marks that generation
`aborted`, terminates the bootstrap, and returns a loss-signaling wrapper. A
`Task.Supervisor.start_child/3` request already queued behind a suspended
supervisor can therefore start only a child that observes `aborted` and exits
normally without registering. This explicit cancellation receipt is required
because killing the caller does not retract a queued `GenServer.call`.

Each later invocation of that wrapper remains subscriber-neutral and logs the
sanitized event-id line with `class=dispatcher_unavailable`; the wrapper does
not retry initialization. A later `observe_turn/2` call may claim a new
generation after the prior aborted child has been reaped.

## Closed Public Surface

OXE-1.3a revises the existing observer operation from synchronous arbitrary
terms to asynchronous closed envelopes and adds two lifecycle operations:

```elixir
@spec observe_turn(TurnContext.t(), (map() -> term())) :: (map() -> term())

@spec record(ObserverEnvelope.t()) :: :ok

@spec drain_observers(non_neg_integer()) ::
        :ok | {:error, :observer_drain_timeout}
```

`observe_turn/2` captures the immutable registry selection and context once.
`record/1` accepts only `ObserverEnvelope`; malformed direct input logs exactly
`telemetry.delivery_failed class=invalid_envelope`, never invokes an adapter,
and returns `:ok`. `drain_observers/1` is an
operator/test lifecycle function, not a controller decision. It closes ingress,
drains accepted ledger entries until the supplied monotonic deadline, logs an
event-id range for any deadline loss, terminates adapter tasks, and stops the
transient dispatcher normally.

The `DeliveryObserver` callback becomes:

```elixir
@callback record(ObserverEnvelope.t()) ::
            :ok | {:error, ObserverFailure.t()}
```

It has no context, options, queue handle, or controller return path. The
registry selection is immutable for the BEAM; the dispatcher stamps failures
with that captured registry revision but does not expose it inside adapter
payloads.

## Versioned Envelope

The first closed product is:

```elixir
%SymphonyElixir.Extensions.ObserverEnvelope{
  schema_version: 1,
  event_id: "evt_<sha256>",
  sequence: 1,
  emitted_at: ~U[2026-08-16 00:00:00Z],
  source: :codex_app_server,
  event_type: "codex.session_started",
  issue_id: "issue-1",
  issue_identifier: "OXE-1",
  issue_revision: "sha256:<description hash>",
  run_id: "run_<thread hash>",
  attempt_id: nil,
  turn_id: "turn-1",
  miu_id: nil,
  transition_id: nil,
  decision_id: nil,
  operation_fingerprint: nil,
  decision: nil,
  usage: %ObserverUsage{
    input_tokens: 0,
    cached_input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0
  },
  evidence_refs: []
}
```

Every struct uses `@enforce_keys` and an exact `@type t`. `source` is a closed
atom. `event_type` is the stable `codex.` prefix plus the already-assembled
event atom; it never uses an arbitrary wire method. Sequence is monotonic within
one wrapped turn subscriber. `event_id` is the lowercase SHA-256 of schema,
source, issue id, thread id, turn id, sequence, and normalized event type, with
an `evt_` prefix. It is deterministic for replay and contains no raw field.

`run_id` is the SHA-256-derived identity of the app-server thread. The AppServer
source can prove issue, run/thread, and turn correlation. It cannot prove the
orchestrator retry attempt, structured MIU, controller transition, or controller
decision identity without changing the already-reviewed agent-runner boundary.
Those fields are explicit `nil`, never guessed. Later source-specific envelopes
fill them when the owning controller supplies that authority. This is a
deliberate source-knowledge boundary, not an incomplete schema.

`issue_revision` hashes the complete issue description, matching the parent
architecture's current contextual revision receipt. The description itself,
title, URL, workspace, worker host, options, registry selection, raw payload,
raw line, port, PID, and adapter reason never enter the envelope.

`operation_fingerprint` is present only when the assembled message provides a
recognized request method and safe string/integer request id. It hashes the
normalized method and request id and then discards the payload. `decision_id`
is present only for the closed decision product and hashes `event_id` plus that
product.

The closed `ObserverDecision` variants are authorization allow, deny, invalid,
failure, approval-required, and input-required. Their fields are fixed
`type`, `class`, and nullable `wake_condition`; raw decision strings and reasons
are not retained. Non-decision app-server events have `decision: nil`.

Usage accepts known snake/camel-case token counters from the assembled metadata,
normalizes non-negative integers, computes no speculative totals, and defaults
missing counters to zero. The four counters remain distinct. Unknown usage keys
and nested raw payloads are discarded.

## Bounded Ingress Ledger

The generic queue capacity is exactly 64 accepted events, including the event
currently being delivered. It is a code constant for this MIU, not workflow
policy and not an unvalidated extension option.

Ingress uses two fixed named ETS tables:

- an ordered event ledger keyed by a monotonic dispatcher sequence;
- fixed metadata rows for pending count, sequence, accepting state, and one
  coalesced wake flag.

Both tables are named and public so producer processes can perform atomic writes
without a dispatcher call. They contain only sanitized envelopes and fixed
counters, not controller authority or secrets. Their owner sets
`SymphonyElixir.TaskSupervisor` as ETS heir, so accepted events survive an
abnormal dispatcher exit. A restarted transient task resumes the oldest ledger
entry. The entry is deleted only after every selected observer has returned or
been contained. Replay is therefore at-least-once; observer adapters must make
append operations idempotent by `event_id`.

The producer reserves one pending slot atomically before insert. At capacity it
does not insert or send an ordinary queue message. It returns immediately and
logs exactly one sanitized line:

```text
telemetry.delivery_failed first_event_id=<id> last_event_id=<id> class=queue_full
```

One ETS wake flag coalesces dispatcher wakeups, so a stalled dispatcher cannot
create an unbounded wake-message mailbox. Queue count, ledger rows, wake state,
and adapter concurrency are all bounded.

## Adapter Isolation

For each ledger event, the dispatcher invokes all selected observers in
separate linked and monitored tasks. It does not delete the ledger row until all
tasks have completed or been classified. Adapter tasks run concurrently so one
hung observer cannot prevent another observer receiving the same event.

Each callback has a 100ms monotonic deadline. Return classes are:

- `:ok` — delivered;
- `{:error, %ObserverFailure{interface: :delivery_observer}}` —
  `adapter_error`;
- any other return, including an `ObserverFailure` for another interface —
  `invalid_adapter_return`;
- raise, throw, ordinary exit, kill, or deadline — `raise`, `throw`, `exit`,
  `killed`, or `timeout`.

Failure kills only the callback task. It emits one line containing the event id,
adapter module, registry revision, and fixed class. It never contains the
envelope inspection, adapter reason, issue text, options, raw message, or stack:

```text
telemetry.observer_failed event_id=<id> interface=delivery_observer adapter=<module> registry_revision=<sha256> class=<class>
```

After classifying all callbacks, the dispatcher advances to the next ledger
event. Observer failure never changes, delays beyond the fixed local submission
work, retries, or replaces the subscriber callback.

## Restart And Drain Semantics

An abnormal dispatcher exit leaves its current ledger row intact. Linked
callback tasks die with it. The task supervisor restarts the dispatcher, which
replays that event with the same `event_id` before later rows. This proves that a
dispatcher crash is not silent and does not require a controller retry.

`drain_observers/1` atomically changes ingress to closed. New submissions remain
subscriber-neutral but log `class=dispatcher_draining`. A successful drain
waits only up to the caller-supplied deadline, delivers all accepted rows, clears
the wake state, and exits normally. At deadline, it logs the first and last
remaining event IDs as `class=drain_timeout`, kills callback tasks, clears the
bounded ledger, and returns `{:error, :observer_drain_timeout}`. Reopening on a
later active turn creates a fresh accepting dispatcher.

Application shutdown uses the transient child's fixed 1s shutdown budget. If
the supervisor terminates it before an explicit drain, its termination path
logs the current bounded ledger range as `class=shutdown` before the ETS heir is
terminated. The kernel does not wait for an unbounded spool or callback.

## Differential Contract

The executable RED checkpoint must prove:

1. no-op observers return the original subscriber function, start no dispatcher,
   and preserve the exact AppServer result and subscriber sequence;
2. a suspended task supervisor cannot hold the first active facade call beyond
   its 10ms budget; the returned loss wrapper still calls the subscriber, emits
   exact `dispatcher_unavailable` evidence, and cannot start later;
3. malformed direct `record/1` input returns `:ok`, emits only the fixed
   `invalid_envelope` line, and never reaches an adapter;
4. active observation receives the same assembled events before the unchanged
   subscriber, with no extra subscriber event;
5. the envelope has the exact closed keys/correlation/usage/decision values and
   excludes every seeded secret/raw field;
6. a hung callback does not delay the subscriber or another observer and is
   killed at the fixed deadline without sleeps;
7. 64 accepted events bound memory; later events are dropped with exact
   sanitized event-id evidence while every subscriber call still occurs;
8. typed error, wrong-interface error, malformed return, raise, throw, exit,
   kill, and timeout are individually contained with the exact event,
   adapter, registry revision, and class evidence while later queue work
   continues;
9. killing the dispatcher mid-event restarts it and replays the same accepted
   event id from the ETS ledger;
10. successful drain and deadline drain have deterministic queue/task/process
   disposition and reject later ingress without affecting the subscriber;
11. terminating the owning runtime supervisor logs the exact accepted event-id
   range as `shutdown` before the ledger disappears and permits a clean runtime
   restart;
12. baseline audit stays green, the stale budget rejects the unpromoted
   AppServer fingerprint, and exact `make all` becomes GREEN only after this RED
   contract is implemented.

No test uses sleeps. Initialization blocking uses `:sys.suspend/1` plus a
100ms assertion around the specified 10ms budget. Adapter-start,
subscriber-delivery, queue-fill, dispatcher kill/restart, timeout, and drain
use messages, monitors, and explicit calls.
Tests compare event types, ids, ordering, results, and sanitized log bodies;
timestamps and PIDs are excluded only where they are intentionally nondeterministic.

## Kernel And Manifest Boundary

GREEN may change generic extension modules and only the already-owned
`elixir/lib/symphony_elixir/codex/app_server.ex` pinned path. The intended kernel
edit is the one subscriber-wrapper assignment after successful turn binding.
`SymphonyElixir.Extensions` remains its only extension import.

Do not edit `SymphonyElixir.Application`, `AgentRuntimeSupervisor`,
`AgentRunner`, `Orchestrator`, configuration schema, or
`UPSTREAM_PATCH_BUDGET.yml`. After GREEN and independent review, remeasure the
combined OXE-1.3/1.3a AppServer patch. OXE-1.4 alone atomically promotes the
24-line orchestrator, 15-line agent-runner, and final AppServer measurements.

## Strongest Surviving Attack

The generic dispatcher guarantees bounded, at-least-once delivery to observer
callbacks, not durable telemetry persistence. A BEAM or host crash can still
lose ETS ledger rows. The parent architecture assigns durable append/spool
ownership to the later Orocsy observer adapter. That adapter must append by
`event_id` before returning `:ok`; OXE-1.3a must not pretend an in-memory generic
queue is the durable spool.

## RED Evidence

The exact focused command is:

```sh
mix test test/symphony_elixir/extensions_observer_dispatch_red_test.exs --seed 0
```

It records thirteen tests: twelve expected semantic failures and one passing no-op
AppServer baseline. The failures localize to the absent active subscriber hook,
closed envelope, bounded ingress/fan-out, dispatcher replay, and drain lifecycle.
The no-op baseline completes the same turn and emits exactly
`session_started -> notification -> turn_completed` with no dispatcher.

The unchanged AppServer, host, registry, and OXE-1.3 authorization suites pass
99 tests with zero failures. Formatter, public-spec checking, strict Credo, and
diff checking are clean. The RED checkpoint changes test fixtures, test-only
catalog entries, and documentation only; no production module, pinned kernel
file, or manifest authority changes.

## Local Adversarial Rework

A local audit after `2694fdc` found that the first RED matrix checked observer
failure classes only as substrings and did not prove the documented runtime
shutdown path. The rework requires exact event/adapter/revision/class lines,
classifies a wrong-interface `ObserverFailure` as an invalid adapter return,
and terminates/restarts the real runtime supervisor around one accepted event.
It also makes the initialization generation cancellation receipt explicit so a
queued task-supervisor call cannot create a dispatcher after the 10ms caller
deadline. This local audit is evidence hardening, not the independent bounded
Spec/Standards clearance required below.

## Next Action

Obtain bounded Spec/Standards review of the thirteen-test RED contract and this
design. Do not implement the dispatcher or AppServer hook until that review and
the separate OXE-1.3 authorization GREEN review are dispositioned explicitly.
