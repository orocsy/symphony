# Symphony Dispatch

## Dispatch Gate

- Latest user intent locked:
- Branch:
- PR:
- Linear issue ids:
- Concurrency limit:
- Shared files:
- Stop conditions:
- Orocsy runtime initialized:
- Required gate commands:

## Agent Lanes

| Lane | Issue | Write scope | Required evidence | Validation | Depends on |
| --- | --- | --- | --- | --- | --- |
| A | <ISSUE> | <files/modules> | <events/files> | <commands> | <none> |
| B | <ISSUE> | <files/modules> | <events/files> | <commands> | <none> |

## Orocsy Worker Contract

Each Symphony worker must run inside the Orocsy runtime contract:

```bash
python3 "$OROCSY_CLI" --repo . symphony prepare-workspace --issue <ISSUE> --issue-file .orocsy/delivery/issue-requirements.json
python3 "$OROCSY_CLI" --repo . run start --issue <ISSUE>
python3 "$OROCSY_CLI" --repo . gate leaks --record
python3 "$OROCSY_CLI" --repo . gate secrets --record
python3 "$OROCSY_CLI" --repo . gate artifacts --record
python3 "$OROCSY_CLI" --repo . gate declared-scope --strict --record
python3 "$OROCSY_CLI" --repo . gate required-evidence --strict --record
```

After every validation command, append evidence:

```bash
python3 "$OROCSY_CLI" --repo . event append --type tool.finished --status passed --tool "<command>"
```

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
- Orocsy gate results recorded for every lane.
- Review comments classified.
- Browser evidence attached for UI flows.
- Integration pass run after convergence.
