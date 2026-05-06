# Project Bootstrap CLI

Use the CLI when starting a new project or turning an existing repo into an
agent-ready repo.

## Why It Exists

The workflow skill tells Codex how to work, but a project also needs a
repeatable way to install the workflow files, record stack choices, and create a
Symphony workflow. The CLI wraps that setup so the user does not need to copy
files manually.

## Runtime Shape

```mermaid
flowchart LR
  Agent["Agent / Codex"] --> CLI["agentic_project.py init"]
  CLI --> Repo["Target repo"]
  CLI --> Skill["Global or project skill"]
  CLI --> Stack["PROJECT_STACK.md"]
  CLI --> Workflow[".codex/symphony/WORKFLOW.concurrent-symphony.md"]
  CLI --> MIU[".codex/agentic/miu-execution.md"]
```

## Command Pattern

```bash
python3 examples/orocsy-agentic-delivery/cli/agentic_project.py list

python3 examples/orocsy-agentic-delivery/cli/agentic_project.py init \
  --repo /path/to/new-repo \
  --project-name my-app \
  --stack nextjs-fullstack \
  --deploy vercel-plus-managed-backend \
  --feature-pack auth \
  --skill-mode global
```

## What It Writes

- `AGENTS.md`
- `PROJECT_STACK.md`
- `.codex/agentic/PROJECT_STACK.yml`
- `.codex/agentic/miu-execution.md`
- `.codex/agentic/linear-workstream.md`
- `.codex/symphony/WORKFLOW.concurrent-symphony.md`
- `.codex/symphony/start-symphony.sh`
- Optional project-local `.codex/skills/agentic-delivery-loop/`

## Selection Rule

Do not assume LuxeBook's stack. Pick a stack/deploy profile based on the new
project's real product shape:

- `nextjs-fullstack`: one deployable web app is enough.
- `next-nest-prisma-postgres-redis`: separate API plus web apps, SaaS-style.
- `api-service`: backend-first or integration-heavy product.

If the stack does not fit, use the closest profile only as a record of starting
assumptions, then update `PROJECT_STACK.md`.
