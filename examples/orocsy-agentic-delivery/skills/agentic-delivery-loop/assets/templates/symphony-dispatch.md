# Symphony Dispatch

## Dispatch Gate

- Latest user intent locked:
- Branch:
- PR:
- Linear issue ids:
- Concurrency limit:
- Shared files:
- Stop conditions:

## Agent Lanes

| Lane | Issue | Write scope | Validation | Depends on |
| --- | --- | --- | --- | --- |
| A | <ISSUE> | <files/modules> | <commands> | <none> |
| B | <ISSUE> | <files/modules> | <commands> | <none> |

## Shared Boundary

If two lanes need the same route/component/service, create a boundary MIU
first:

- Shell owner:
- Slot/interface:
- Mounted lane:
- Contract tests:

## Workpad Update Format

```md
## Update <timestamp>

Scope:
Commit:
MIU completed:
Validation:
Blockers:
Next:
```

## Merge Gate

- All lane commits pushed.
- Local and remote checks known.
- Review comments classified.
- Browser evidence attached for UI flows.
- Integration pass run after convergence.

