# Orocsy Delivery OS CLI

`agentic_project.py` wraps Orocsy Delivery OS so a future agent can bootstrap a
new repo without manually copying each file.

## Commands

Project factory:

```bash
python3 cli/agentic_project.py list
python3 cli/agentic_project.py list-assets
python3 cli/agentic_project.py init --repo /path/to/repo --project-name my-app
python3 cli/agentic_project.py evaluate --domain auth --stack nextjs-fullstack
python3 cli/agentic_project.py scaffold --repo /path/to/repo --project-name my-app \
  --profile nextjs-fullstack \
  --asset-pack media-r2-s3
python3 cli/agentic_project.py verify-scaffold --profile nextjs-fullstack
python3 cli/agentic_project.py verify-scaffold --profile nextjs-fullstack --run-checks
python3 cli/agentic_project.py providers doctor --repo /path/to/repo
```

Runtime ledger and deterministic gates:

```bash
python3 cli/orocsy.py --repo /path/to/repo init --intent "ship feature"
python3 cli/orocsy.py --repo /path/to/repo run start --issue COD-123
python3 cli/orocsy.py --repo /path/to/repo event append --type tool.finished --status passed --tool "pnpm test"
python3 cli/orocsy.py --repo /path/to/repo gate all --json
python3 cli/orocsy.py --repo /path/to/repo gate issue-requirements --strict
python3 cli/orocsy.py --repo /path/to/repo gate declared-scope --scope "src/**"
python3 cli/orocsy.py --repo /path/to/repo gate required-evidence --evidence-event tool.finished --inbox
python3 cli/orocsy.py eval list
python3 cli/orocsy.py eval rubric miu-quality
python3 cli/orocsy.py --repo /path/to/repo eval record miu-quality --status passed --summary "MIU is complete"
python3 cli/orocsy.py --repo /path/to/repo inbox list --open-only
python3 cli/orocsy.py --repo /path/to/repo symphony prepare-workspace --issue-file linear/COD-123.json
python3 cli/orocsy.py symphony guidance --workspace /path/to/repo --json
python3 cli/orocsy.py symphony monitor --root ~/.codex/symphony-workspaces/my-app-concurrent --json
python3 cli/orocsy.py control status
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

Verification flags:

```bash
--asset-pack media-r2-s3
--asset-pack auth-evaluated
--run-checks
--package-manager pnpm
--keep-temp
```

Scaffold flags:

```bash
--profile nextjs-fullstack
--asset-pack auth-evaluated
--asset-pack stripe-billing-evaluated
--asset-pack ci-browser-e2e
--no-default-assets
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
- `.orocsy/delivery/evals/*.rubric.md` after runtime initialization

`scaffold` additionally generates runnable project code and decision memory:

- `package.json`
- TypeScript, Next.js, ESLint, and Vitest config
- `src/app/*`
- `src/lib/env.ts`
- selected integration helpers such as media, auth, billing, boundaries, and CI
- `.env.example`
- `.codex/agentic/ASSET_DECISIONS.yml`
- `SCAFFOLD_DECISIONS.md`
- `docs/providers/PROVIDER_SETUP.md`

The CLI records stack/deploy choices but does not lock the project to them.
Agents must still inspect the repo and fill the business boundary inventory
before implementation.

`orocsy.py symphony monitor` is read-only. It scans a Symphony workspace root
or a single workspace and reports git branch/head/dirty state, Orocsy delivery
state, event counts, last event, stale runs, and missing runtime ledgers. Use
`--strict` when a cron/steward job should fail on warnings.

`orocsy.py inbox` stores correction items as JSON and Markdown under
`.orocsy/delivery/inbox/`. Failed gates and evals can create inbox items with
`--inbox`; workers resolve them only after recording the missing evidence.

`orocsy.py symphony guidance` is controlled but non-destructive. It returns one
of `block`, `retry`, or `continue` based on missing runtime state, stale runs,
failed events, and unresolved corrections. `orocsy.py control status` documents
the intentionally deferred full control plane.

## Stability Gate

Run `verify-scaffold` before trusting a bootstrap profile. Without
`--run-checks`, it generates a temp repo and verifies structure only: required
files exist, dependency ranges are not `latest`, decision files are present, no
secret-looking literals are emitted, Next tsconfig defaults are pre-written, and
generated lint config avoids known flat-config incompatibilities.

With `--run-checks`, it also runs:

```bash
pnpm install
pnpm typecheck
pnpm test
pnpm lint
pnpm build
```

This is the stabilization loop: debug once, then move the failure class into
the bootstrap gate.

Runtime checks:

```bash
python3 -B -m unittest test_agentic_project.py test_orocsy.py test_orocsy_e2e.py
```

## Asset Rule

Do not begin from a blank official starter when a proven asset exists. Prefer:

1. Evaluated free/open-source or official provider SDKs when they are clearly
   stronger for the domain.
2. Reusable patterns when they encode hard-won implementation details
   such as S3/R2 media URLs, provider env validation, browser evidence, tenant
   safety, or booking concurrency.
3. Framework-base assets only as the foundation needed to run the app.
