# OXE-1.3 Immutable Turn Authorization

Status: GREEN implemented and exact gate green; independent GREEN review pending; OXE-1.3a observer RED recorded

Date: 2026-08-16

Cleared fixed point: `b322808` (`OXE-1.2` GREEN at `943fbdd`)

Parent traces:

- `openai_upstream_orocsy_extension_architecture.md`
- `openai_extension_oxe11_extension_host.md`
- `openai_extension_oxe12_admission_delivery_hooks.md`
- `openai_extension_oxe02_kernel_patch_budget.md`

## Decision

`OXE-1.3` owns the authorization half of the last Slice 1 kernel path,
`elixir/lib/symphony_elixir/codex/app_server.ex`, and exactly two generic
capabilities:

1. capture one immutable turn context before `turn/start`;
2. authorize only parsed approval or dynamic-tool intents while carrying that
   same context through every receive-loop recursion.

It does not implement Orocsy command policy, infer MIU scope, add a registry
process, activate the manifest, reinterpret ordinary notifications as
authorization requests, or activate `DeliveryObserver`. Pinned kernel code
imports only `SymphonyElixir.Extensions`.

The original candidate combined authorization and observation. Independent
review rejected that scope: synchronous observer callbacks contradict the
parent architecture's bounded asynchronous handoff and non-blocking scheduler
requirements. The internal `OXE-1.3a` review subcheckpoint now owns the observer
dispatcher, versioned envelope, correlation IDs, bounded queue, and app-server
emission hook. It is the second gate inside the top-level `OXE-1.3` MIU, not a
fifth Slice 1 MIU, and must clear before `OXE-1.4` can activate the manifest.

## Facade Boundary

The four adapter interfaces remain admission, delivery, authorization, and
observation. OXE-1.1 began with four public facade function/arities, one for
each interface. OXE-1.3 adds four kernel-facing lifecycle and protocol-bridge
function/arities without adding an adapter interface: `capture_turn/1`,
`capture_turn/3`, `bind_turn/2`, and `handle_turn_authorization/3`. The facade
therefore exposes eight public function/arities under seven operation names.
The added entry points own workflow/registry/option snapshot construction,
server-returned turn correlation, capture/bind failure disposition, protocol
response construction, and no-op delegation so the pinned client never
performs adapter lookup or constructs adapter-visible structs:

```elixir
@type worker_host :: String.t() | nil
@type turn_facts :: {Issue.t(), Path.t(), worker_host(), String.t()}
@type app_server_request_facts :: {String.t(), map()}

@spec capture_turn(turn_facts()) ::
        {:ok, TurnSeed.t()} | {:error, ExtensionFailure.t()}

@spec bind_turn(TurnSeed.t(), String.t()) ::
        {:ok, TurnContext.t()} | {:error, ExtensionFailure.t()}

@spec capture_turn(turn_facts(), (-> term()), (-> :ok)) ::
        {:ok, String.t(), TurnContext.t()} | {:error, term()}

@spec authorize(app_server_request_facts(), TurnContext.t()) ::
        CommandAuthorization.result()

@spec handle_turn_authorization(
        app_server_authorization_facts(), TurnContext.t(), function()
      ) :: AppServerAuthorization.result()
```

`capture_turn/1`, `bind_turn/2`, and `authorize/2` define the typed extension
boundary. The two arity-three functions are deep kernel bridges: they compose
those typed operations with the pinned client's existing start/receive-loop
lifecycle while keeping lifecycle error handling and JSON-RPC response mapping
out of `codex/app_server.ex`. They do not route a fifth adapter callback.

`capture_turn/1` resolves the immutable registry and a fresh options snapshot
once per `AppServer.run_turn/4`, before the kernel sends `turn/start`. The
returned value is carried opaquely; the kernel does not read its registry or
options fields. Malformed facts fail before registry lookup with code
`:invalid_kernel_input`, interface `:command_authorization`, and reason
`:turn_facts_invalid`. Validation requires an `Issue` struct, non-empty
workspace and thread-id binaries, and a nil or non-empty binary worker host;
tuple arity alone is not sufficient.

`turn/start` is the first point at which the server returns the current turn
id. `capture_turn/3` captures before invoking the supplied start callback and,
immediately after a successful start, calls `bind_turn/2` before any subscriber
message or receive-loop entry. The facade validates the id and converts the
`TurnSeed` into the immutable adapter-visible `TurnContext`. This two-phase
construction is required: capturing after `turn/start` would make configuration
failure too late, while omitting `turn_id` would allow a request from another
turn to borrow the active policy snapshot.

Malformed seed terms fail with `:invalid_kernel_input` and reason
`:turn_seed_invalid`; a non-binary or empty server turn id fails with the same
code and reason `:turn_id_invalid`. If binding fails after `turn/start`, the
kernel cannot safely reuse a session whose active turn has no valid identity.
It therefore closes the app-server port, enters no receive loop, invokes no
subscriber or adapter, logs exactly one sanitized line
`extension turn binding failed code=<code> interface=command_authorization`,
and returns
`{:error, {:extension_turn_binding_failed, code, :command_authorization}}`.
The caller may still call idempotent `stop_session/1`, but it may not reuse the
invalidated session.

`handle_turn_authorization/3` accepts the pinned client's decoded request facts,
the facade-created bound context, and its existing no-op fallback. It delegates
closed decision work to `authorize/2`. The facade validates the targeted schema,
requires request `threadId`/`turnId` (or legacy `conversationId`) to match that
context, and constructs the closed `CommandIntent` before invoking the adapter;
neither the complete JSON-RPC payload nor its `params` map crosses that
boundary. Each authorization call revalidates immutable selector authority
through the facade but uses the context's captured options rather than a later
reload. Selector drift fails restart-required; same-selector option reload is
visible only to a later captured turn.

A recognized targeted method with a valid string/integer request id whose
payload cannot form its closed product
returns typed code `:command_intent_invalid` before adapter invocation. The
app-server maps it to request-scoped `decline`/`denied`, a sanitized dynamic
tool failure, or the existing input-required outcome when no safe response can
be formed. It never executes a tool or auto-approves a malformed target under
policy `never`. The literal no-op adapter is the sole compatibility exception:
its selected registry preserves exact pre-extension behavior so unchanged
pinned tests remain valid. An active non-noop selector cannot receive this
exception.

Any request id that is not a string or integer—including missing, null,
Boolean, floating-point, list, or map values—cannot safely identify a JSON-RPC
response for an active non-noop selector. That path sends no response, closes
the session port, emits
only the already-started `:session_started` event followed by one sanitized
`:authorization_invalid` event with fixed `request_id: :invalid`, and returns
`{:error, {:turn_input_required,
%{code: :command_intent_invalid, interface: :command_authorization}}}`. It does
not emit the raw input-required payload or a second terminal-error subscriber
event. This is distinct from malformed params with a valid id, which receive a
safe family-specific denial and keep the turn alive.

A term that is not the kernel fact tuple is different from a malformed wire
request: it returns typed code `:invalid_kernel_input`, interface
`:command_authorization`, and reason `:command_request_facts_invalid` before
registry lookup. An unknown method inside a valid fact tuple returns typed
`:command_intent_invalid`; the pinned client does not call this facade for
unknown methods.

## Capture Failure Protocol

Capture can fail because the workflow is unavailable, extension configuration
is invalid, the registry cannot be resolved, or selectors drifted after the
runtime latch. Those failures share one exact kernel contract:

1. `AppServer.run_turn/4` sends no `turn/start` request;
2. it invokes neither authorization nor the caller's `on_message` subscriber;
3. it logs exactly one line,
   `extension turn context failed code=<code> interface=command_authorization`;
4. the line excludes issue fields, workspace, worker host, thread id, options,
   adapter, registry revision, and failure reason;
5. it returns
   `{:error, {:extension_turn_context_failed, code, :command_authorization}}`;
6. a caller of `run_turn/4` retains ownership of the otherwise-valid session.

The server-returned thread id is part of those facts. A nil/empty/non-binary
thread id means the session itself is unusable rather than otherwise valid, so
the same pre-`turn/start` failure additionally closes the app-server port. RED
exercises that real ingress through `start_session/2` plus `run_turn/4`, proves
no turn request, and checks the port is already invalid before idempotent caller
cleanup.

The RED suite starts a real fake-port session, creates deterministic selector
drift, records the port writes before `run_turn/4`, and proves the post-call
trace contains no `turn/start` request. Direct facade cases terminate the
workflow cache through its real supervisor boundary and exercise both a missing
workflow and invalid extension options. No case mocks workflow or registry
authority. `AppServer.run/4` already owns session cleanup through its existing
`try/after`; changing or separately re-proving that lifecycle is outside this
MIU.

## Adapter-Owned Values

```elixir
%SymphonyElixir.Extensions.TurnSeed{
  issue: Issue.t(),
  workspace: Path.t(),
  worker_host: String.t() | nil,
  thread_id: String.t(),
  registry_revision: String.t(),
  options: map()
}

%SymphonyElixir.Extensions.TurnContext{
  issue: Issue.t(),
  workspace: Path.t(),
  worker_host: String.t() | nil,
  thread_id: String.t(),
  turn_id: String.t(),
  registry_revision: String.t(),
  options: map()
}

%SymphonyElixir.Extensions.CommandIntent{
  request_id: String.t() | integer(),
  operation:
    CommandExecution.t()
    | FileChangeApproval.t()
    | LegacyExecCommand.t()
    | LegacyApplyPatch.t()
    | DynamicToolCall.t()
    | ToolApproval.t()
}
```

Both lifecycle structs and every operation product use `@enforce_keys` and
exact `@type t`. No adapter-supplied Boolean, wall-clock value, mutable registry
handle, raw workflow configuration, complete JSON-RPC payload, or raw `params`
map enters the schema.

The operation products are discriminated by struct module, not an atom paired
with an open map:

| Product | Closed normalized fields |
| --- | --- |
| `CommandExecution` | `item_id`, `thread_id`, `turn_id`, nullable `approval_id`, nullable command text, nullable absolute `cwd`, nullable reason, closed command actions, nullable closed network approval, proposed exec-policy strings, closed proposed network amendments |
| `FileChangeApproval` | `item_id`, `thread_id`, `turn_id`, nullable absolute `grant_root`, nullable reason |
| `LegacyExecCommand` | `call_id`, `conversation_id`, `argv`, absolute `cwd`, normalized closed parsed actions, nullable reason/approval id |
| `LegacyApplyPatch` | `call_id`, `conversation_id`, closed target changes (`path`, `operation`, nullable `move_path`), nullable absolute `grant_root`, nullable reason |
| `DynamicToolCall` | `tool`, `call_id`, `thread_id`, `turn_id`, opaque JSON arguments separated from the surrounding protocol map, and fixed `arguments_validated?: false` |
| `ToolApproval` | `item_id`, `thread_id`, `turn_id`, non-empty approval questions containing unique ids and unique non-empty option labels, including exactly one `Approve Once` and one `Deny` |

Command and parsed-action text remain text because shell parsing, semantic
equivalence, and operation fingerprinting belong to the policy adapter.
Command/legacy action variants become closed `Read`, `ListFiles`, `Search`, or
`Unknown` products; network context and amendment variants become closed
host/protocol/action products. Network protocols normalize to the closed atoms
`:http`, `:https`, `:socks5_tcp`, or `:socks5_udp`; amendment actions normalize
to `:allow` or `:deny`, and every other enum value is invalid. Dynamic-tool
arguments remain untrusted opaque
provider evidence of any JSON type, as required by v0.128.0. This repository
has neither generic JSON-Schema validation nor immutable tool-schema authority
at the authorization seam, so OXE-1.3 makes that limitation executable:
`arguments_validated?` is always false and the facade normalizes a non-noop
adapter's `:allow`/`allow_once` for this product into fail-closed authorization
failure without invoking the executor. A future reviewed product revision must
bind and validate the advertised input schema before an Orocsy adapter can
allow dynamic execution. Paths are normalized absolute path facts. Existing-path
canonicalization is adapter-owned because `worker_host` may identify a remote
filesystem; a non-noop adapter must deny when it cannot prove canonical
containment. The v2 file-approval request does not contain the changed paths,
so a non-noop adapter must deny that product until a later Orocsy MIU joins the
corresponding `item/started` evidence by `item_id`.

`CommandExecution` intentionally omits raw descriptions and unknown extension
fields but retains every authority-relevant v0.128.0 field.
`LegacyApplyPatch` retains normalized target path, operation, and move target
but intentionally omits file content and unified diff from the policy boundary.
`ToolApproval` retains question identity and labels but omits
question/header/option prose. RED asserts exact struct key sets, every retained
value, every action/change variant, and these intentional omissions.

## Parsed Intent Set

The pinned AppServer recognizes these exact protocol products:

| Method | Product | Parsed condition |
| --- | --- | --- |
| `item/commandExecution/requestApproval` | `CommandExecution` | request id and all v0.128.0-required correlation fields; optional fields have their schema types |
| `item/fileChange/requestApproval` | `FileChangeApproval` | request id and all v0.128.0-required correlation fields; optional fields have their schema types |
| `execCommandApproval` | `LegacyExecCommand` | request id plus all required legacy fields and closed parsed actions |
| `applyPatchApproval` | `LegacyApplyPatch` | request id plus all required legacy fields and closed target changes |
| `item/tool/call` | `DynamicToolCall` | request id, required correlation/tool fields, and any JSON arguments value |
| `item/tool/requestUserInput` | `ToolApproval` | every question is an MCP approval product with a unique stable id and non-empty unique option labels containing exactly one `Approve Once` and one `Deny` |

Free-form `requestUserInput`, empty questions, duplicate question ids, and
missing/duplicate/empty labels never call authorization and preserve the
existing input-required branch. Recognized malformed approval/tool payloads and
every family-specific thread/turn/conversation mismatch fail closed before
adapter or tool invocation. Ordinary
notifications, terminal events, and unknown methods preserve their existing
branches without calling authorization.

## Authorization Mapping

`:kernel_default` is not approval. It enters the exact pinned behavior:

- policy `never` uses the existing session-scoped auto-approval response;
- safer policy returns the existing `:approval_required` or `:input_required`;
- dynamic tools enter the existing executor path.

Extension allow decisions are deliberately request-scoped. Neither `:allow`
nor `{:allow_once, lease}` writes a session policy cache:

| Protocol family | allow response | deny/error response |
| --- | --- | --- |
| v2 command/file request | `decision: "accept"` | `decision: "decline"` |
| legacy exec/apply request | `decision: "approved"` | `decision: "denied"` |
| MCP approval question | answer `Approve Once` | answer `Deny` |
| dynamic tool call | unavailable for an active non-noop adapter while `arguments_validated?` is false; return the fixed failure result without execution | `success: false`, one `inputText` content item, and fixed text `extension authorization denied` or `extension authorization failed` |

The literal no-op adapter's `:kernel_default` continues to execute dynamic
tools exactly as the pinned client does today. This compatibility path does not
convert unvalidated arguments into an extension authorization decision.

Allow, deny, and typed adapter failure all continue the same app-server turn;
none terminates and recreates the model session. Denial/failure emits exactly
one stable subscriber event. Denial is
`%{event: :authorization_denied, code: :extension_authorization_denied}`;
adapter error/exception or unvalidated dynamic allow is
`%{event: :authorization_failed, code: :extension_authorization_failed}`; and
recognized invalid intent or correlation is
`%{event: :authorization_invalid, code: :command_intent_invalid}`. Each event
also contains only `request_id`, `method`, fixed
`interface: :command_authorization`, and existing app-server PID/timestamp
metadata. It never contains the raw payload, adapter reason, options, issue
fields, adapter module, or registry revision. If a pinned protocol payload
cannot represent the selected allow/deny response, the kernel fails closed
into its existing approval/input-required outcome rather than guessing.

This mapping is pinned to the official Codex `rust-v0.128.0` generated schemas,
not mutable `main`. The annotated tag object is
`08ad4f5f5abf9c4844d9ccd0e2c6b364d8460d46`; its peeled source commit is
`e4310be51f617f5e60382038fa9cbf53a2429ca4`:

- [`CommandExecutionRequestApprovalResponse`](https://github.com/openai/codex/blob/e4310be51f617f5e60382038fa9cbf53a2429ca4/codex-rs/app-server-protocol/schema/json/CommandExecutionRequestApprovalResponse.json)
  proves `accept` and `decline`;
- [`FileChangeRequestApprovalResponse`](https://github.com/openai/codex/blob/e4310be51f617f5e60382038fa9cbf53a2429ca4/codex-rs/app-server-protocol/schema/json/FileChangeRequestApprovalResponse.json)
  proves `accept` and `decline`;
- [`ExecCommandApprovalResponse`](https://github.com/openai/codex/blob/e4310be51f617f5e60382038fa9cbf53a2429ca4/codex-rs/app-server-protocol/schema/json/ExecCommandApprovalResponse.json)
  and [`ApplyPatchApprovalResponse`](https://github.com/openai/codex/blob/e4310be51f617f5e60382038fa9cbf53a2429ca4/codex-rs/app-server-protocol/schema/json/ApplyPatchApprovalResponse.json)
  prove `approved` and `denied`;
- [`ToolRequestUserInputResponse`](https://github.com/openai/codex/blob/e4310be51f617f5e60382038fa9cbf53a2429ca4/codex-rs/app-server-protocol/schema/json/ToolRequestUserInputResponse.json)
  proves the question-id to answer-list product; the selected `Approve Once`
  or `Deny` label must exist exactly once in the request;
- [`DynamicToolCallResponse`](https://github.com/openai/codex/blob/e4310be51f617f5e60382038fa9cbf53a2429ca4/codex-rs/app-server-protocol/schema/json/DynamicToolCallResponse.json)
  proves the Boolean success flag and typed `contentItems` response.

The six load-bearing request receipts are SHA-256 hashes of the exact generated
files at that peeled commit:

| Request schema | SHA-256 |
| --- | --- |
| [`CommandExecutionRequestApprovalParams`](https://github.com/openai/codex/blob/e4310be51f617f5e60382038fa9cbf53a2429ca4/codex-rs/app-server-protocol/schema/json/CommandExecutionRequestApprovalParams.json) | `69b2401d8cdcad8ef06f6ad490ac8f509eb3e7f63e9115aafd4ad740825d767e` |
| [`FileChangeRequestApprovalParams`](https://github.com/openai/codex/blob/e4310be51f617f5e60382038fa9cbf53a2429ca4/codex-rs/app-server-protocol/schema/json/FileChangeRequestApprovalParams.json) | `a2f4111d102238be12ea83134f48df2e09094488dcbfb6f08e9061b0aea61181` |
| [`ExecCommandApprovalParams`](https://github.com/openai/codex/blob/e4310be51f617f5e60382038fa9cbf53a2429ca4/codex-rs/app-server-protocol/schema/json/ExecCommandApprovalParams.json) | `653116614df1aa5011c3cc399cf79bae6b9eb28c1d527df27275abf61ceb1365` |
| [`ApplyPatchApprovalParams`](https://github.com/openai/codex/blob/e4310be51f617f5e60382038fa9cbf53a2429ca4/codex-rs/app-server-protocol/schema/json/ApplyPatchApprovalParams.json) | `179d91081c3c84d0f79fc544a3d6d423f280c0f9d93512cdd0344c80e09b99a3` |
| [`DynamicToolCallParams`](https://github.com/openai/codex/blob/e4310be51f617f5e60382038fa9cbf53a2429ca4/codex-rs/app-server-protocol/schema/json/DynamicToolCallParams.json) | `401bba20cfbd95762bef0467d840430c46be53369093ad9f26425ba757e34efc` |
| [`ToolRequestUserInputParams`](https://github.com/openai/codex/blob/e4310be51f617f5e60382038fa9cbf53a2429ca4/codex-rs/app-server-protocol/schema/json/ToolRequestUserInputParams.json) | `3d42a71d4348bc8cae87594962ed5db8607be02bbdf48207c767694ef41ea7f8` |

The exact tag is the OXE-1.3 protocol target. Production activation must pin the
same Codex package version; an unversioned `npm install @openai/codex` is not
release evidence. OXE-1.3 does not add permission-request families absent from
the pinned Elixir client.

## Immutable Recursion

Before OXE-1.3, the receive loop carried only the derived
`auto_approve_requests` Boolean. GREEN replaces that recursive value with one
turn-authority product containing the existing Boolean and the captured
`TurnContext`. Every
`receive_loop`, partial-line, decoded-message, approval, and unhandled-message
recursion carries the same value. No recursive branch re-reads workflow options
or reconstructs the context.

The RED fixture emits an explicitly oversized JSON line so the Erlang port
delivers at least one `{:noeol, chunk}`, then an ordinary notification, an
unknown notification, two different approval products, and a terminal event.
It pauses the first authorization with a message barrier, reloads the same
selectors with different options, and then resumes. Both authorization calls
must observe the original context/options/revision; a later `capture_turn/1`
must observe the new options with the same registry revision. No sleeps are
used for synchronization.

## Observer Boundary Deferred To OXE-1.3a

OXE-1.3 does not call `Extensions.record/1` from AppServer and does not define
an app-server `ObserverEvent`. OXE-1.2's `DeliveryEvent` remains the
workspace-ready controller product. OXE-1.3a must design and prove, before any
observer hook is written:

- a bounded asynchronous handoff whose full/hung/failing paths cannot block the
  subscriber or scheduler;
- a versioned stable envelope with event id/time/source/type and explicit run,
  issue, attempt, turn, MIU, transition, and decision correlation fields;
- a sanitized loss/failure signal and deterministic shutdown/drain semantics;
- observer disablement/failure differentials proving identical controller and
  subscriber behavior.

## RED Tests

The checkpoint adds test-only adapters and focused tests for:

1. exact closed facade-owned seed/context construction, option snapshot/reload,
   and typed pre-registry rejection of malformed tuple and member facts;
2. unavailable-workflow and invalid-options facade failures plus exact
   selector-drift and invalid-server-thread result/log/no-`turn/start`/
   no-subscriber/session-disposition behavior;
3. two-phase seed/context binding, exact invalid-seed/post-start-bind failure,
   plus closed command-intent construction for all six method/product mappings
   and every family-specific thread/turn/conversation correlation;
4. exact v0.128.0 allow/allow-once/deny/error response bodies for all six
   products with integer and string JSON-RPC ids without restarting the
   app-server turn, including fail-closed non-noop dynamic allow while
   arguments remain unvalidated;
5. missing and non-string/non-integer ids plus malformed params/nested
   action/change and network enum variants across v2, legacy, and dynamic
   families failing closed before adapter/tool invocation, including direct
   reusable-session proof of no response/port invalidation when the id cannot
   identify a safe response, plus
   empty/duplicate questions, missing/duplicate/empty labels, free-form input,
   and thread/turn mismatches bypassing the adapter;
6. no-op authorization preserving safer-policy approval-required behavior and
   policy-`never` session auto-approval exactly;
7. every JSON argument type remaining explicitly unvalidated, active non-noop
   allow/allow-once failing without execution, no-op default execution, and
   deny/error sanitized tool results;
8. an oversized split-line, ordinary notification, unknown notification, and
   two approvals carrying one context across every recursion plus a
   message-barrier mid-turn option reload;
9. every adapter return/raise/throw/exit branch normalized into an exact
   request response and stable subscriber event without raw reason, options,
   issue fields, adapter/revision, or wire payload;
10. the stale `app_server.ex` prototype fingerprint remaining optional and
    fail-closed until the exact GREEN patch is reviewed for OXE-1.4.

Tests compare canonical event types, decisions, and ordering. They exclude
timestamps, PIDs, temporary paths, and raw secret-bearing payloads.

## RED Evidence

At this checkpoint the exact focused command is:

```sh
mix test test/symphony_elixir/extensions_turn_authorization_red_test.exs --seed 0
```

It deterministically records 57 tests, 56 semantic failures, and one passing
no-op baseline. The failures localize to absent `capture_turn/1`, absent
pre-`turn/start` capture and post-start binding, absent closed protocol
authorization, missing request-scoped response mapping, unsafe-id and
malformed/cross-turn policy-`never` bypasses, missing sanitized subscriber
evidence, missing recursion context, and the existing
duplicate-question/duplicate-label auto-answer behavior. The unchanged
app-server/host/registry suite passes 40 tests. Formatter, public-spec checking,
and strict Credo are clean. No production module or pinned kernel file changes
in this RED checkpoint.

## GREEN Evidence

The authorization-only implementation keeps the observer surface inactive and
changes no manifest authority. The exact combined authorization/host command
passes 74 tests. The complete repository gate passes 433 tests with zero
failures and six skips, 100.00% total coverage, public specs, strict Credo, and
Dialyzer with zero errors. The baseline audit remains green.

The new boundary coverage includes omitted and nil optional protocol fields,
every retained malformed field class, empty worker host, invalid seed/context,
registry revision drift, pre-receive-loop start failure, and unsafe-id port
closure for both live and already-closed ports. These cases keep malformed
evidence out of the adapter rather than adding coverage exclusions.

## Manifest Boundary

`OXE-1.3` changes neither `UPSTREAM_PATCH_BUDGET.yml` nor the already reviewed
OXE-1.2 evidence. The implemented
`elixir/lib/symphony_elixir/codex/app_server.ex` patch measures 61 changed lines
(44 additions, 17 deletions) with replacement fingerprint
`8a2c7cbe484e7123a136133f3dbec09f88c586191195e61a4a905963369776e`.
Together with the reviewed 24-line orchestrator and 15-line agent-runner
patches, the provisional aggregate is 100 changed kernel lines. The stale
40-line manifest rejects all three replacement fingerprints and ceilings as
designed. OXE-1.4 atomically promotes the independently reviewed paths and
revises the aggregate ceiling; piecemeal authority is forbidden.

## Independent Review Disposition

The Spec and Standards passes initially found authority gaps in the combined
authorization/observer candidate. The checkpoint was narrowed to authorization
and reworked until the executable RED contract covered closed lifecycle and
intent products, exact protocol receipts/responses, every active-turn
correlation family, invalid thread/turn/request-id session disposition,
malformed nested variants, every JSON argument class, sanitized subscriber/log
evidence, and recursive context preservation. Observation moved to the internal
OXE-1.3a review subcheckpoint because its required bounded asynchronous
dispatcher and versioned envelope are a separate proof.

Final bounded Spec and Standards review reported no surviving finding. The
reviewed fixed candidate contains no production or manifest edit: 57 focused
tests reproduce 56 expected semantic RED failures and one passing no-op
differential; the unchanged app-server/host/registry baseline passes 40 tests;
formatter, public specs, strict Credo, and diff checking are clean.

The GREEN candidate now satisfies the executable contract and exact repository
gate with the measured 61-line seam. Its production code and measurement still
require the independent GREEN Spec/Standards pass named by acceptance condition
11; this document does not treat the local gate as that independent clearance.

## Acceptance Conditions

1. RED failures localize to absent turn-context enrichment and kernel hooks.
2. Only `codex/app_server.ex` changes in the pinned kernel during GREEN.
3. Pinned code references only `SymphonyElixir.Extensions`.
4. One context/options snapshot survives every recursive branch in one turn.
5. Authorization runs only for the six parsed intent kinds, after exact active
   thread/turn/conversation correlation; unsafe request ids never receive a
   response or reach the adapter/executor.
6. `:kernel_default` preserves both existing approval modes and dynamic-tool
   behavior exactly.
7. Non-default allow/deny/error continues the same turn with the documented
   request-scoped protocol result.
8. Capture failure sends no turn request; an invalid server thread id and a
   post-start binding failure invalidate their unusable session before
   receive-loop entry. All emit no subscriber message, return their documented
   typed tag, and log one sanitized line.
9. Split-line, notification, unknown-message, approval, and terminal recursions
   all carry the same captured context.
10. Focused tests, unchanged app-server tests, baseline audit, and exact
   `make all` pass; budget audit continues to reject the stale manifest.
11. Independent Spec and Standards review clears authorization RED and GREEN;
    the internal OXE-1.3a subcheckpoint then clears the observer boundary before
    OXE-1.4 makes `app_server.ex` required.

## Next Action

Obtain independent GREEN Spec/Standards review of the authorization-only
candidate and its measured 61-line AppServer seam. In parallel, disposition the
twelve-test OXE-1.3a RED contract recorded in
`openai_extension_oxe13a_bounded_observer.md`; do not begin observer GREEN until
both reviews are explicit. Keep the manifest unchanged until OXE-1.4 promotes
all three reviewed kernel patches atomically.
