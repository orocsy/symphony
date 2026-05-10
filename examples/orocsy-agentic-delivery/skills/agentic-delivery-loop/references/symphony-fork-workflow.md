# Symphony Fork Workflow

Use this when turning the reusable workflow into a forked Symphony package.

## Current Observed State

- Local checkout: `$SYMPHONY_REPO`, usually `~/src/orocsy-symphony`.
- `origin` points to `git@github.com:orocsy/symphony.git`.
- No `upstream` remote is kept during project dispatch. Add one only for an
  explicit manual sync task, then remove it again.
- Older local Elixir experiments may exist in stash; do not force-reset or drop
  stashes casually.

## Recommended Fork Setup For New Machines

Clone the fork as the main working copy:

```bash
SYMPHONY_REPO="${SYMPHONY_REPO:-$HOME/src/orocsy-symphony}"
git clone git@github.com:orocsy/symphony.git "$SYMPHONY_REPO"
```

If an upstream sync is explicitly requested, add the remote temporarily:

```bash
git -C "$SYMPHONY_REPO" remote add upstream https://github.com/openai/symphony
git -C "$SYMPHONY_REPO" fetch upstream
git -C "$SYMPHONY_REPO" merge --ff-only upstream/main
git -C "$SYMPHONY_REPO" push origin main
git -C "$SYMPHONY_REPO" remote remove upstream
```

Recommended fork content:

```text
examples/orocsy-agentic-delivery/
├── README.md
├── WORKFLOW.concurrent-symphony.template.md
├── templates/
│   ├── AGENTS.next-project.md
│   ├── linear-workstream.md
│   ├── miu-execution.md
│   └── symphony-dispatch.md
└── skills/
    └── agentic-delivery-loop/
```

## Do Not Commit

- Linear API keys.
- Project `.env` files.
- project workspace caches.
- Raw Symphony runtime workspaces.
- Local agent logs or PID files.

## How It Would Work

1. Keep reusable workflow templates in the fork under `examples/`.
2. Sync engine code from upstream only as an explicit maintenance task.
3. For a new project, copy the example workflow and templates into the project.
4. Run Symphony from the local fork checkout, pointing it at the project
   workflow file.
