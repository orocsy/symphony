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
python3 cli/orocsy.py --repo /path/to/repo gate declared-scope --scope "src/**"
python3 cli/orocsy.py --repo /path/to/repo gate required-evidence --evidence-event tool.finished
python3 cli/orocsy.py --repo /path/to/repo symphony prepare-workspace --issue COD-123 --scope "src/**"
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

## Asset Rule

Do not begin from a blank official starter when a proven asset exists. Prefer:

1. Evaluated free/open-source or official provider SDKs when they are clearly
   stronger for the domain.
2. Reusable patterns when they encode hard-won implementation details
   such as S3/R2 media URLs, provider env validation, browser evidence, tenant
   safety, or booking concurrency.
3. Framework-base assets only as the foundation needed to run the app.
