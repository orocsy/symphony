---
tracker:
  kind: linear
  project_slug: "<linear-project-slug>"
  active_states:
    - In Progress
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/.codex/symphony-workspaces/<project>-concurrent
hooks:
  timeout_ms: 300000
  after_create: |
    git clone "$PROJECT_REPO" .
    base_branch="${PROJECT_BASE_BRANCH:-main}"
    git fetch origin "$base_branch"
    git checkout -B "$base_branch" "origin/$base_branch"
    if [ -x .codex/worktree_init.sh ]; then
      ./.codex/worktree_init.sh
    fi
    orocsy_cli="${OROCSY_CLI:-}"
    if [ -z "$orocsy_cli" ] && [ -n "$SYMPHONY_REPO" ]; then
      orocsy_cli="$SYMPHONY_REPO/examples/orocsy-agentic-delivery/cli/orocsy.py"
    fi
    if [ -n "$orocsy_cli" ] && [ -f "$orocsy_cli" ]; then
      python3 "$orocsy_cli" --repo . symphony prepare-workspace \
        --issue "{{ issue.identifier }}" \
        --intent "Symphony issue {{ issue.identifier }}" \
        --orocsy-cli "$orocsy_cli" \
        --evidence-event tool.finished \
        --evidence-event gate.post-miu
    else
      echo "Orocsy runtime CLI not found; set OROCSY_CLI or SYMPHONY_REPO before dispatch."
      exit 1
    fi
  before_run: |
    orocsy_cli="${OROCSY_CLI:-}"
    if [ -z "$orocsy_cli" ] && [ -n "$SYMPHONY_REPO" ]; then
      orocsy_cli="$SYMPHONY_REPO/examples/orocsy-agentic-delivery/cli/orocsy.py"
    fi
    if [ -n "$orocsy_cli" ] && [ -f "$orocsy_cli" ]; then
      python3 "$orocsy_cli" --repo . symphony prepare-workspace \
        --issue "{{ issue.identifier }}" \
        --intent "Symphony issue {{ issue.identifier }}" \
        --orocsy-cli "$orocsy_cli" \
        --evidence-event tool.finished \
        --evidence-event gate.post-miu
      PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . run start --issue "{{ issue.identifier }}"
      PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . gate leaks --record
      PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . gate secrets --record
      PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . gate artifacts --record
      PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . symphony clean-generated --record
    else
      echo "Orocsy runtime CLI not found; refusing to run an ungoverned worker."
      exit 1
    fi
agent:
  max_concurrent_agents: 3
  max_turns: 8
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  max_turn_total_tokens: 1500000
  forbidden_command_patterns:
    - '(^|\s)(pnpm|next)\s+(dev|start)(\s|$)'
    - '(^|\s)(pnpm|npm|npx|yarn)\s+(dlx|exec|x)?\s*playwright\s+install(\s|$)'
    - '(^|\s)playwright\s+install(\s|$)'
  approval_policy:
    granular:
      sandbox_approval: true
      rules: false
      mcp_elicitations: true
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    writableRoots:
      - .
      - .git
    readOnlyAccess:
      type: fullAccess
    networkAccess: true
    excludeTmpdirEnvVar: false
    excludeSlashTmp: false
---

You are working on Linear issue `{{ issue.identifier }}`.

Issue snapshot:
- ID: `{{ issue.id }}`
- Title: {{ issue.title }}
- State: {{ issue.state }}
- Branch: {{ issue.branch_name }}
- URL: {{ issue.url }}
- Labels: {{ issue.labels }}
- Description:
{{ issue.description }}

Use this issue snapshot as the primary assignment source. If you must query
Linear, query by `issue.id`; do not use an `IssueFilter.identifier` filter.

{% if attempt %}
Retry continuation:

- This is retry attempt #{{ attempt }} because the issue is still active after
  an interrupted or failed worker turn.
- Resume from the current workspace state; inspect `git status --short --branch`,
  recent commits, and `.orocsy/delivery/events/events.jsonl` before editing.
- If product changes, validation, or gates already exist, enter
  handoff-recovery mode and only complete the pending commit, push, PR review
  request, or Linear update.
- If provider/network/permission failure still blocks handoff, record an Orocsy
  inbox item or workpad blocker with next action `retry` and stop.
{% endif %}

Orocsy worker prelude:

1. Read `AGENTS.md`.
2. Load the Orocsy / `agentic-delivery-loop` skill.
3. Read `.orocsy/delivery/state/current.json` and `.orocsy/delivery/policy.yml`.
   Use the workspace-local runtime CLI at `.codex/delivery/bin/orocsy.py`.
4. Read the assigned Linear issue, including Write Scope, Shared Files,
   Dependencies, MIUs, Validation, and Out Of Scope.
5. Before editing code, update `.orocsy/delivery/policy.yml` with the issue's
   declared write-scope globs if the prepare hook could not infer them.
6. Create or update the Technical MIU trace.
7. Confirm the `before_run` hook already recorded `run.started`,
   `gate.leaks`, `gate.secrets`, and `gate.artifacts` with this bounded command:
   `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . gate all --json`
   The ledger path is `.orocsy/delivery/events/events.jsonl`; do not search for
   the retired flat path `.orocsy/delivery/events.jsonl`. If the bounded gate
   command reports missing startup events, stop and report workflow setup
   failure instead of running the external `$OROCSY_CLI` path.
8. If you need to record additional runtime evidence, use:
   `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . <command>`
9. Implement one MIU at a time and append command evidence after each check:
   `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . event append --type tool.finished --status passed --tool "<command>"`
10. Before commit, run:
   `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . gate declared-scope --strict --record`
   `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . gate required-evidence --strict --record`
11. Before push, run:
   `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . gate all --json`
12. Before handoff, print the applicable eval rubric and record the verdict:
   `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . eval rubric miu-quality`
   `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . eval record miu-quality --status passed --summary "<why>"`
13. If any gate or eval fails, create/resolve inbox items and ask for guidance:
   `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . gate required-evidence --strict --inbox`
   `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py symphony guidance --workspace . --record`
14. If guidance says `block` or `retry`, update the Linear workpad and stop
    until the correction is handled.
15. Generated artifact cleanup:
    - Do not run raw destructive cleanup commands such as `rm -rf`,
      `git clean`, or `find ... -delete` inside a Symphony worker. These
      commands are approval-bound in Codex and can abort non-interactive runs.
    - Before final gates, staging, or push, and whenever generated artifacts
      such as `.next/dev`, `.orocsy/runtime`, `.pnpm-store`, `next-env.d.ts`, `dist/`,
      `coverage/`, or cache folders break validation, use the bounded cleanup
      command. It removes ignored generated folders and restores known tracked
      framework-generated files such as `next-env.d.ts`:
      `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . symphony clean-generated --record`
    - If cleanup beyond the allowlisted generated-artifact command is
      unavoidable, stop, record an Orocsy guidance/blocker, and let the
      workflow owner run or approve a bounded cleanup outside the worker. Do
      not retry the same destructive command.
16. Symphony browser verification guard:
    - Browser evidence is still required for UI-impacting work, but Symphony
      command guard denies raw dev-server and browser-install commands in
      non-interactive workers.
    - Do not run `pnpm dev`, `next dev`, `pnpm start`, `next start`,
      `pnpm dlx playwright install`, `npx playwright install`, or
      `playwright install` from a worker turn. The runtime is configured to
      fail the turn when these commands start, because they create unbounded
      servers/downloads that a non-interactive worker may not cleanly stop.
    - Do not use raw MCP browser calls such as
      `mcp__playwright__browser_run_code_unsafe` from a Symphony app-server
      worker. If that tool blocks, Symphony cannot recover the turn or hand off
      the MIU cleanly.
    - Use only a project-owned bounded browser harness, such as `pnpm e2e`,
      `pnpm exec playwright test`, or `node scripts/browser-smoke.mjs`, where
      the top-level command owns any server startup and always stops it before
      exit. Prefix any npm/npx-backed browser command with the workspace-local
      cache and keep generated browser artifacts under ignored folders:
      `PLAYWRIGHT_BROWSERS_PATH=0 NPM_CONFIG_CACHE=.orocsy/runtime/npm-cache npm_config_cache=.orocsy/runtime/npm-cache NPM_CONFIG_STORE_DIR=.orocsy/runtime/pnpm-store npm_config_store_dir=.orocsy/runtime/pnpm-store <command>`
    - If the project lacks Playwright/browser dependencies, installed browser
      binaries, or a bounded smoke harness, record the exact blocker in
      `.orocsy/delivery/events/events.jsonl`, update the Linear workpad, and
      stop. Do not install dependencies/browsers ad hoc from the worker and do
      not claim product browser verification passed.
17. Symphony permission guard:
    - Do not set `codex.approval_policy` to `never`. The generated start
      script refuses that mode because it can silently approve dangerous
      non-interactive worker requests.
    - In granular mode, Symphony may auto-approve only Codex file-change
      approvals caused by workspace edit rules being disabled. Command
      approvals, sandbox escalations, MCP elicitations, and external mutation
      approvals must not be auto-approved by the worker.
    - If a command approval or MCP/tool approval prompt appears, record the
      blocker in the Orocsy ledger, update the Linear workpad, and stop for the
      workflow owner. Do not answer approval prompts by hand inside the worker.
18. Symphony handoff recovery guard:
    - Before new product edits, inspect `git status --short --branch` and recent
      `.orocsy/delivery/events/events.jsonl` entries when the workspace already
      has local commits ahead of upstream or a previous `git push`, GitHub, or
      Linear command failed.
    - If implementation commits, validation, and gates already exist, enter
      handoff-recovery mode: retry only the pending external handoff command
      such as `git push`, PR review request/comment, or Linear workpad/state
      update. Do not modify product code or rerun broad implementation work.
    - If the network or provider remains unavailable, record an Orocsy inbox
      item with next action `retry`, update the workpad when possible, and stop
      so Symphony backoff can resume without code churn.
    - On a later retry, resume from the same workspace and finish push/review
      handoff. Do not create duplicate commits unless a current review thread
      still requires a code change.

Strict dispatch gate:

1. Continue only if the issue is explicitly dispatch-ready.
2. The issue must define Write Scope, Shared Files, Dependencies, MIUs,
   Validation, and Out Of Scope.
3. If any section is missing, update the Linear workpad with `needs-scope` and
   stop without editing code.
4. If dependencies are unfinished, update the workpad with `blocked` and stop.
5. If this issue's declared write scope overlaps another active issue, update
   the workpad with `blocked-overlap` and stop.

CI/CD timing:

1. Do not dispatch full CI/CD as an early product feature lane.
2. Keep early lanes on focused local validation, branch discipline, PR review,
   and browser evidence when UI is touched.
3. Create CI/CD as its own platform MIU after the app baseline, package scripts,
   environment requirements, and merge flow are stable on `main`.

Review hardening trigger:

1. If the issue state is `Rework`, or the issue has an attached open PR with
   unresolved Codex/human review threads, run the review hardening loop before
   any new feature work.
2. Fetch thread-aware PR review comments, not only flat PR comments.
   Prefer the bounded GitHub GraphQL `reviewThreads` shape with only path, line,
   resolved/outdated state, latest reviewed commit, and comment body.
3. Do not fetch broad PR payloads such as full `statusCheckRollup`, flat
   `comments`, full `reviews`, images, screenshots, or design files unless a
   current accepted review thread specifically requires that evidence.
4. Classify each finding as `accept`, `duplicate`, `stale`, `reject`, or
   `needs-design`.
5. Fix only accepted current-code findings inside the issue's write scope.
6. Treat the first accepted current review finding as the next MIU. Avoid
   broad exploration after a valid actionable review item is known.
7. Add or update focused regression tests for every accepted finding.
8. Push to the existing PR branch, reply or update the Linear workpad with the
   classification and validation evidence, request review again, then move the
   issue back to `Human Review`.
9. If push, GitHub review request, or Linear update fails after validation,
   record a handoff blocker and stop in handoff-recovery mode instead of
   repeating the implementation MIU.

Execution:

1. Read project instructions and the issue.
2. Create or switch to the issue branch:
   - use Linear branchName if present
   - otherwise use `symphony/{{ issue.identifier }}-<short-slug>`
3. Sync from latest `origin/main`.
4. Write or refresh the Technical MIU trace.
5. Implement one MIU at a time.
6. Run focused validation immediately after each MIU.
7. Run broader checks required by the project.
8. Push the issue branch.
9. Create or update one PR against `main`.
10. Comment `@codex review` on the PR.
11. Update the Linear workpad with branch, PR, commit, validation, blockers.
12. Move the issue to Human Review.

Never merge the PR automatically.
