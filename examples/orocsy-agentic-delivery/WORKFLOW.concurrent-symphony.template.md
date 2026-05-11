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
    else
      echo "Orocsy runtime CLI not found; refusing to run an ungoverned worker."
      exit 1
    fi
agent:
  max_concurrent_agents: 3
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
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

Orocsy worker prelude:

1. Read `AGENTS.md`.
2. Load the Orocsy / `agentic-delivery-loop` skill.
3. Read `.codex/delivery/state/current.json` and `.codex/delivery/policy.yml`.
   Use the workspace-local runtime CLI at `.codex/delivery/bin/orocsy.py`.
4. Read the assigned Linear issue, including Write Scope, Shared Files,
   Dependencies, MIUs, Validation, and Out Of Scope.
5. Before editing code, update `.codex/delivery/policy.yml` with the issue's
   declared write-scope globs if the prepare hook could not infer them.
6. Create or update the Technical MIU trace.
7. Confirm the `before_run` hook already recorded `run.started`,
   `gate.leaks`, `gate.secrets`, and `gate.artifacts` in
   `.codex/delivery/events.jsonl`. If they are missing, stop and report
   workflow setup failure instead of running the external `$OROCSY_CLI` path.
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

Strict dispatch gate:

1. Continue only if the issue is explicitly dispatch-ready.
2. The issue must define Write Scope, Shared Files, Dependencies, MIUs,
   Validation, and Out Of Scope.
3. If any section is missing, update the Linear workpad with `needs-scope` and
   stop without editing code.
4. If dependencies are unfinished, update the workpad with `blocked` and stop.
5. If this issue's declared write scope overlaps another active issue, update
   the workpad with `blocked-overlap` and stop.

Review hardening trigger:

1. If the issue state is `Rework`, or the issue has an attached open PR with
   unresolved Codex/human review threads, run the review hardening loop before
   any new feature work.
2. Fetch thread-aware PR review comments, not only flat PR comments.
3. Classify each finding as `accept`, `duplicate`, `stale`, `reject`, or
   `needs-design`.
4. Fix only accepted current-code findings inside the issue's write scope.
5. Add or update focused regression tests for every accepted finding.
6. Push to the existing PR branch, reply or update the Linear workpad with the
   classification and validation evidence, request review again, then move the
   issue back to `Human Review`.

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
