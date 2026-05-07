# Project Template Packs

Template packs describe reusable project shapes. They are intentionally
declarative: the agent chooses a profile, records it in `PROJECT_STACK.md`, and
then implements or adapts the real code after inspecting the project.

## Layers

| Layer | Purpose |
| --- | --- |
| `stacks/` | Product/runtime architecture choices such as web app, API service, SaaS monorepo, database, cache, and language. |
| `deploy/` | Deployment topology choices such as managed frontend, API runtime, database, cache, storage, secrets, and CI. |
| `feature-packs/` | Optional business/platform capabilities such as auth, billing, media, notifications, analytics, and AI. |
| `code-assets/` | Runnable scaffold assets grouped by framework base, LuxeBook-extracted patterns, third-party evaluations, and project overlays. |

## Rule

Never treat a profile as a command to use LuxeBook's exact stack. Profiles are
starting points. The project-specific `PROJECT_STACK.md` is the durable truth
after bootstrap.

Code assets are stricter than profiles: each asset must record what it provides,
what it depends on, why it is selected, and when to reject it. A scaffold must
write `SCAFFOLD_DECISIONS.md` and `.codex/agentic/ASSET_DECISIONS.yml` so the
next agent can see the technical reasoning instead of guessing.
