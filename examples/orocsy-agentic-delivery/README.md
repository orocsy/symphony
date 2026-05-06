# Agentic Delivery Kit

This kit extracts reusable delivery patterns from the LuxeBook sessions:
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

Use all four layers together:

| Layer | Purpose | Portable? |
| --- | --- | --- |
| Skill | Small trigger and workflow router for Codex | Yes |
| References | Detailed MIU, business correction, browser, review, and Symphony rules loaded only when needed | Yes |
| Templates | Copyable `AGENTS.md`, Linear issue, MIU execution, and Symphony workflow scaffolds | Yes |
| Project docs | Session learnings and project-specific examples | Reuse as examples, not as defaults |

The skill should live in a Codex skills folder. The references/templates should
travel with it. Project docs can be copied into a new repo only when they are
useful as examples.

## Files

- `skills/agentic-delivery-loop/SKILL.md`: copyable Codex skill entrypoint.
- `skills/agentic-delivery-loop/references/`: deeper references loaded only when
  the task needs them.
- `skills/agentic-delivery-loop/assets/templates/`: copyable templates for
  `AGENTS.md`, Linear issues, Symphony dispatch, and MIU execution docs.
- `skills/agentic-delivery-loop/assets/templates/WORKFLOW.concurrent-symphony.template.md`:
  scaffold for a 3-agent, separate-PR Symphony workflow.
- `luxebook-session-learnings.md`: session-by-session lessons distilled from
  LuxeBook work.

## Inspiration

External inspiration checked for this kit:

- Boris Cherny's Claude Code workflow: https://howborisusesclaudecode.com/

Useful ideas adapted here:

- Keep multiple agents isolated in separate checkouts/worktrees.
- Give agents shared project memory, but keep it concise and indexed.
- Use custom commands/skills for repeated loops.
- Ask one agent to plan and another to verify only when concurrency is explicit.
- Fold repeated mistakes back into durable instructions or templates.

LuxeBook-specific adjustment:

- Parallelism is valuable, but only after ownership boundaries are explicit.
- A bigger `AGENTS.md` is not automatically better. Put high-frequency rules in
  the root instructions and move detailed variants into skill references.

## Next Project Bootstrap

1. Copy `skills/agentic-delivery-loop/` into the next project's `.codex/skills/`
   or global Codex skills folder.
2. Start the new project with `assets/templates/AGENTS.next-project.md`.
3. Fill the business invariant section before the first implementation ticket.
4. Use `assets/templates/linear-workstream.md` for every feature lane.
5. Use `assets/templates/miu-execution.md` as the living audit trail.
6. Before merging, run the review hardening and browser truth loops that apply.

## Symphony Fork Path

Your local Symphony checkout is fork-first:

- `origin` -> `git@github.com:orocsy/symphony.git`
- `upstream` -> `https://github.com/openai/symphony`

The reusable workflow can live in one of two places:

1. **Project-local first:** keep workflow templates in the app repo and copy
   them into each project. This is safest while the rules are still evolving.
2. **Fork overlay next:** add an `examples/orocsy-agentic-delivery/` or
   `templates/agentic-delivery/` folder to `orocsy/symphony` with the reusable
   workflow templates and docs. This makes Symphony itself a reusable agent
   runner package.

Do not commit project secrets or LuxeBook-specific env files into the Symphony
fork.
