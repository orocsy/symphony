# Orocsy Delivery OS

Orocsy Delivery OS packages reusable agent delivery patterns:
Symphony dispatch, Linear coordination, Technical MIU traces, design gates,
review hardening, and full browser verification.

The goal is not more process. The goal is an agent loop with enough self logic
to correct business mistakes while still shipping quickly.

## What To Reuse

| Option | Use when | Core loop |
| --- | --- | --- |
| Solo MIU loop | One agent owns a narrow feature or bug | Intent lock -> MIU trace -> failing test -> fix -> focused validation -> handoff |
| Symphony + Linear loop | Large feature has separable lanes | Split by ownership boundary -> dispatch one Linear issue per lane -> shared branch/PR contract -> merge by verified MIU |
| Review hardening loop | PR has Codex/human review comments | Fetch thread-aware comments -> classify valid/stale/duplicate -> fix valid comments only -> re-review |
| Browser truth loop | UI behavior or customer journey matters | Design source -> unit tests -> dev server -> browser walkthrough -> screenshots/evidence -> responsive checks |
| Business correction loop | Auth, payments, bookings, tenant data, storage, or external delivery changes | Trace runtime scenario -> identify business invariant -> reject naive solution -> prove invariant with tests |

## Package Shape

Use five layers together:

| Layer | Purpose | Portable? |
| --- | --- | --- |
| Skill | Small trigger and workflow router for Codex | Yes |
| References | Detailed MIU, business correction, browser, review, and Symphony rules loaded only when needed | Yes |
| Templates | Copyable `AGENTS.md`, Linear issue, MIU execution, and Symphony workflow scaffolds | Yes |
| CLI | Agent-invoked bootstrap wrapper for new repos | Yes |
| Template packs | Selectable stack, deployment, feature, and code asset profiles | Yes |
| Code assets | Runnable starter code composed from evaluated framework, reusable pattern, third-party, and project overlay packs | Yes |
| Project docs | Session learnings and project-specific examples | Reuse as examples, not as defaults |

The skill should live in a Codex skills folder. The references/templates should
travel with it. The CLI and template packs make project bootstrap repeatable.
Project docs can be copied into a new repo only when they are useful as
examples.

## Files

- `skills/agentic-delivery-loop/SKILL.md`: copyable Codex skill entrypoint.
- `skills/agentic-delivery-loop/references/`: deeper references loaded only when
  the task needs them.
- `skills/agentic-delivery-loop/assets/templates/`: copyable templates for
  `AGENTS.md`, Linear issues, Symphony dispatch, and MIU execution docs.
- `skills/agentic-delivery-loop/assets/templates/WORKFLOW.concurrent-symphony.template.md`:
  scaffold for a 3-agent, separate-PR Symphony workflow.
- `templates/` and `WORKFLOW.concurrent-symphony.template.md`: top-level copies
  of the same reusable templates for quick project seeding.
- `cli/agentic_project.py`: dependency-free bootstrap CLI for future agents.
- `cli/orocsy.py`: dependency-free runtime CLI for ledgers and deterministic
  gates.
- `project-templates/`: selectable stack/deploy/feature/code asset profiles.
- `delivery-session-learnings.md`: session-by-session lessons distilled from
  reusable delivery work.
- `orocsy-delivery-runtime-architecture.md`: current and target architecture
  for adding runtime state, gates, observability, evals, and later control-plane
  behavior.

## Inspiration

External inspiration checked for this kit:

- Boris Cherny's Claude Code workflow: https://howborisusesclaudecode.com/

Useful ideas adapted here:

- Keep multiple agents isolated in separate checkouts/worktrees.
- Give agents shared project memory, but keep it concise and indexed.
- Use custom commands/skills for repeated loops.
- Ask one agent to plan and another to verify only when concurrency is explicit.
- Fold repeated mistakes back into durable instructions or templates.

Project-specific adjustment learned from prior delivery work:

- Parallelism is valuable, but only after ownership boundaries are explicit.
- A bigger `AGENTS.md` is not automatically better. Put high-frequency rules in
  the root instructions and move detailed variants into skill references.

## Next Project Bootstrap

Preferred path:

```bash
python3 cli/agentic_project.py list
python3 cli/agentic_project.py init --repo /path/to/repo --project-name my-app
python3 cli/agentic_project.py list-assets
python3 cli/agentic_project.py evaluate --domain auth --stack nextjs-fullstack
python3 cli/agentic_project.py scaffold --repo /path/to/repo --project-name my-app \
  --profile nextjs-fullstack \
  --asset-pack media-r2-s3 \
  --asset-pack auth-evaluated
python3 cli/agentic_project.py verify-scaffold --profile nextjs-fullstack --run-checks
python3 cli/agentic_project.py providers doctor --repo /path/to/repo
python3 cli/orocsy.py --repo /path/to/repo init --intent "first MIU"
python3 cli/orocsy.py --repo /path/to/repo gate all --json
python3 cli/orocsy.py eval rubric miu-quality
python3 cli/orocsy.py --repo /path/to/repo eval record miu-quality --status passed --summary "MIU is complete"
python3 cli/orocsy.py --repo /path/to/repo inbox list --open-only
python3 cli/orocsy.py symphony guidance --workspace /path/to/repo --json
python3 cli/orocsy.py symphony monitor --root ~/.codex/symphony-workspaces/my-app-concurrent
python3 cli/orocsy.py control status
```

The CLI seeds `AGENTS.md`, `PROJECT_STACK.md`, MIU docs, Linear workstream
docs, and a Symphony workflow. The scaffold path then creates runnable code and
records why each asset was selected or rejected. Official framework starters are
only a fallback foundation; project code should come from evaluated assets when
they fit.

Before using a profile for a new project, run `verify-scaffold`. The structural
gate is dependency-free; `--run-checks` performs the full temp-project install,
typecheck, test, lint, and build loop so dependency drift is caught in the kit
instead of inside the next product repo.

For Symphony runs, use `orocsy.py symphony monitor` as the first read-only
steward command. It does not mutate Symphony or project workspaces; it reports
workspace health, branch state, Orocsy ledger state, last events, and stale
runs so a future cron or dashboard can decide whether to alert, block, or
dispatch a correction.

For workflow judgment, use `orocsy.py eval rubric <name>` to load the LLM/human
rubric and `orocsy.py eval record <name>` to turn the verdict into ledger
evidence. The first rubrics cover MIU quality, business correction, review
classification, browser evidence, and workstream split safety.

For correction and recovery, failed gates/evals can create inbox items under
`.orocsy/delivery/inbox/`. `orocsy.py symphony guidance` then gives a
non-destructive `block`, `retry`, or `continue` decision for a worker. The full
control plane remains intentionally deferred until this evidence loop catches
enough real failure modes.

Manual fallback:

1. Copy `skills/agentic-delivery-loop/` into the next project's `.codex/skills/`
   or use the global Codex skills folder.
2. Start the new project with `assets/templates/AGENTS.next-project.md`.
3. Fill the business invariant section before the first implementation ticket.
4. Use `assets/templates/linear-workstream.md` for every feature lane.
5. Use `assets/templates/miu-execution.md` as the living audit trail.
6. Before merging, run the review hardening and browser truth loops that apply.

## Symphony Fork Path

Your local Symphony checkout is fork-first:

- `origin` -> `git@github.com:orocsy/symphony.git`
- no `upstream` remote by default. Add an upstream OpenAI remote only for an
  explicit manual sync task, then remove it again before project dispatch.

The reusable workflow can live in one of two places:

1. **Project-local first:** keep workflow templates in the app repo and copy
   them into each project. This is safest while the rules are still evolving.
2. **Fork overlay next:** keep `examples/orocsy-agentic-delivery/` in
   `orocsy/symphony` with the reusable workflow templates and docs. This makes
   the fork itself the reusable agent runner package.

Do not commit project secrets or project-specific env files into the Symphony
fork.
