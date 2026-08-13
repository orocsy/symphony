# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

### Hardened worker command policy

The Elixir runtime can narrow fresh implementation and review rework workers with
mode-specific command guards. Review rework may allow one local metadata-only checkpoint form,
`git log -N --oneline [--decorate|--no-decorate]` for `N` from 1 through 20, when the effective
operator-configured policy also admits it. Revision selectors, pathspecs, content-producing output,
other flags, and unbounded history remain denied.

Structured handoff recovery may read a file named directly by the active Runtime Contract's
`write_scope` or `read_context`. The allowance is read-only and exact-path: every parsed operand
must be declared, derived/imported context is not promoted, shell chains and substitutions remain
denied, and an operator-configured command ban always takes precedence. Existing targets must
canonicalize to regular files inside the workspace; a missing declared target may be probed only
when its canonical path remains inside the workspace. When a denied compound
read is recoverable, the worker is instructed to split it into separate single-purpose commands;
the runtime never authorizes the compound command itself. In `handoff_recovery` only, the runtime
may also admit the canonical active issue brief at `.orocsy/delivery/issue-brief.md` or
`.codex/agentic/issue-briefs/<active-id>.md`. Explicit denied scope takes precedence, other issue
briefs and dispatch modes receive no such authority, and the target is revalidated as a regular
file inside the workspace immediately before execution.

For structured Runtime Contracts, dispatch follows ticket type and certified MIU lifecycle before
generic Git handoff heuristics. Integration-check tickets retain integration mode. A clean branch
with a pending MIU starts fresh implementation only when no committed delta exists after that MIU's
certification base; otherwise Symphony recovers and certifies the existing checkpoint. If Git or
controller evidence cannot prove the absence of a committed delta, dispatch fails closed instead of
restarting implementation. Branch synchronization preserves the pre-sync authoritative branch head
when it precedes the synchronized tip. A recreated workspace instead derives the first MIU base from
the integration branch's merge base with the declared base branch, so a pushed commit cannot erase
its own delta. The immutable snapshot binds the pending MIU, base and head commits, and concrete
paths; undeclared or explicitly denied committed paths also fail closed. That unsafe evidence keeps
priority when live corrections refresh a prompt, so correction text cannot restore edit or commit
authority. A structured pending-MIU lifecycle state also precedes premature PR feedback; legacy
review rework keeps its best-effort branch refresh when the remote is temporarily unavailable.
Recovery prompts name an actual committed path, never a wildcard scope. When that committed delta
needs a missing in-scope fix, the worker creates one conditional follow-up micro commit before
requesting certification; an already-complete, clean delta receives no duplicate or empty commit.
The controller classifies committed, staged, unstaged, and untracked paths together, so in-scope
dirt must enter that follow-up commit and out-of-scope dirt fails closed. Signed MIU boundaries are
enumerated across every commit in the uncertified range, so restoring a path at the range endpoint
cannot hide an undeclared write. A dirty-only pending MIU receives the same structured micro-commit
and `miu.completion_requested` sequence instead of the legacy push/review handoff. Plain directory
write scopes authorize descendants consistently in command enforcement, recovery classification,
and certification. The signed certificates are also copied to controller-owned state outside the
issue workspace and restored after workspace recreation; set
`SYMPHONY_CONTROLLER_EVIDENCE_STATE_DIR` to an operator-owned path outside every
issue workspace to override that state root.

Observer telemetry writes a non-authoritative per-issue aggregate under
`.orocsy/delivery/token-telemetry/issue-aggregate.json`. It reports attempts, consecutive
no-progress attempts, token totals, dominant phase/signature, and latest progress without changing
dispatch state.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
