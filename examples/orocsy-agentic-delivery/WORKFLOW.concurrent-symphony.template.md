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
review_monitor:
  enabled: true
  provider: github
  repo: "$PROJECT_REPO"
  states:
    - Human Review
  rework_state: Rework
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
  max_failed_worker_retries: 3
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  max_turn_total_tokens: 1500000
  durable_progress_timeout_ms: 60000
  durable_progress_min_tokens: 30000
  durable_progress_first_event_max_tokens: 120000
  forbidden_command_patterns:
    - '(^|\s)(pnpm|next)\s+(dev|start)(\s|$)'
    - '(^|\s)(pnpm|npm|npx|yarn)\s+(dlx|exec|x)?\s*playwright\s+install(\s|$)'
    - '(^|\s)playwright\s+install(\s|$)'
  safe_command_approval_patterns:
    - '^/bin/zsh -lc "ps -axo pid,ppid,stat,command \| rg ''[A-Za-z0-9_./| -]+''"$'
    - '^ps -axo pid,ppid,stat,command( \| rg ''[A-Za-z0-9_./| -]+'')?$'
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
- If `git status` is dirty/ahead and recent `tool.finished`, `gate.post-miu`,
  `gate.required-evidence`, or `gate.declared-scope` events passed, this is a
  dirty validated handoff checkpoint.
- At a dirty validated handoff checkpoint, inspect the focused diff, then stage,
  commit, push, request/update PR review, and update Linear before any broad
  PR/Linear scans or broad validation reruns.
- If `git status` is clean on a pushed non-main branch and recent validation/gate
  events passed, this is a pushed validated handoff checkpoint: verify/create
  the PR, request/update PR review, and update Linear before any broad scans.
- If product changes, validation, or gates already exist, enter
  handoff-recovery mode and only complete the pending commit, push, PR review
  request, or Linear update.
- If provider/network/permission failure still blocks handoff, record an Orocsy
  inbox item or workpad blocker with next action `retry` and stop.
{% endif %}

Orocsy worker prelude:

1. Read `AGENTS.md`, `.orocsy/delivery/state/current.json`, and
   `.orocsy/delivery/policy.yml`. Use the workspace-local runtime CLI at
   `.codex/delivery/bin/orocsy.py`.
2. Read the assigned Linear issue, including Write Scope, Shared Files,
   Dependencies, MIUs, Validation, and Out Of Scope.
3. Skill loading guard:
   - Do not load global/plugin skill bodies or skill reference files during the
     first worker turn. This workflow and `.codex/delivery/bin/orocsy.py` are
     the Orocsy runtime instructions for Symphony workers.
   - If a broad skill seems useful, defer it until after the branch exists,
     write-scope policy is updated, the Technical MIU trace is refreshed, and
     either a first code/test edit or a blocker event has been recorded.
4. If `.codex/agentic/issue-briefs/{{ issue.identifier }}.md` exists, treat it
   as the cached technical handoff for current file paths and target code shape.
   Do not rediscover broad context before using that brief.
5. First-turn context budget:
   - During the first worker turn, read only `AGENTS.md`, the assigned Linear
     issue, the matching `.codex/agentic/issue-briefs/{{ issue.identifier }}.md`,
     `.orocsy/delivery/state/current.json`, `.orocsy/delivery/policy.yml`, and
     the smallest directly named source/test files from the brief.
   - Do not open full project docs, broad design docs, old ticket logs, or
     recursive file listings unless the issue brief is missing a required file
     path. Prefer `rg -n` and `sed -n` slices under 220 lines. Keep command
     `max_output_tokens` at or below 12000 unless a single required file slice
     genuinely needs more.
6. First durable progress checkpoint:
   - Before optional skills, broad docs, recursive listings, or reading more
     than eight implementation files, create/switch to the issue branch, update
     `.orocsy/delivery/policy.yml` with the declared write-scope globs if the
     prepare hook could not infer them, and create or refresh the Technical MIU
     trace/spec with concrete current file paths, target code shape, data
     lifetime, concurrency/provider constraints, exact tests, and validation
     commands.
   - Immediately append a durable progress event:
     `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . event append --type tool.finished --status passed --tool "first-turn-miu-handoff"`
   - If the MIU shape is still unclear after the issue and directly named files,
     record a blocker and stop instead of reading broadly.
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
   Dynamic `eval.*` events are durable progress. Do not invent a separate
   narrative status when the eval command can record the proof.
13. Handoff git-state verification guard:
   - After the final push and before any GitHub or Linear completion update,
     verify the actual repository state:
     `git status --short --branch`
     `git rev-parse HEAD`
     `git rev-parse @{upstream}`
   - The branch must be clean and local `HEAD` must equal upstream. A narrative eval
     summary saying "committed" or "pushed" is not evidence.
   - If the branch is dirty, ahead of upstream, missing an upstream, or the
     remote PR head does not match local `HEAD`, stop in handoff-recovery mode,
     record the blocker, and do not move the issue to review/completion.
   - After PR/review/Linear handoff succeeds, append a durable handoff event:
     `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . event append --type handoff.completed --status passed --tool "github-linear-handoff"`
14. If any gate or eval fails, create/resolve inbox items and ask for guidance:
   `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py --repo . gate required-evidence --strict --inbox`
   `PYTHONDONTWRITEBYTECODE=1 python3 .codex/delivery/bin/orocsy.py symphony guidance --workspace . --record`
15. If guidance says `block` or `retry`, update the Linear workpad and stop
    until the correction is handled.
16. Generated artifact cleanup:
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
18. Symphony browser verification guard:
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
19. Symphony permission guard:
    - Do not set `codex.approval_policy` to `never`. The generated start
      script refuses that mode because it can silently approve dangerous
      non-interactive worker requests.
    - In granular mode, Symphony may auto-approve Codex file-change approvals
      caused by workspace edit rules being disabled and commands matching
      `codex.safe_command_approval_patterns`. Keep those patterns read-only and
      narrow. Current default permits only the `ps -axo ... | rg ...`
      diagnostic used to inspect a stuck git/ssh process.
    - Command approvals outside the safe-command patterns, sandbox
      escalations, MCP elicitations, and external mutation approvals must not be
      auto-approved by the worker.
    - If a command approval or MCP/tool approval prompt appears, record the
      blocker in the Orocsy ledger, update the Linear workpad, and stop for the
      workflow owner. Do not answer approval prompts by hand inside the worker.
20. Symphony handoff recovery guard:
    - Before new product edits, inspect `git status --short --branch` and recent
      `.orocsy/delivery/events/events.jsonl` entries when the workspace has
      dirty changes, local commits ahead of upstream, or a previous `git push`,
      GitHub, or Linear command failed.
    - Dirty validated handoff checkpoint: when `git status` is dirty/ahead and
      recent `tool.finished`, `gate.post-miu`, `gate.required-evidence`, or
      `gate.declared-scope` events passed, the next worker action is focused
      diff inspection, staging, commit, push, PR review request/update, and
      Linear handoff. Do not query broad Linear/GitHub context or rerun broad
      validations before the commit unless the focused diff is incomplete or
      invalid.
    - Pushed validated handoff checkpoint: when `git status` is clean on a
      pushed non-main branch and recent validation/gate events passed, the next
      worker action is only PR existence/create/update, PR review request, and
      Linear handoff. Do not redo implementation, broad context scans, or broad
      validations first.
    - If product changes, validation, and gates already exist, enter
      handoff-recovery mode: complete only the pending commit, push, PR review
      request/comment, or Linear workpad/state update. Do not modify product
      code or rerun broad implementation work.
    - If the network or provider remains unavailable, record an Orocsy inbox
      item with next action `retry`, update the workpad when possible, and stop
      so Symphony backoff can resume without code churn.
    - On a later retry, resume from the same workspace and finish push/review
      handoff. Do not create duplicate commits unless a current review thread
      still requires a code change.
21. Runtime failure parking guard:
    - The Symphony runtime will stop a worker immediately when Codex requests
      command approval, sandbox approval, MCP elicitation, or interactive input
      that the non-interactive worker cannot safely answer.
    - Live Codex turn token-budget exhaustion parks immediately with next action
      `block` when no fresh local handoff progress exists. If the same run
      produced dirty files or local commits ahead of base, Symphony schedules a
      constrained handoff-recovery retry first so the worker can validate,
      push, request review, and update Linear without redoing product work.
    - High token usage by itself is not a failure. Symphony parks only the
      high-token/no-recent-durable-progress case: after the configured progress
      window, the worker must have recent dirty files, local commits/ahead
      status, or passed MIU/gate evidence such as `tool.finished`,
      `gate.post-miu`, `gate.required-evidence`, or `gate.declared-scope`.
      Stale commits or gate events from an earlier run do not count.
      Dynamic `eval.*` and `handoff.*` events also count as durable progress.
    - If the watchdog parks with `no-durable-progress`, treat the root cause as
      a handoff-quality or hidden-blocker defect. Inspect the workspace/log, add
      code-level MIU details, and redispatch only after the correction is clear.
    - Runtime blocker comments must be written to the affected Linear issue
      whenever Linear is reachable. Include the correction id plus redacted
      runtime evidence so the issue timeline is the durable human log; the
      local Orocsy correction remains the machine-readable recovery state.
    - Retryable network/provider/runtime failures may retry only up to
      `agent.max_failed_worker_retries`. After that, Symphony must create an
      Orocsy correction, try to comment on Linear, release the worker slot, and
      stop dispatching that issue until the correction is resolved.
    - Do not keep reasoning around a blocked permission, token-budget, or network
      condition.
      Record the blocker with next action `block` or `retry` and let the
      workflow owner resolve/redispatch when the environment is healthy.

Strict dispatch gate:

1. Continue only if the issue is explicitly dispatch-ready.
2. The issue must define Write Scope, Shared Files, Dependencies, MIUs,
   Validation, and Out Of Scope.
3. The primary visible `## MIUs` section must itself include code-level handoff
   detail: current file paths, current risky code/API shape, target interface
   or DTO, data lifetime, concurrency/provider constraints, exact test names,
   and validation commands. A later appendix or cached brief is not enough for
   dispatch readiness because humans and workers both scan the primary section.
4. If the issue only has abstract MIU bullets such as "implement service" or
   "add tests", update the Linear workpad with `needs-code-level-miu` and stop
   before broad codebase rediscovery.
5. If any required section is missing, update the Linear workpad with `needs-scope` and
   stop without editing code.
6. If dependencies are unfinished, update the workpad with `blocked` and stop.
7. If this issue's declared write scope overlaps another active issue, update
   the workpad with `blocked-overlap` and stop.

CI/CD timing:

1. Do not dispatch full CI/CD as an early product feature lane.
2. Keep early lanes on focused local validation, branch discipline, PR review,
   and browser evidence when UI is touched.
3. Create CI/CD as its own platform MIU after the app baseline, package scripts,
   environment requirements, and merge flow are stable on `main`.

Review hardening trigger:

0. The runtime `review_monitor` polls `Human Review` issues for current-head
   GitHub PR feedback and moves them to `Rework` before dispatch. A worker
   should not need a human to copy Codex review comments back into Linear.
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
6. Build a bounded current accepted review set from unresolved, non-outdated
   findings. Fix all accepted current-code findings that are inside this
   issue's write scope and small enough for one review-hardening batch.
7. Review completion gate: do not move the issue back to `Human Review` until
   a fresh thread-aware scan shows zero active accepted review threads for the
   PR, or every remaining active thread is classified as `duplicate`, `stale`,
   `reject`, or `needs-design` with evidence in the Linear workpad.
8. If multiple accepted findings are too broad or unrelated for one MIU, fix the
   first safe batch, push it, leave the issue in `Rework`, and list the
   remaining active thread IDs and next action in Linear instead of handing back
   as complete.
9. Add or update focused regression tests for every accepted finding.
10. Push to the existing PR branch, reply or update the Linear workpad with the
   classification and validation evidence, request review again, then move the
   issue back to `Human Review` only after the review completion gate passes.
11. If push, GitHub review request, or Linear update fails after validation,
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
