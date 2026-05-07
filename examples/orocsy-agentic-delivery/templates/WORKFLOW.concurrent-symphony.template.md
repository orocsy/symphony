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
agent:
  max_concurrent_agents: 3
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
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

Strict dispatch gate:

1. Continue only if the issue is explicitly dispatch-ready.
2. The issue must define Write Scope, Shared Files, Dependencies, MIUs,
   Validation, and Out Of Scope.
3. If any section is missing, update the Linear workpad with `needs-scope` and
   stop without editing code.
4. If dependencies are unfinished, update the workpad with `blocked` and stop.
5. If this issue's declared write scope overlaps another active issue, update
   the workpad with `blocked-overlap` and stop.

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
