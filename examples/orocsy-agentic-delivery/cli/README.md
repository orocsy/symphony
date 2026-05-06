# Agentic Project CLI

`agentic_project.py` wraps the reusable kit so a future agent can bootstrap a
new repo without manually copying each file.

## Commands

```bash
python3 cli/agentic_project.py list
python3 cli/agentic_project.py init --repo /path/to/repo --project-name my-app
```

Useful flags:

```bash
--stack next-nest-prisma-postgres-redis
--deploy vercel-plus-managed-backend
--feature-pack media-storage
--feature-pack billing-stripe
--linear-project-slug my-linear-project
--skill-mode global
--skill-mode project
--dry-run
--force
```

## Generated Files

- `AGENTS.md`
- `PROJECT_STACK.md`
- `.codex/agentic/PROJECT_STACK.yml`
- `.codex/agentic/miu-execution.md`
- `.codex/agentic/linear-workstream.md`
- `.codex/symphony/WORKFLOW.concurrent-symphony.md`
- `.codex/symphony/start-symphony.sh`
- optional `.codex/skills/agentic-delivery-loop/`

The CLI records stack/deploy choices but does not lock the project to them.
Agents must still inspect the repo and fill the business boundary inventory
before implementation.
